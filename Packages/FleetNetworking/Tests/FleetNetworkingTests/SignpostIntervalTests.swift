import XCTest
import FleetCore
import FleetNetworking

/// F0 — `gateway.connect` and `replay.pass` signpost intervals begin and end
/// exactly once per flow, using an injected recording sink (no OS trace).
final class SignpostIntervalTests: XCTestCase {

    // MARK: helpers

    private func makeTransport(
        serverPort: UInt16, connectTimeout: Duration = .seconds(10)
    ) -> GatewayWebSocketTransport {
        GatewayWebSocketTransport(
            baseURL: URL(string: "http://127.0.0.1:\(serverPort)")!,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: TransportConfiguration(
                pingInterval: .seconds(30), inboundDeadline: .seconds(30),
                connectTimeout: connectTimeout, requestTimeout: .seconds(3)))
    }

    private func makeSignposts() -> (FleetSignposts, FleetSignpostRecorder) {
        let recorder = FleetSignpostRecorder()
        return (FleetSignposts(sink: recorder, stats: FleetPerformanceStats()), recorder)
    }

    private static func ready() -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true,"heartbeat":false,"replay_epoch":"epoch-1"}}}"#
    }

    private static func seqEvent(sessionID: String, seq: Int) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "event",
            "params": ["type": "message.delta", "session_id": sessionID, "seq": seq,
                       "payload": ["text": "x"]] as [String: Any],
        ] as [String: Any])
        return String(data: data, encoding: .utf8)!
    }

    private static func request(_ frame: String) -> (id: String, method: String)? {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String, let method = obj["method"] as? String else { return nil }
        return (id, method)
    }

    private static func response(id: String, result: [String: Any]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result] as [String: Any])
        return String(data: data, encoding: .utf8)!
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition not met in time")
    }

    // MARK: gateway.connect

    func testConnectIntervalBeginsAndEndsOncePerConnectAndIsNotDuplicatedWhenAlreadyOpen() async throws {
        let server = try InProcessWebSocketServer(script: .init(onOpen: [Self.ready()]))
        try await server.start()
        defer { server.stop() }

        let (signposts, recorder) = makeSignposts()
        let transport = makeTransport(serverPort: server.listeningPort)
        await transport.setSignposts(signposts)

        try await transport.connect()
        try await transport.connect() // idempotent from .open: no second interval
        XCTAssertEqual(recorder.beginCount(.gatewayConnect), 1)
        XCTAssertEqual(recorder.endEvents(.gatewayConnect).map(\.outcome), [.completed])
        XCTAssertTrue(recorder.isBalanced(.gatewayConnect))

        await transport.disconnect()
        try await transport.connect() // a genuine reconnect is a second interval
        XCTAssertEqual(recorder.beginCount(.gatewayConnect), 2)
        XCTAssertTrue(recorder.isBalanced(.gatewayConnect))
        await transport.disconnect()
    }

    func testConcurrentConnectCallsShareOneInterval() async throws {
        let server = try InProcessWebSocketServer(script: .init(onOpen: [Self.ready()]))
        try await server.start()
        defer { server.stop() }

        let (signposts, recorder) = makeSignposts()
        let transport = makeTransport(serverPort: server.listeningPort)
        await transport.setSignposts(signposts)

        async let first: Void = transport.connect()
        async let second: Void = transport.connect()
        _ = try await (first, second)
        XCTAssertEqual(recorder.beginCount(.gatewayConnect), 1)
        XCTAssertTrue(recorder.isBalanced(.gatewayConnect))
        await transport.disconnect()
    }

    func testFailedConnectEndsIntervalAsFailed() async throws {
        let server = try InProcessWebSocketServer(script: .init()) // never sends ready
        try await server.start()
        defer { server.stop() }

        let (signposts, recorder) = makeSignposts()
        let transport = makeTransport(serverPort: server.listeningPort, connectTimeout: .milliseconds(300))
        await transport.setSignposts(signposts)

        do {
            try await transport.connect()
            XCTFail("expected ready timeout")
        } catch {}
        XCTAssertEqual(recorder.beginCount(.gatewayConnect), 1)
        XCTAssertEqual(recorder.endEvents(.gatewayConnect).map(\.outcome), [.failed])
        XCTAssertTrue(recorder.isBalanced(.gatewayConnect))
    }

    func testCancelledConnectEndsIntervalWithoutLeaking() async throws {
        let server = try InProcessWebSocketServer(script: .init()) // never sends ready
        try await server.start()
        defer { server.stop() }

        let (signposts, recorder) = makeSignposts()
        let transport = makeTransport(serverPort: server.listeningPort, connectTimeout: .seconds(2))
        await transport.setSignposts(signposts)

        let task = Task { try await transport.connect() }
        await waitUntil { recorder.beginCount(.gatewayConnect) == 1 }
        task.cancel()
        _ = try? await task.value

        XCTAssertEqual(recorder.endEvents(.gatewayConnect).count, 1)
        XCTAssertTrue(recorder.isBalanced(.gatewayConnect))
        XCTAssertNotEqual(recorder.endEvents(.gatewayConnect).first?.outcome, .completed)
    }

    // MARK: replay.pass

    func testReplayPassBeginsAndEndsOnceWithEventCount() async throws {
        let first = InProcessWebSocketServer.Script(
            onOpen: [Self.ready(),
                     Self.seqEvent(sessionID: "s1", seq: 1),
                     Self.seqEvent(sessionID: "s1", seq: 2),
                     Self.seqEvent(sessionID: "s1", seq: 3)],
            onText: { _ in [] })
        let second = InProcessWebSocketServer.Script(
            onOpen: [Self.ready()],
            onText: { frame in
                guard let (id, method) = Self.request(frame), method == "session.events.since" else { return [] }
                return [Self.response(id: id, result: [
                    "events": [
                        ["type": "message.delta", "session_id": "s1", "seq": 4, "payload": ["text": "c"]],
                        ["type": "message.delta", "session_id": "s1", "seq": 5, "payload": ["text": "d"]],
                    ] as [[String: Any]],
                    "latest_seq": 5, "truncated": false, "count": 2, "epoch": "epoch-1",
                ])]
            })
        let server = try InProcessWebSocketServer(scripts: [first, second])
        try await server.start()
        defer { server.stop() }

        let (signposts, recorder) = makeSignposts()
        let transport = makeTransport(serverPort: server.listeningPort)
        await transport.setSignposts(signposts)
        try await transport.connect()
        await waitUntil { await transport.watermark(for: "s1") == 3 }

        let engine = GatewayReplayEngine(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport,
            history: StubHistory())
        await engine.setSignposts(signposts)

        // First adoption: nothing to replay, and not a measurable "pass".
        _ = try await engine.replayAfterReconnect()
        XCTAssertEqual(recorder.beginCount(.replayPass), 0)

        server.abortConnection()
        await waitUntil { transport.state != .connected }
        try await transport.connect()
        let outcomes = try await engine.replayAfterReconnect()

        XCTAssertEqual(outcomes, [.replayed(sessionID: "s1", count: 2)])
        XCTAssertEqual(recorder.beginCount(.replayPass), 1)
        XCTAssertEqual(recorder.endEvents(.replayPass).count, 1)
        XCTAssertEqual(recorder.endEvents(.replayPass).first?.outcome, .completed)
        XCTAssertEqual(recorder.endEvents(.replayPass).first?.count, 2)
        XCTAssertTrue(recorder.isBalanced(.replayPass))
        await transport.disconnect()
    }
}

private struct StubHistory: SessionHistoryProviding {
    func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
        SessionHistory(sessionID: sessionID, count: 0, messages: [])
    }

    func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
        SessionStatus.parse(output: "Hermes TUI Status\nSession ID: \(sessionID)\nAgent Running: No")
    }
}
