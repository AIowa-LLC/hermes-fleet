import XCTest
import FleetCore
import FleetNetworking

/// RPC request/response correlation on `GatewayWebSocketTransport` plus the
/// `GatewayRosterClient` (profiles.list / session.list) — M2.
///
/// All server interaction is against `InProcessWebSocketServer` fixtures; no
/// live Hermes gateway is touched.
final class RosterClientTests: XCTestCase {

    // MARK: helpers

    private func makeTransport(
        serverPort: UInt16,
        requestTimeout: Duration = .seconds(2),
        ticket: WSTicket = WSTicket(token: "fixture-ticket", ttlSeconds: 30)
    ) -> GatewayWebSocketTransport {
        let base = URL(string: "http://127.0.0.1:\(serverPort)")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30),
            inboundDeadline: .seconds(30),
            connectTimeout: .seconds(10),
            requestTimeout: requestTimeout
        )
        return GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTicketMinter(ticket: ticket),
            configuration: config
        )
    }

    /// Script that answers profiles.list / session.list / gateway.ping with
    /// realistic wire shapes (methods_profiles.py / methods_session.py).
    ///
    /// The payloads are pre-serialized to JSON strings (Sendable) so they can
    /// be captured by the `@Sendable` onText closure; the request id is echoed
    /// at runtime.
    private func rosterScript(
        profiles: [[String: Any]] = [[
            "name": "default", "path": "/home/t/.hermes", "is_default": true,
            "model": "deepseek-v4-flash", "provider": "nous",
            "description": "default profile", "display_name": "Default",
            "skill_count": 3, "has_avatar": false,
        ]],
        sessions: [[String: Any]] = [[
            "id": "sess-001", "title": "hello", "preview": "hi there",
            "started_at": 1_700_000_000, "message_count": 2, "source": "tui",
        ]]
    ) -> InProcessWebSocketServer.Script {
        let profilesJSON = Self.jsonArray(profiles)
        let sessionsJSON = Self.jsonArray(sessions)
        return InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                switch method {
                case "profiles.list":
                    return [Self.responseFrame(id: id, key: "profiles", arrayJSON: profilesJSON)]
                case "session.list":
                    return [Self.responseFrame(id: id, key: "sessions", arrayJSON: sessionsJSON)]
                case "gateway.ping":
                    return [Self.responseFrame(id: id, resultObject: #"{"ok":true}"#)]
                default:
                    return []
                }
            }
        )
    }

    private static func readyFrame() -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true,"heartbeat":false,"replay_epoch":"epoch-1"}}}"#
    }

    private static func extractRequest(_ frame: String) -> (id: String, method: String)? {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String else { return nil }
        return (id, method)
    }

    private static func jsonArray(_ array: [[String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: array)
        return String(data: data, encoding: .utf8)!
    }

    private static func responseFrame(id: String, result: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        return String(data: data, encoding: .utf8)!
    }

    /// `{"jsonrpc":"2.0","id":<id>,"result":{"<key>":<arrayJSON>}}`
    private static func responseFrame(id: String, key: String, arrayJSON: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","result":{"\#(key)":\#(arrayJSON)}}"#
    }

    /// `{"jsonrpc":"2.0","id":<id>,"result":<objectJSON>}`
    private static func responseFrame(id: String, resultObject: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","result":\#(resultObject)}}"#
    }

    // MARK: transport RPC correlation

    func testRequestReturnsCorrelatedResult() async throws {
        let server = try InProcessWebSocketServer(script: rosterScript())
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        let result = try await transport.request(method: "profiles.list", params: .object([:]))
        let profiles = result["profiles"]?.arrayValue
        XCTAssertEqual(profiles?.count, 1)
        XCTAssertEqual(profiles?.first?["name"]?.stringValue, "default")

        await transport.disconnect()
    }

    func testRequestTimesOutWhenGatewayIsSilent() async throws {
        // Server pushes ready but never answers RPC requests.
        let server = try InProcessWebSocketServer(script: .init(onOpen: [Self.readyFrame()]))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort, requestTimeout: .milliseconds(300))
        try await transport.connect()

        do {
            _ = try await transport.request(method: "profiles.list", params: .object([:]))
            XCTFail("expected requestTimeout")
        } catch let error as TransportError {
            XCTAssertEqual(error, .requestTimeout)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        await transport.disconnect()
    }

    func testRequestFailsOnTeardownInsteadOfHanging() async throws {
        // Server closes 1000 right after ready → pending request must throw a
        // classification, not hang forever.
        let server = try InProcessWebSocketServer(script: .init(onOpen: [Self.readyFrame()]))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()

        let requestTask = Task {
            try await transport.request(method: "profiles.list", params: .object([:]))
        }
        // Let the request send, then drop the socket.
        try await Task.sleep(for: .milliseconds(200))
        await transport.disconnect()

        do {
            _ = try await requestTask.value
            XCTFail("expected connectionClosed error")
        } catch let error as TransportError {
            guard case .connectionClosed = error else {
                return XCTFail("expected connectionClosed, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRequestFromDisconnectedTransportIsRejected() async {
        let transport = makeTransport(serverPort: 1) // never connected
        do {
            _ = try await transport.request(method: "profiles.list", params: .object([:]))
            XCTFail("expected invalidState")
        } catch let error as TransportError {
            guard case .invalidState = error else {
                return XCTFail("expected invalidState, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: roster client — profiles.list

    func testFetchProfilesDecodesRoster() async throws {
        let server = try InProcessWebSocketServer(script: rosterScript())
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayRosterClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let profiles = try await client.fetchProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].name, "default")
        XCTAssertEqual(profiles[0].model, "deepseek-v4-flash")
        XCTAssertEqual(profiles[0].provider, "nous")
        XCTAssertEqual(profiles[0].resolvedDisplayName, "Default")
    }

    /// P0-7: the server sends `gateway_running` per profile; the client must
    /// decode it (secondary "own gateway process" truth — never presence).
    func testFetchProfilesDecodesGatewayRunning() async throws {
        let script = rosterScript(profiles: [
            [
                "name": "default", "path": "/home/t/.hermes", "is_default": true,
                "model": "deepseek-v4-flash", "provider": "nous",
                "display_name": "Default", "skill_count": 3,
                "gateway_running": true,
            ],
            [
                "name": "researcher", "path": "/home/t/.hermes/profiles/researcher",
                "is_default": false, "model": "hermes", "provider": "openrouter",
                "gateway_running": false,
            ],
            [
                // Older gateways omit the key entirely — must default false.
                "name": "legacy", "path": "/home/t/.hermes/profiles/legacy",
            ],
        ])
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayRosterClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let profiles = try await client.fetchProfiles()
        XCTAssertEqual(profiles.count, 3)
        let byName = Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0) })
        XCTAssertEqual(byName["default"]?.gatewayRunning, true)
        XCTAssertEqual(byName["researcher"]?.gatewayRunning, false)
        XCTAssertEqual(byName["legacy"]?.gatewayRunning, false)
    }

    func testFetchProfilesNotConnectedThrows() async {
        let transport = makeTransport(serverPort: 1)
        let client = GatewayRosterClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.fetchProfiles()
            XCTFail("expected notConnected")
        } catch let error as RosterError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: roster client — session.list

    func testFetchSessionsSendsProfileParamAndDecodes() async throws {
        // Capture the session.list request to prove the profile slug is
        // scoped (the routing requirement: the profile half of the route).
        let captured = ParamCapture()

        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "session.list" {
                    if let data = frame.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let params = obj["params"] as? [String: Any] {
                        captured.record(params)
                    }
                    return [Self.responseFrame(
                        id: id,
                        result: ["sessions": [
                            ["id": "s1", "title": "hi", "preview": "", "started_at": 1, "last_active": 99, "message_count": 2, "source": "tui"]
                        ]])]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayRosterClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let route = Route(gatewayID: GatewayID(rawValue: "workstation"),
                          profileSlug: ProfileSlug(rawValue: "researcher"))
        let sessions = try await client.fetchSessions(for: route, limit: 50)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "s1")
        // FOS-5 (SPEC §10): session.list last_active decoded and preserved.
        XCTAssertEqual(sessions[0].lastActive, 99)

        XCTAssertEqual(captured.profile, "researcher", "session.list must be scoped to the route's profile slug")
        XCTAssertEqual(captured.limit, 50)
    }

    // MARK: M9 — route traversal guards fail closed

    func testFetchSessionsRejectsUnsafeRouteBeforeTransport() async {
        let client = GatewayRosterClient(
            gatewayID: GatewayID(rawValue: "workstation"),
            transport: makeTransport(serverPort: 1))
        let route = Route(gatewayID: GatewayID(rawValue: "workstation"),
                          profileSlug: ProfileSlug(rawValue: "../etc"))
        do {
            _ = try await client.fetchSessions(for: route, limit: 20)
            XCTFail("expected invalidRoute")
        } catch let error as RosterError {
            guard case .invalidRoute = error else {
                return XCTFail("expected invalidRoute, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFetchSessionsSafeRouteStillChecksConnection() async {
        let client = GatewayRosterClient(
            gatewayID: GatewayID(rawValue: "workstation"),
            transport: makeTransport(serverPort: 1))
        let route = Route(gatewayID: GatewayID(rawValue: "workstation"),
                          profileSlug: ProfileSlug(rawValue: "researcher"))
        do {
            _ = try await client.fetchSessions(for: route, limit: 20)
            XCTFail("expected notConnected")
        } catch let error as RosterError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: routing collision at transport level — A/default vs B/default

    func testRoutingCollisionDistinctAcrossTwoGateways() async throws {
        // Gateway A and Gateway B each serve a "default" profile. The roster
        // client bound to each gateway must return its OWN profile with its OWN
        // provenance — a same-named profile never bleeds across gateways.
        let scriptA = rosterScript(profiles: [
            ["name": "default", "path": "/home/a", "is_default": true, "model": "ma", "provider": "pa"]
        ])
        let scriptB = rosterScript(profiles: [
            ["name": "default", "path": "/home/b", "is_default": true, "model": "mb", "provider": "pb"]
        ])
        let serverA = try InProcessWebSocketServer(script: scriptA)
        let serverB = try InProcessWebSocketServer(script: scriptB)
        try await serverA.start()
        try await serverB.start()
        defer {
            serverA.stop()
            serverB.stop()
        }

        let transportA = makeTransport(serverPort: serverA.listeningPort)
        let transportB = makeTransport(serverPort: serverB.listeningPort)
        try await transportA.connect()
        try await transportB.connect()
        defer {
            Task { await transportA.disconnect() }
            Task { await transportB.disconnect() }
        }

        let gatewayA = GatewayID(rawValue: "gateway-a")
        let gatewayB = GatewayID(rawValue: "gateway-b")
        let clientA = GatewayRosterClient(gatewayID: gatewayA, transport: transportA)
        let clientB = GatewayRosterClient(gatewayID: gatewayB, transport: transportB)

        let profilesA = try await clientA.fetchProfiles()
        let profilesB = try await clientB.fetchProfiles()

        // Same slug, distinct owners.
        XCTAssertEqual(profilesA[0].name, "default")
        XCTAssertEqual(profilesB[0].name, "default")
        XCTAssertNotEqual(profilesA[0].path, profilesB[0].path)

        // Build the union roster exactly as the app will: bots stamped with
        // owning-gateway provenance from each gateway's descriptors.
        var roster = FleetRoster()
        roster.upsertGateway(FleetGateway(id: gatewayA, displayName: "A"))
        roster.upsertGateway(FleetGateway(id: gatewayB, displayName: "B"))
        roster.setBots(on: gatewayA, from: profilesA)
        roster.setBots(on: gatewayB, from: profilesB)

        let routeA = Route(gatewayID: gatewayA, profileSlug: ProfileSlug(rawValue: "default"))
        let routeB = Route(gatewayID: gatewayB, profileSlug: ProfileSlug(rawValue: "default"))

        let botA = try XCTUnwrap(roster.bot(for: routeA))
        let botB = try XCTUnwrap(roster.bot(for: routeB))
        XCTAssertNotEqual(botA, botB)
        XCTAssertEqual(botA.gatewayID, gatewayA)
        XCTAssertEqual(botB.gatewayID, gatewayB)
        XCTAssertEqual(roster.bots(on: gatewayA).count, 1)
        XCTAssertEqual(roster.bots(on: gatewayB).count, 1)
        // 2 gateways × 1 shared slug = 2 distinct bots in the union roster.
        XCTAssertEqual(roster.allBots.count, 2)
    }
}

/// Thread-safe capture of an RPC request's params, observed server-side.
final class ParamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _profile: String?
    private var _limit: Double?

    var profile: String? { lock.lock(); defer { lock.unlock() }; return _profile }
    var limit: Double? { lock.lock(); defer { lock.unlock() }; return _limit }

    func record(_ params: [String: Any]) {
        lock.lock()
        _profile = params["profile"] as? String
        _limit = params["limit"] as? Double
        lock.unlock()
    }
}
