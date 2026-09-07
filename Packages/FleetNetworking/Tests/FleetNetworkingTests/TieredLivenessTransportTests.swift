import XCTest
import FleetCore
import FleetNetworking

/// t_a07ca37e — tiered heartbeat-freshness liveness at the transport level
/// (Hermex #227 pattern folded into the RT3 liveness evaluation). These run
/// against the real actor + in-process WebSocket server with compressed
/// timing windows, proving:
///   - last-frame tracking refreshes on heartbeats AND payload frames;
///   - a "slow model turn" (heartbeats flowing, no content frames past the
///     reconnect window) stays connected — no spurious teardown/reconnect;
///   - a dead transport (no frames at all) still goes stale within the
///     tiered window and reconnects;
///   - a mid-flight tool call extends the reconnect window.
final class TieredLivenessTransportTests: XCTestCase {

    /// Compressed windows: fresh <1.2s, checkDue 1.2..<1.8s, stale at 1.8s,
    /// extended to 2.5s while a tool call is in flight. Check cadence 200ms.
    private let timing = ConnectionLivenessTiming(
        checkingInterval: 0.2,
        transportFreshInterval: 1.2,
        reconnectInterval: 1.8,
        runningToolReconnectInterval: 2.5
    )

    private func eventFrame(type: String, sessionID: String, seq: Int) -> String {
        #"{ "jsonrpc": "2.0", "method": "event", "params": { "type": "\#(type)", "session_id": "\#(sessionID)", "seq": \#(seq) } }"#
    }

