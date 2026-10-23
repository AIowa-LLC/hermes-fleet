import XCTest
import FleetCore
@testable import FleetNetworking

/// Retry policy for timed-out gateway RPCs: which methods retry, how many
/// attempts run, the backoff shape, and that the timeout error names the RPC.
/// All timing is fake (injected sleep and jitter); the only socket is one
/// silent in-process fixture at the end.
final class RequestRetryTests: XCTestCase {

    /// Records sleeps, per-attempt timeouts, and call counts without waiting.
    private actor Log {
        private(set) var delays: [Duration] = []
        private(set) var attempts: [Duration?] = []
        private(set) var calls = 0
        func recordDelay(_ d: Duration) { delays.append(d) }
        func recordAttempt(_ timeout: Duration?) { attempts.append(timeout); calls += 1 }
    }

    private func fakeSleep(_ log: Log) -> @Sendable (Duration) async throws -> Void {
        { await log.recordDelay($0) }
    }

    // MARK: allowlist

    func testReadMethodsAreRetryableAndMutationsAreNot() {
        for read in ["session.history", "session.status", "session.list", "profiles.list",
                     "session.events.since", "config.get", "approval.pending"] {
            XCTAssertTrue(GatewayRequestCatalog.isIdempotentRead(read), read)
        }
        for write in ["prompt.submit", "config.set", "approval.respond", "session.create",
                      "session.resume", "session.interrupt", "cron.manage", "message.react",
                      "profiles.configure", "groups.send"] {
            XCTAssertFalse(GatewayRequestCatalog.isIdempotentRead(write), write)
        }
    }

    // MARK: retry count

