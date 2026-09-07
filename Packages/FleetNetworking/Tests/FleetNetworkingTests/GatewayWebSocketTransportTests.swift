import XCTest
import FleetCore
import FleetNetworking

/// Fake ticket minter for transport tests (no network).
struct StaticTicketMinter: WSTicketMinting {
    let ticket: WSTicket
    func mintTicket() async throws -> WSTicket { ticket }
}

/// Scripted gateway.ready payload used across transport integration tests.
func readyFrame(replayEpoch: String = "epoch-1") -> String {
    #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{},"change_events":true,"heartbeat":true,"replay_epoch":"\#(replayEpoch)"}}}"#
}

final class GatewayWebSocketTransportTests: XCTestCase {

    /// A transport pointed at an in-process server with a short heartbeat
    /// config (fast tests), and a ready frame pushed on open.
    private func makeTransport(
        serverPort: UInt16,
        pingInterval: Duration = .milliseconds(200),
        inboundDeadline: Duration = .seconds(30),
        connectTimeout: Duration = .seconds(10),
        ticket: WSTicket = WSTicket(token: "fixture-ticket", ttlSeconds: 30)
    ) -> GatewayWebSocketTransport {
        let base = URL(string: "http://127.0.0.1:\(serverPort)")!
        let config = TransportConfiguration(
            pingInterval: pingInterval,
            inboundDeadline: inboundDeadline,
            connectTimeout: connectTimeout,
            requestTimeout: .seconds(10)
        )
        return GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTicketMinter(ticket: ticket),
            configuration: config
        )
    }

    // MARK: connect + gateway.ready

    func testConnectReceivesReadyAndEntersConnected() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [readyFrame()],
            onText: { frame in
                // Echo gateway.ping responses so heartbeat stays healthy.
                if frame.contains("\"gateway.ping\"") {
                    guard let id = Self.extractID(from: frame) else { return [] }
                    return [Self.pongFrame(id: id)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        XCTAssertEqual(transport.state, .disconnected)

        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)
        await transport.disconnect()
        XCTAssertEqual(transport.state, .disconnected)
    }

    func testConnectWithoutReadyTimesOut() async throws {
        // Server opens but never sends gateway.ready → connect must time out.
        let server = try InProcessWebSocketServer(script: .init())
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(
            serverPort: server.listeningPort, connectTimeout: .milliseconds(500))
        do {
            try await transport.connect()
            XCTFail("expected ready timeout")
        } catch let error as TransportError {
            XCTAssertEqual(error, .readyTimeout)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        // The transport must not be left in a connected state after a failed
        // handshake; it either stays disconnected or records a failure.
        XCTAssertNotEqual(transport.state, .connected, "must not be connected after ready timeout")
    }

    // MARK: heartbeat

    func testHeartbeatSendsPingsAndKeepsConnectionAlive() async throws {
        // Track how many gateway.ping frames the server sees.
        let pingCounter = PingCounter()
        let script = InProcessWebSocketServer.Script(
            onOpen: [readyFrame()],
            onText: { frame in
                if frame.contains("\"gateway.ping\"") {
                    pingCounter.increment()
                    guard let id = Self.extractID(from: frame) else { return [] }
                    return [Self.pongFrame(id: id)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(
            serverPort: server.listeningPort, pingInterval: .milliseconds(150))
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        // Let a few heartbeat intervals elapse.
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertGreaterThanOrEqual(pingCounter.count, 2, "expected repeated pings")

        await transport.disconnect()
    }

    func testHeartbeatOnlyRunsWhenGatedByReadyFlag() async throws {
        // gateway.ready with heartbeat:false must NOT start pinging.
        let pingCounter = PingCounter()
        let noHeartbeatReady = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"heartbeat":false,"change_events":true,"replay_epoch":"e1"}}}"#
        let script = InProcessWebSocketServer.Script(
            onOpen: [noHeartbeatReady],
            onText: { frame in
                if frame.contains("\"gateway.ping\"") { pingCounter.increment() }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(
            serverPort: server.listeningPort, pingInterval: .milliseconds(100))
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(pingCounter.count, 0, "heartbeat must be gated on ready.heartbeat")

        await transport.disconnect()
    }

    func testHeartbeatStaleConnectionMapsToAbnormalClosure() async throws {
        // Server sends ready but never responds → after inboundDeadline the
        // transport must treat the connection as stale (failed).
        let script = InProcessWebSocketServer.Script(
            onOpen: [readyFrame()]
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(
            serverPort: server.listeningPort,
            pingInterval: .milliseconds(100),
            inboundDeadline: .milliseconds(500)
        )
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        // Wait past the deadline; the stale handler should flip to failed.
        let deadline = Date().addingTimeInterval(3)
        while transport.state == .connected && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard case .failed(let reason) = transport.state else {
            return XCTFail("expected failed state after stale heartbeat, got \(transport.state)")
        }
        XCTAssertTrue(reason.contains("abnormal"), "expected abnormal closure reason, got \(reason)")
    }

    // MARK: P1-4 — junk-frame liveness (binary/malformed must NOT refresh liveness)

    /// P1-4 regression: a peer that sends ONLY periodic binary frames must not
    /// stay "connected" forever. Binary frames are junk on the text-only
    /// /api/ws seam — they must NOT refresh `lastInbound`, so the inbound
    /// deadline fires and the peer is classified abnormal.
    func testPeriodicBinaryFramesDoNotRefreshLiveness() async throws {
        // Ready frame, then NOTHING but binary junk — no valid protocol frame.
        let server = try InProcessWebSocketServer(script: .init(onOpen: [readyFrame()]))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(
            serverPort: server.listeningPort,
            pingInterval: .milliseconds(100),
            inboundDeadline: .milliseconds(400)
        )
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        // Push binary junk CONTINUOUSLY for the whole wait window, so on the
        // old (buggy) code the peer stays alive purely via junk frames. The
        // fixed code must NOT count these as liveness → deadline fires.
        let junker = Task {
            while !Task.isCancelled {
                server.sendBinary(Data([0x00, 0x01, 0x02]))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { junker.cancel() }

        let deadline = Date().addingTimeInterval(3)
        while transport.state == .connected && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard case .failed(let reason) = transport.state else {
            return XCTFail("expected failed state after binary-only peer, got \(transport.state)")
        }
        XCTAssertTrue(reason.contains("abnormal"), "expected abnormal closure reason, got \(reason)")
    }

    /// P1-4 regression: a peer that sends malformed (non-JSON-RPC) text frames
    /// must not stay connected forever. Consecutive junk beyond the bounded
    /// threshold closes + classifies the connection.
    func testMalformedFrameFloodClosesConnectionPastThreshold() async throws {
        let server = try InProcessWebSocketServer(script: .init(onOpen: [readyFrame()]))
        try await server.start()
        defer { server.stop() }

        // Tiny threshold + long deadline: the threshold, not the inbound
        // deadline, must be what closes the connection.
        let config = TransportConfiguration(
            pingInterval: .milliseconds(200),
            inboundDeadline: .seconds(30),
            connectTimeout: .seconds(10),
            requestTimeout: .seconds(10),
            malformedFrameLimit: 3
        )
        let base = URL(string: "http://127.0.0.1:\(server.listeningPort)")!
        let transport = GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: config
        )
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        // Flood malformed text frames (they fail JSON-RPC decode).
        for _ in 0..<6 {
            server.sendText("this is not json {{{")
            try await Task.sleep(for: .milliseconds(20))
        }

        let deadline = Date().addingTimeInterval(3)
        while transport.state == .connected && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard case .failed(let reason) = transport.state else {
            return XCTFail("expected failed state after malformed flood, got \(transport.state)")
        }
        XCTAssertTrue(reason.contains("abnormal"), "expected abnormal closure reason, got \(reason)")
    }

    // MARK: close-code mapping

    func testServerClose4401MapsToReauth() async throws {
        // Server closes with 4401 (bad credential) shortly after ready.
        let script = InProcessWebSocketServer.Script(
            onOpen: [readyFrame()],
            onText: { _ in [] }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        // Ask the server to close with 4401.
        server.sendClose(code: 4401)

        let deadline = Date().addingTimeInterval(3)
        while transport.state == .connected && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard case .failed(let reason) = transport.state else {
            return XCTFail("expected failed state after 4401 close, got \(transport.state)")
        }
        XCTAssertTrue(reason.contains("reauthentication"), "expected reauth mapping, got \(reason)")
    }

    func testServerClose1000MapsToDisconnected() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [readyFrame()],
            onText: { _ in [] }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        server.sendClose(code: 1000)
        let deadline = Date().addingTimeInterval(3)
        while transport.state == .connected && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotEqual(transport.state, .connected, "normal close should end the connection")
    }

    // MARK: URL building

    func testBuildWebSocketURLAppendsTicket() throws {
        let base = URL(string: "http://127.0.0.1:9119")!
        let url = try XCTUnwrap(
            GatewayWebSocketTransport.buildWebSocketURL(
                base: base, path: "/api/ws", ticket: WSTicket(token: "t-123", ttlSeconds: 30)))
        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.port, 9119)
        XCTAssertEqual(url.path, "/api/ws")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "ticket" })
        XCTAssertEqual(query?.value, "t-123")
    }

    func testBuildWebSocketURLHTTPSBecomesWSS() throws {
        let base = URL(string: "https://gateway.example.com:9443")!
        let url = try XCTUnwrap(
            GatewayWebSocketTransport.buildWebSocketURL(
                base: base, path: "/api/ws", ticket: WSTicket(token: "t", ttlSeconds: 30)))
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.port, 9443)
    }

    // MARK: D1 — deterministic handshake-death classification

    /// D1 regression (M13 HOLD): when the socket dies during the ready
    /// handshake, `connect()` must deterministically classify the failure as
    /// `.connectionClosed(.abnormalClosure)` — never a race-dependent
    /// `.readyTimeout`. The `DyingSession`'s blocking `close()` keeps teardown
    /// suspended at the close await (after finishing the ready channel) while
    /// `waitForReady()` samples `connectionState`; pre-fix that sampled
    /// `.connecting` and rethrew `.readyTimeout`.
    func testSocketDeathDuringHandshakeClassifiesConnectionClosedNotReadyTimeout() async throws {
        let config = TransportConfiguration(
            pingInterval: .seconds(30),
            inboundDeadline: .seconds(30),
            connectTimeout: .seconds(10),
            requestTimeout: .seconds(10)
        )
        let base = URL(string: "http://127.0.0.1:1")!
        let transport = GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            sessionFactory: DyingSessionFactory(closeDelay: .milliseconds(400)),
            configuration: config
        )
        do {
            try await transport.connect()
            XCTFail("expected connectionClosed(.abnormalClosure), got success")
        } catch let error as TransportError {
            XCTAssertEqual(error, .connectionClosed(.abnormalClosure))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: state machine

    func testConnectionStateMapsToTransportState() {
        XCTAssertEqual(ConnectionState.idle.transportState, .disconnected)
        XCTAssertEqual(ConnectionState.connecting.transportState, .connecting)
        XCTAssertEqual(ConnectionState.open.transportState, .connected)
        XCTAssertEqual(ConnectionState.closed.transportState, .disconnected)
        XCTAssertEqual(ConnectionState.error(.serverError).transportState, .failed("server error (1011)"))
    }

    func testConnectFromOpenIsIdempotentNoOp() async throws {
        // P0-7: a second connect() while OPEN must be an idempotent no-op —
        // the dogfood defect "connect() from open" broke conversation
        // re-entry against the shared per-gateway transport.
        let script = InProcessWebSocketServer.Script(onOpen: [readyFrame()])
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        // Second connect: no throw, stays connected, NO second socket.
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)
        XCTAssertEqual(server.connectionCount, 1,
                       "idempotent connect must not open a second connection")

        await transport.disconnect()
    }

    // MARK: P0-7 — event fan-out (multi-subscriber)

    /// Thread-safe accumulator for the fan-out tests (module-local).
    private final class FanOutCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [GatewayEvent] = []
        var all: [GatewayEvent] { lock.lock(); defer { lock.unlock() }; return _all }
        func append(_ event: GatewayEvent) { lock.lock(); _all.append(event); lock.unlock() }
    }

    /// P0-7: two subscribers each receive every streamed event — the event
    /// channel fans out instead of handing its only element to one consumer.
    /// This is what lets a re-entered conversation (fresh view model) keep
    /// rendering replies over the shared per-gateway transport.
    func testEventFanOutDeliversToAllSubscribers() async throws {
        let script = InProcessWebSocketServer.Script(onOpen: [readyFrame()])
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()

        // Register BOTH subscriptions synchronously (registration happens in
        // subscribeToEvents(), not when iteration starts — AsyncStream
        // buffers yields until the consumer iterates), then spawn consumers.
        // This removes the task-startup race that flaked under CI load.
        let first = FanOutCollector()
        let second = FanOutCollector()
        let stream1 = transport.subscribeToEvents()
        let stream2 = transport.subscribeToEvents()
        let sub1 = Task { for await event in stream1 { first.append(event) } }
        let sub2 = Task { for await event in stream2 { second.append(event) } }
        defer { sub1.cancel(); sub2.cancel() }

        server.sendText(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"s-1","seq":1,"payload":{"text":"hi"}}}"#)

        let deadline = Date().addingTimeInterval(3)
        while (first.all.isEmpty || second.all.isEmpty) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(first.all.count, 1, "first subscriber must receive the event")
        XCTAssertEqual(second.all.count, 1, "second subscriber must receive the event")
        XCTAssertEqual(first.all.first?.type, .messageDelta)
        XCTAssertEqual(second.all.first?.type, .messageDelta)

        await transport.disconnect()
    }

    /// P0-7: a subscriber attached AFTER a previous consumer cancelled still
    /// receives subsequently streamed events (re-entry: the first view model
    /// died, the new one must get a live pipe).
    func testLateSubscriberAfterCancellationReceivesEvents() async throws {
        let script = InProcessWebSocketServer.Script(onOpen: [readyFrame()])
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()

        // First subscriber attaches, then cancels (view model popped).
        let early = FanOutCollector()
        let earlyStream = transport.subscribeToEvents()
        let earlyTask = Task { for await event in earlyStream { early.append(event) } }
        try await Task.sleep(for: .milliseconds(200))
        earlyTask.cancel()

        // Late subscriber registers synchronously (conversation re-entered).
        let late = FanOutCollector()
        let lateStream = transport.subscribeToEvents()
        let lateTask = Task { for await event in lateStream { late.append(event) } }
        defer { lateTask.cancel() }

        server.sendText(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"s-1","seq":2,"payload":{"text":"again"}}}"#)

        let deadline = Date().addingTimeInterval(3)
        while late.all.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(late.all.count, 1, "late subscriber must receive the event after the first consumer cancelled")

        await transport.disconnect()
    }

    // MARK: helpers

    private static func extractID(from frame: String) -> String? {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { return nil }
        return id
    }

    private static func pongFrame(id: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","result":{"ok":true}}"#
    }
}

