import XCTest
import FleetCore
import FleetNetworking

/// M3 One-Gateway Connectivity acceptance (spec §31 Gateway):
/// connect one stock Hermes gateway, reachable/unreachable state,
/// `gateway.ready` adoption, and "disconnect does not crash".
///
/// All server interaction is against `InProcessWebSocketServer` fixtures; no
/// live Hermes gateway is touched (consistent with M1/M2).
final class SingleGatewayConnectionTests: XCTestCase {

    /// A connection bound to an in-process server port with the given gateway id.
    private func makeConnection(
        serverPort: UInt16,
        gatewayID: GatewayID = GatewayID(rawValue: "workstation"),
        connectTimeout: Duration = .seconds(10)
    ) -> SingleGatewayConnection {
        let base = URL(string: "http://127.0.0.1:\(serverPort)")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30),
            inboundDeadline: .seconds(30),
            connectTimeout: connectTimeout,
            requestTimeout: .seconds(10)
        )
        let transport = GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: config
        )
        return SingleGatewayConnection(
            gatewayID: gatewayID,
            displayName: "MacBook",
            endpoint: base,
            transport: transport
        )
    }

    /// Scripted ready frame with adoption-relevant fields.
    private func readyFrame(replayEpoch: String = "epoch-1") -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{},"change_events":true,"heartbeat":true,"replay_epoch":"\#(replayEpoch)"}}}"#
    }

    // MARK: connect → gateway.ready adoption → online

    func testConnectAdoptsReadyAndReachesOnline() async throws {
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

        let connection = makeConnection(serverPort: server.listeningPort)
        XCTAssertEqual(connection.status, .offline, "new connection starts offline")

        try await connection.connect()
        XCTAssertEqual(connection.status, .online, "ready adoption flips to online")

        // gateway.ready adoption surfaced on the seam.
        let ready = await connection.adoptedReady()
        XCTAssertEqual(ready?.replayEpoch, "epoch-1")
        XCTAssertTrue(ready?.heartbeatEnabled == true)
        XCTAssertTrue(ready?.changeEventsEnabled == true)
        XCTAssertEqual(ready?.capabilities, ["heartbeat", "change_events"])
    }

    func testCurrentGatewayReflectsAdoptedMetadata() async throws {
        let server = try InProcessWebSocketServer(script: .init(onOpen: [readyFrame()]))
        try await server.start()
        defer { server.stop() }

        let connection = makeConnection(serverPort: server.listeningPort)
        try await connection.connect()

        let gateway = await connection.currentGateway()
        XCTAssertEqual(gateway.id.rawValue, "workstation")
        XCTAssertEqual(gateway.connectionState, .connected)
        XCTAssertEqual(gateway.replayEpoch, "epoch-1")
        XCTAssertEqual(gateway.capabilities, ["heartbeat", "change_events"])
        XCTAssertTrue(gateway.authConfigured, "ready handshake implies authenticated")
    }

    // MARK: reachable / unreachable state

    func testUnreachableEndpointMapsToUnreachableError() async throws {
        // No listener on this port → connect must classify, not hang.
        let server = try InProcessWebSocketServer(script: .init())
        try await server.start()
        let port = server.listeningPort
        server.stop() // close the only listener

        let connection = makeConnection(serverPort: port, connectTimeout: .seconds(2))
        do {
            try await connection.connect()
            XCTFail("expected unreachable")
        } catch let error as GatewayConnectivityError {
            XCTAssertEqual(error, .unreachable)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertNotEqual(connection.status, .online)
    }

    func testReadyTimeoutMapsToTimeoutError() async throws {
        // Server accepts but never sends gateway.ready → connect must time out.
        let server = try InProcessWebSocketServer(script: .init())
        try await server.start()
        defer { server.stop() }

        let connection = makeConnection(serverPort: server.listeningPort, connectTimeout: .milliseconds(400))
        do {
            try await connection.connect()
            XCTFail("expected ready timeout")
        } catch let error as GatewayConnectivityError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertNotEqual(connection.status, .online, "must not be left online after failed handshake")
    }

    /// D1 regression (M13 HOLD): a socket that dies during the ready handshake
    /// must map to `.unreachable` deterministically — even when the receive-loop
    /// teardown is still in flight (suspended at the blocking `close()`) at the
    /// instant `waitForReady()` classifies the failure. Pre-fix this sampled
    /// `.connecting` and mapped `.timeout` instead of `.unreachable`.
    func testSocketDeathDuringHandshakeIsUnreachableNotTimeout() async throws {
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
        let connection = SingleGatewayConnection(
            gatewayID: GatewayID(rawValue: "workstation"),
            displayName: "MacBook",
            endpoint: base,
            transport: transport
        )
        do {
            try await connection.connect()
            XCTFail("expected unreachable, got success")
        } catch let error as GatewayConnectivityError {
            XCTAssertEqual(error, .unreachable)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testServerClose4401MapsAuthenticationRequired() async throws {
        let server = try InProcessWebSocketServer(script: .init(onOpen: [readyFrame()]))
        try await server.start()
        defer { server.stop() }

        let connection = makeConnection(serverPort: server.listeningPort)
        try await connection.connect()
        XCTAssertEqual(connection.status, .online)

        server.sendClose(code: 4401)
        let deadline = Date().addingTimeInterval(3)
        while connection.status == .online && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(connection.status, .authenticationRequired)
    }

    func testServerClose1000MapsOffline() async throws {
        let server = try InProcessWebSocketServer(script: .init(onOpen: [readyFrame()]))
        try await server.start()
        defer { server.stop() }

        let connection = makeConnection(serverPort: server.listeningPort)
        try await connection.connect()
        XCTAssertEqual(connection.status, .online)

        server.sendClose(code: 1000)
        let deadline = Date().addingTimeInterval(3)
        while connection.status == .online && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(connection.status, .offline)
    }

    // MARK: disconnect does not crash (spec §31)

    func testDisconnectBeforeConnectDoesNotCrash() async {
        // No server: the connection is constructed but never connected.
        let connection = makeConnection(serverPort: 1)
        // disconnect() with no connection established: must not crash.
        await connection.disconnect()
        XCTAssertEqual(connection.status, .offline)
    }

    func testDoubleDisconnectDoesNotCrash() async throws {
        let server = try InProcessWebSocketServer(script: .init(onOpen: [readyFrame()]))
        try await server.start()
        defer { server.stop() }

        let connection = makeConnection(serverPort: server.listeningPort)
        try await connection.connect()
        XCTAssertEqual(connection.status, .online)

        await connection.disconnect()
        await connection.disconnect() // second teardown is a no-op, not a crash
        XCTAssertEqual(connection.status, .offline)
    }

    func testDisconnectAfterServerCloseDoesNotCrash() async throws {
        let server = try InProcessWebSocketServer(script: .init(onOpen: [readyFrame()]))
        try await server.start()
        defer { server.stop() }

        let connection = makeConnection(serverPort: server.listeningPort)
        try await connection.connect()
        XCTAssertEqual(connection.status, .online)

        server.sendClose(code: 1006) // abnormal server-side drop
        let deadline = Date().addingTimeInterval(3)
        while connection.status == .online && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotEqual(connection.status, .online)

        await connection.disconnect() // disconnect from a failed state: no crash
        XCTAssertEqual(connection.status, .offline)
    }

    func testConnectFromAlreadyConnectedIsIdempotentNoOp() async throws {
        // P0-7: re-entering a conversation re-runs the connect flow against
        // the still-open shared connection — must succeed without a second
        // socket.
        let server = try InProcessWebSocketServer(script: .init(onOpen: [readyFrame()]))
        try await server.start()
        defer { server.stop() }

        let connection = makeConnection(serverPort: server.listeningPort)
        try await connection.connect()
        XCTAssertEqual(connection.status, .online)

        try await connection.connect()
        XCTAssertEqual(connection.status, .online)
        XCTAssertEqual(server.connectionCount, 1,
                       "idempotent connect must not open a second connection")

        await connection.disconnect()
    }

    // MARK: helpers (mirror the transport test module's scripted frame builders)

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