    func testIdempotentReadRetriesTimeoutsUpToMaxAttempts() async {
        let log = Log()
        do {
            _ = try await RequestRetry.run(
                method: "session.history",
                policy: .idempotentRead,
                sleep: fakeSleep(log),
                jitter: { 0 }
            ) { timeout -> Int in
                await log.recordAttempt(timeout)
                throw TransportError.requestTimeout(method: "session.history")
            }
            XCTFail("expected timeout")
        } catch TransportError.requestTimeout(let method) {
            XCTAssertEqual(method, "session.history")
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let calls = await log.calls
        let delays = await log.delays
        let attempts = await log.attempts
        XCTAssertEqual(calls, RequestRetryPolicy.idempotentRead.maxAttempts)
        XCTAssertEqual(delays.count, RequestRetryPolicy.idempotentRead.maxAttempts - 1)
        // Retried reads use the policy's per-attempt cap, not the connection default.
        XCTAssertTrue(attempts.allSatisfy { $0 == Duration.seconds(30) })
    }

    func testIdempotentReadSucceedsOnLaterAttempt() async throws {
        let log = Log()
        let counter = Log()
        let value = try await RequestRetry.run(
            method: "profiles.list",
            policy: .idempotentRead,
            sleep: fakeSleep(log),
            jitter: { 0.5 }
        ) { _ -> String in
            await counter.recordAttempt(nil)
            let calls = await counter.calls
            if calls < 3 { throw TransportError.requestTimeout(method: "profiles.list") }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        let calls = await counter.calls
        let delays = await log.delays
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(delays.count, 2)
    }

    // MARK: mutations are never retried

    func testMutationTimeoutIsSurfacedAfterOneAttempt() async {
        let log = Log()
        do {
            _ = try await RequestRetry.run(
                method: "config.set",
                policy: .idempotentRead,
                sleep: fakeSleep(log),
                jitter: { 0 }
            ) { timeout -> Int in
                await log.recordAttempt(timeout)
                throw TransportError.requestTimeout(method: "config.set")
            }
            XCTFail("expected timeout")
        } catch TransportError.requestTimeout(let method) {
            XCTAssertEqual(method, "config.set")
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let calls = await log.calls
        let delays = await log.delays
        let attempts = await log.attempts
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(delays.count, 0)
        // Writes keep the connection's default timeout (nil override).
        XCTAssertEqual(attempts, [nil])
    }

    func testPromptSubmitIsNeverRetried() async {
        let log = Log()
        do {
            _ = try await RequestRetry.run(
                method: "prompt.submit",
                policy: .idempotentRead,
                sleep: fakeSleep(log),
                jitter: { 0 }
            ) { timeout -> Int in
                await log.recordAttempt(timeout)
                throw TransportError.requestTimeout(method: "prompt.submit")
            }
        } catch {}
        let calls = await log.calls
        let delays = await log.delays
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(delays.count, 0)
    }

    // MARK: only timeouts are retried

    func testNonTimeoutErrorsAreNotRetried() async {
        let log = Log()
        do {
            _ = try await RequestRetry.run(
                method: "session.history",
                policy: .idempotentRead,
                sleep: fakeSleep(log),
                jitter: { 0 }
            ) { timeout -> Int in
                await log.recordAttempt(timeout)
                throw TransportError.connectionClosed(.abnormalClosure)
            }
            XCTFail("expected failure")
        } catch TransportError.connectionClosed {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let calls = await log.calls
        let delays = await log.delays
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(delays.count, 0)
    }

    func testMaxAttemptsFloorsAtOne() async {
        let policy = RequestRetryPolicy(maxAttempts: 0, baseDelay: .milliseconds(1), maxDelay: .milliseconds(1))
        XCTAssertEqual(policy.maxAttempts, 1)
        let log = Log()
        do {
            _ = try await RequestRetry.run(
                method: "session.list", policy: policy,
                sleep: fakeSleep(log), jitter: { 0 }
            ) { timeout -> Int in
                await log.recordAttempt(timeout)
                throw TransportError.requestTimeout(method: "session.list")
            }
        } catch {}
        let calls = await log.calls
        XCTAssertEqual(calls, 1)
    }

    // MARK: backoff

    func testBackoffIsExponentialWithEqualJitter() {
        let policy = RequestRetryPolicy.idempotentRead // base 0.5s, cap 4s
        // Jitter 0 gives the lower bound (half the capped delay).
        XCTAssertEqual(policy.backoff(beforeRetry: 1, jitter: 0), .milliseconds(250))
        XCTAssertEqual(policy.backoff(beforeRetry: 2, jitter: 0), .milliseconds(500))
        // Jitter 1 gives the full capped delay.
        XCTAssertEqual(policy.backoff(beforeRetry: 1, jitter: 1), .milliseconds(500))
        XCTAssertEqual(policy.backoff(beforeRetry: 2, jitter: 1), .milliseconds(1000))
        // Out-of-range jitter is clamped.
        XCTAssertEqual(policy.backoff(beforeRetry: 2, jitter: 7), .milliseconds(1000))
        XCTAssertEqual(policy.backoff(beforeRetry: 2, jitter: -3), .milliseconds(500))
    }

    func testBackoffIsCapped() {
        let policy = RequestRetryPolicy(maxAttempts: 10, baseDelay: .milliseconds(500), maxDelay: .seconds(4))
        XCTAssertEqual(policy.backoff(beforeRetry: 9, jitter: 1), .seconds(4))
        XCTAssertEqual(policy.backoff(beforeRetry: 30, jitter: 1), .seconds(4))
    }

    // MARK: transport integration

    /// A silent gateway (answers the handshake, never answers RPCs). A read
    /// retries through the injected policy and ends with a timeout that names
    /// the RPC; the fake sleep means the test does not wait for backoff.
    func testReadRequestAgainstSilentGatewayReportsTimedOutMethod() async throws {
        let server = try InProcessWebSocketServer(script: .init(onOpen: [Self.readyFrame()]))
        try await server.start()
        defer { server.stop() }

        let transport = GatewayWebSocketTransport(
            baseURL: URL(string: "http://127.0.0.1:\(server.listeningPort)")!,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: TransportConfiguration(
                pingInterval: .seconds(30),
                inboundDeadline: .seconds(30),
                connectTimeout: .seconds(10),
                requestTimeout: .seconds(10)
            )
        )
        try await transport.connect()

        let log = Log()
        let policy = RequestRetryPolicy(
            maxAttempts: 3, baseDelay: .milliseconds(1), maxDelay: .milliseconds(1),
            attemptTimeout: .milliseconds(100)
        )
        do {
            _ = try await transport.readRequest(
                method: "profiles.list", params: .object([:]), policy: policy,
                sleep: fakeSleep(log), jitter: { 0 }
            )
            XCTFail("expected requestTimeout")
        } catch let error as TransportError {
            XCTAssertEqual(error, .requestTimeout(method: "profiles.list"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let delays = await log.delays
        XCTAssertEqual(delays.count, 2)
        await transport.disconnect()
    }

    private static func readyFrame() -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true,"heartbeat":false,"replay_epoch":"epoch-1"}}}"#
    }
}