/// A session double whose `receive()` fails immediately (the socket died
/// during the ready handshake) and whose `close()` blocks for a controlled
/// duration. The blocking close deterministically reproduces the D1 race: the
/// receive-loop teardown finishes the ready channel, then suspends at the
/// close await — so `waitForReady()` samples `connectionState` while teardown
/// is mid-flight. Pre-fix that sampled `.connecting` (→ `.timeout`); the fix
/// records `.error(.abnormalClosure)` before finishing the ready channel so
/// the classification is `.unreachable`.
final class DyingSession: WebSocketSession, @unchecked Sendable {
    private let closeDelay: Duration
    init(closeDelay: Duration) { self.closeDelay = closeDelay }
    var lastCloseCode: Int? { nil }
    func open() async throws {}
    func receive() async throws -> WebSocketMessage {
        // NSURLErrorCannotConnectToHost → CloseCodeMapping → .abnormalClosure.
        throw URLError(.cannotConnectToHost)
    }
    func send(_ message: WebSocketMessage) async throws {}
    func close(code: Int, reason: String?) async {
        // Deterministic race hold: the receive-loop teardown CANCELS its own
        // task before calling close(), so a cancellation-aware Task.sleep here
        // would bail instantly and never hold the window open. Suspend on a
        // plain continuation resumed by a dispatch timer instead — this yields
        // the actor for the configured delay (ignoring cancellation) so
        // waitForReady()'s classification catch deterministically runs while
        // teardown is mid-flight, before the terminal connection state is
        // recorded.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let nanos = Int(closeDelay.components.seconds * 1_000_000_000
                + closeDelay.components.attoseconds / 1_000_000_000)
            DispatchQueue.global().asyncAfter(
                deadline: .now() + DispatchTimeInterval.nanoseconds(nanos)
            ) {
                cont.resume()
            }
        }
    }
}

struct DyingSessionFactory: WebSocketSessionFactory {
    let closeDelay: Duration
    func makeSession(url: URL) -> any WebSocketSession {
        DyingSession(closeDelay: closeDelay)
    }
}

/// Thread-safe counter used to observe server-side received pings.
final class PingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func increment() { lock.lock(); _count += 1; lock.unlock() }
}