    private func makeTransport(
        serverPort: UInt16,
        pingInterval: Duration = .milliseconds(100),
        livenessTiming: ConnectionLivenessTiming
    ) -> GatewayWebSocketTransport {
        let base = URL(string: "http://127.0.0.1:\(serverPort)")!
        let config = TransportConfiguration(
            pingInterval: pingInterval,
            livenessTiming: livenessTiming,
            connectTimeout: .seconds(10),
            requestTimeout: .seconds(10)
        )
        return GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 60)),
            configuration: config
        )
    }

    private func heartbeatScript() -> InProcessWebSocketServer.Script {
        InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                if frame.contains("\"gateway.ping\"") {
                    guard let id = Self.extractID(from: frame) else { return [] }
                    return [Self.pongFrame(id: id)]
                }
                return []
            }
        )
    }

    /// Wait until `condition` holds or the timeout elapses.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: last-frame tracking refreshes on heartbeats AND payload frames

    func testLivenessSnapshotRefreshesOnHeartbeatPong() async throws {
        let server = try InProcessWebSocketServer(script: heartbeatScript())
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort, livenessTiming: timing)
        try await transport.connect()

        // Heartbeat pongs flow (every 100ms); silence stays fresh.
        try await Task.sleep(for: .milliseconds(600))
        let snapshot = try XCTUnwrap(transport.liveness, "liveness snapshot must exist while connected")
        XCTAssertTrue(
            snapshot.tier(timing: timing) == .fresh,
            "heartbeat-refreshed transport must be fresh (silence was \(snapshot.secondsSinceLastFrame())s)")

        await transport.disconnect()
    }

    func testLivenessSnapshotRefreshesOnPayloadFrame() async throws {
        let server = try InProcessWebSocketServer(script: heartbeatScript())
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort, livenessTiming: timing)
        try await transport.connect()

        // A payload (event) frame — NOT a heartbeat — must also refresh the
        // last-frame timestamp.
        server.sendText(eventFrame(type: "message.delta", sessionID: "s-1", seq: 1))
        try await Task.sleep(for: .milliseconds(150))
        let snapshot = try XCTUnwrap(transport.liveness)
        XCTAssertEqual(snapshot.tier(timing: timing), .fresh,
                       "payload frame must refresh last-frame tracking")

        await transport.disconnect()
    }

    // MARK: slow model turn — no spurious teardown

    /// Simulated slow model turn: heartbeats keep flowing (server answers
    /// pings), no content frames arrive for LONGER than the reconnect
    /// window. The connection must stay open — no teardown, no reconnect.
    func testSlowTurnWithHeartbeatsStaysConnectedPastReconnectWindow() async throws {
        let server = try InProcessWebSocketServer(script: heartbeatScript())
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort, livenessTiming: timing)
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        // "No content frames" for 3s — well past the 1.8s reconnect window —
        // while heartbeat pongs flow every 100ms.
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(200))
            if transport.state != .connected {
                break // teardown happened — will fail the assert below
            }
        }
        XCTAssertEqual(transport.state, .connected,
                       "slow turn with flowing heartbeats must NOT tear down the connection")
        let connections = server.connectionCount

        await transport.disconnect()
        XCTAssertEqual(server.connectionCount, connections,
                       "no reconnect may have occurred during the slow turn")
    }

    // MARK: dead transport still detected in the tiered window

    /// Simulated dead transport: server goes silent (no pongs, no frames at
    /// all). The transport must go stale and tear down within the tiered
    /// window (stale at 1.8s + 200ms check cadence tolerance).
    func testDeadTransportGoesStaleWithinTieredWindow() async throws {
        // Server sends ready and never responds to anything.
        let server = try InProcessWebSocketServer(
            script: .init(onOpen: [Self.readyFrame()], onText: { _ in [] }))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort, livenessTiming: timing)
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        // Silence: no pongs, no frames. Transport must classify stale
        // (abnormal) — the last-frame timestamp ages out.
        let torn = try await waitUntil(timeout: 5) { transport.state != .connected }
        XCTAssertTrue(torn, "dead transport must be detected within the tiered window")
        guard case .failed(let reason) = transport.state else {
            return XCTFail("expected failed state, got \(transport.state)")
        }
        XCTAssertTrue(reason.contains("abnormal"), "expected abnormal closure, got \(reason)")
    }

    // MARK: tool-in-flight extends the reconnect window

    /// A mid-flight tool call extends the reconnect window: a silent
    /// transport stays connected past the normal 1.8s window (but not past
    /// the extended 2.5s one).
    func testToolInFlightExtendsReconnectWindow() async throws {
        let server = try InProcessWebSocketServer(
            script: .init(onOpen: [Self.readyFrame()], onText: { _ in [] }))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort, livenessTiming: timing)
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        // Tool call starts (no completion will arrive — server is silent).
        server.sendText(eventFrame(type: "tool.start", sessionID: "s-1", seq: 1))

        // At the NORMAL stale point (1.8s + margin) the tool call keeps the
        // connection alive...
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertEqual(transport.state, .connected,
                       "tool-in-flight must extend the reconnect window past 1.8s")

        // ...but the extended window (2.5s) still tears down the dead transport.
        let torn = try await waitUntil(timeout: 5) { transport.state != .connected }
        XCTAssertTrue(torn, "extended window (2.5s) must still detect the dead transport")
        guard case .failed(let reason) = transport.state else {
            return XCTFail("expected failed state, got \(transport.state)")
        }
        XCTAssertTrue(reason.contains("abnormal"))
    }

    // MARK: malformed-frame (P1-4) behavior unchanged

    /// RT3/P1-4 unchanged: binary junk must NOT refresh liveness — the
    /// dead-transport detection still fires under a junk flood.
    func testBinaryJunkFloodStillDetectedAsDead() async throws {
        let server = try InProcessWebSocketServer(
            script: .init(onOpen: [Self.readyFrame()], onText: { _ in [] }))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort, livenessTiming: timing)
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        let junker = Task {
            while !Task.isCancelled {
                server.sendBinary(Data([0x00, 0x01, 0x02]))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { junker.cancel() }

        let torn = try await waitUntil(timeout: 5) { transport.state != .connected }
        XCTAssertTrue(torn, "junk frames must not refresh liveness — dead detection unchanged")
        guard case .failed(let reason) = transport.state else {
            return XCTFail("expected failed state, got \(transport.state)")
        }
        XCTAssertTrue(reason.contains("abnormal"))
    }

    // MARK: helpers (mirror GatewayWebSocketTransportTests)

    private static func readyFrame() -> String {
        #"{ "jsonrpc": "2.0", "method": "event", "params": { "type": "gateway.ready", "payload": { "change_events": true, "heartbeat": true, "replay_epoch": "epoch-1" } } }"#
    }

    private static func extractID(from frame: String) -> String? {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { return nil }
        return id
    }

    private static func pongFrame(id: String) -> String {
        #"{ "jsonrpc": "2.0", "id": "\#(id)", "result": { "ok": true } }"#
    }
}
