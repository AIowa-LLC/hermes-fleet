import XCTest
import FleetCore
import FleetNetworking

/// H2 Connection health dashboard — transport health-event stream tests.
///
/// Prove the transport emits `.connectStarted` / `.connected` /
/// `.disconnected(reason)` / `.pingRTT(ms)` observations that the FleetCore
/// accumulator consumes, against the in-process fixture server.

/// Thread-safe collector for the health event stream.
private final class HealthEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ConnectionHealthEvent] = []
    var all: [ConnectionHealthEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return events.count
    }
    func append(_ event: ConnectionHealthEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }
    /// Wait until the collector holds at least `count` events (bounded).
    func waitFor(count target: Int, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while count < target && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

final class ConnectionHealthEventTests: XCTestCase {

    private func makeTransport(
        serverPort: UInt16,
        pingInterval: Duration = .seconds(30),
        inboundDeadline: Duration = .seconds(30),
        connectTimeout: Duration = .seconds(10)
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
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: config
        )
    }

    func testConnectDisconnectEmitsLifecycleEvents() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [readyFrame()],
            onText: { frame in
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
        let collector = HealthEventCollector()
        let events = transport.subscribeToHealthEvents()
        Task {
            for await event in events {
                collector.append(event)
            }
        }

        try await transport.connect()
        collector.waitFor(count: 2)
        XCTAssertEqual(transport.state, .connected)
        XCTAssertEqual(collector.all, [.connectStarted, .connected],
                       "connect emits connectStarted then connected")

        await transport.disconnect()
        collector.waitFor(count: 3)
        XCTAssertEqual(collector.all.last, .disconnected(reason: "normal closure"),
                       "clean disconnect emits the classified reason")
    }

    func testHeartbeatPingEmitsRTTEvent() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [readyFrame()],
            onText: { frame in
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

        let transport = makeTransport(
            serverPort: server.listeningPort, pingInterval: .milliseconds(100))
        let collector = HealthEventCollector()
        let events = transport.subscribeToHealthEvents()
        Task {
            for await event in events {
                collector.append(event)
            }
        }

        try await transport.connect()
        // Let a couple of heartbeat intervals elapse so a pong arrives.
        let deadline = Date().addingTimeInterval(3)
        while !collector.all.contains(where: { if case .pingRTT = $0 { return true }; return false })
                && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        guard let rtt = collector.all.first(where: { if case .pingRTT = $0 { return true }; return false }) else {
            return XCTFail("expected at least one .pingRTT health event")
        }
        guard case .pingRTT(let milliseconds) = rtt else { return XCTFail("unreachable") }
        XCTAssertGreaterThanOrEqual(milliseconds, 0, "RTT must be non-negative")

        await transport.disconnect()
    }

    func testFailedHandshakeEmitsDisconnectedEvent() async throws {
        // Server opens but never sends gateway.ready → connect fails.
        let server = try InProcessWebSocketServer(script: .init())
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(
            serverPort: server.listeningPort, connectTimeout: .milliseconds(500))
        let collector = HealthEventCollector()
        let events = transport.subscribeToHealthEvents()
        Task {
            for await event in events {
                collector.append(event)
            }
        }

        do {
            try await transport.connect()
            XCTFail("expected ready timeout")
        } catch let error as TransportError {
            XCTAssertEqual(error, .readyTimeout)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        collector.waitFor(count: 2)
        XCTAssertEqual(collector.all.first, .connectStarted)
        XCTAssertEqual(collector.all.last, .disconnected(reason: "abnormal closure"),
                       "failed handshake classifies the disconnect reason")
    }

    func testServerClose4401EmitsReauthDisconnect() async throws {
        let script = InProcessWebSocketServer.Script(onOpen: [readyFrame()])
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        let collector = HealthEventCollector()
        let events = transport.subscribeToHealthEvents()
        Task {
            for await event in events {
                collector.append(event)
            }
        }

        try await transport.connect()
        server.sendClose(code: 4401)

        let deadline = Date().addingTimeInterval(3)
        while collector.all.last != .disconnected(reason: "reauthentication required (4401)")
                && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(collector.all.last, .disconnected(reason: "reauthentication required (4401)"),
                       "4401 maps to the reauth disconnect reason")

        await transport.disconnect()
    }

    // MARK: helpers (mirror the transport test suite)

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
