import XCTest
import os
import FleetCore
import FleetNetworking

/// M8 Multi-Gateway Fleet Roster service tests (spec §31 Multi-Gateway +
/// §32 DoD): union roster across registered gateways preserving owning gateway,
/// one unreachable gateway does not break another, identical profile slugs on
/// two gateways stay distinct, and routing always targets the correct owner.
///
/// Happy paths run against the in-process WS fixture server (one server per
/// gateway, consistent with M1–M7); failure paths use scripted stub sessions
/// so the partial-outage classification is deterministic.
final class FleetRosterServiceTests: XCTestCase {

    private let gatewayA = GatewayID(rawValue: "workstation")
    private let gatewayB = GatewayID(rawValue: "arch")
    private let endpointA = URL(string: "http://127.0.0.1:8642")!
    private let endpointB = URL(string: "http://127.0.0.1:9900")!

    // MARK: helpers

    /// In-memory credential store local to this target (FleetNetworking must
    /// not depend on FleetSecurity — M0 module boundary).
    private final class TestCredentialStore: CredentialStoring, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
        func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
            lock.withLock { $0[gatewayID.rawValue] = credential.rawValue }
        }
        func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
            lock.withLock { $0[gatewayID.rawValue].map { GatewayCredential(rawValue: $0) } }
        }
        func deleteCredential(for gatewayID: GatewayID) async throws {
            lock.withLock { $0.removeValue(forKey: gatewayID.rawValue) }
        }
    }

    /// A scripted roster session whose connect either succeeds (ready adopted,
    /// optional profiles) or throws a scripted error, and which RECORDS
    /// `disconnect()` invocations so tests can assert teardown (ADR #3).
    private final class StubRosterSession: GatewayRosterSession, @unchecked Sendable {
        let gatewayID: GatewayID
        private let connectResult: Result<Void, GatewayConnectivityError>
        private let profiles: [ProfileDescriptor]
        private let ready: GatewayReadyAdoption?
        private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)

        init(
            gatewayID: GatewayID,
            connectResult: Result<Void, GatewayConnectivityError> = .success(()),
            profiles: [ProfileDescriptor] = [],
            ready: GatewayReadyAdoption? = nil
        ) {
            self.gatewayID = gatewayID
            self.connectResult = connectResult
            self.profiles = profiles
            self.ready = ready
        }

        var disconnectCount: Int { lock.withLock { $0 } }

        var status: GatewayStatus {
            switch connectResult {
            case .success: return .online
            case .failure(let error): return GatewayStatus(connectivityError: error)
            }
        }
        func adoptedReady() async -> GatewayReadyAdoption? { ready }
        func connect() async throws {
            if case .failure(let error) = connectResult { throw error }
        }
        func disconnect() async { lock.withLock { $0 += 1 } }
        func currentGateway() async -> FleetGateway {
            var g = FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
            if case .success = connectResult {
                g.capabilities = ready?.capabilities ?? []
                g.connectionState = .connected
            }
            return g
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] { profiles }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private func makeRegistry(
        credentials: CredentialStoring,
        sessionFactory: @escaping GatewayRosterSessionFactory
    ) async throws -> (GatewayRegistryService, FleetRosterService) {
        let registry = GatewayRegistryService(credentials: credentials) { gateway, _ in
            // The roster service drives sessions itself; the registry's own
            // probe factory is unused in these tests.
            StubRosterSession(gatewayID: gateway.id)
        }
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: sessionFactory
        )
        return (registry, roster)
    }

    private func profile(_ name: String, model: String? = nil, displayName: String? = nil) -> ProfileDescriptor {
        ProfileDescriptor(name: name, path: "/home/\(name)", model: model, displayName: displayName)
    }

    // MARK: union roster across two healthy gateways (spec §31: at least two
    // gateways can exist simultaneously)

    func testUnionRosterAcrossTwoHealthyGateways() async throws {
        // Gateway A serves default+researcher; Gateway B serves default+arch.
        let scriptA = rosterScript(profiles: [
            ["name": "default", "path": "/home/a/default", "is_default": true, "model": "ma"],
            ["name": "researcher", "path": "/home/a/researcher", "is_default": false, "model": "ra"],
        ])
        let scriptB = rosterScript(profiles: [
            ["name": "default", "path": "/home/b/default", "is_default": true, "model": "mb"],
            ["name": "arch", "path": "/home/b/arch", "is_default": false, "model": "ab"],
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
        let idA = gatewayA
        let idB = gatewayB
        let factory: GatewayRosterSessionFactory = { gateway, _ in
            if gateway.id == idA {
                return SingleGatewayConnection(
                    gatewayID: gateway.id, displayName: gateway.displayName,
                    endpoint: gateway.endpoint, transport: transportA)
            }
            return SingleGatewayConnection(
                gatewayID: gateway.id, displayName: gateway.displayName,
                endpoint: gateway.endpoint, transport: transportB)
        }

        let credentials = TestCredentialStore()
        let (registry, roster) = try await makeRegistry(credentials: credentials, sessionFactory: factory)
        _ = try await registry.addGateway(GatewayRegistration(id: idA, displayName: "MacBook", endpoint: endpointA))
        _ = try await registry.addGateway(GatewayRegistration(id: idB, displayName: "Arch", endpoint: endpointB))

        let snapshot = await roster.refreshRoster()

        // Both gateways loaded; outcomes reflect profile counts.
        XCTAssertEqual(snapshot.outcome(for: gatewayA), .loaded(profileCount: 2))
        XCTAssertEqual(snapshot.outcome(for: gatewayB), .loaded(profileCount: 2))
        XCTAssertEqual(snapshot.reachableGateways.map(\.id), [gatewayB, gatewayA])
        XCTAssertTrue(snapshot.unreachableGateways.isEmpty)

        // Union roster: 4 bots, owning gateway preserved.
        XCTAssertEqual(snapshot.roster.allBots.count, 4)
        XCTAssertEqual(snapshot.bots(on: gatewayA).map(\.profileSlug.rawValue).sorted(), ["default", "researcher"])
        XCTAssertEqual(snapshot.bots(on: gatewayB).map(\.profileSlug.rawValue).sorted(), ["arch", "default"])

        // Routing targets the correct owner for identical slugs.
        let routeA = Route(gatewayID: gatewayA, profileSlug: ProfileSlug(rawValue: "default"))
        let routeB = Route(gatewayID: gatewayB, profileSlug: ProfileSlug(rawValue: "default"))
        XCTAssertEqual(snapshot.bot(for: routeA)?.gatewayID, gatewayA)
        XCTAssertEqual(snapshot.bot(for: routeB)?.gatewayID, gatewayB)
        XCTAssertEqual(snapshot.bot(for: routeA)?.model, "ma")
        XCTAssertEqual(snapshot.bot(for: routeB)?.model, "mb")
        XCTAssertNotEqual(snapshot.bot(for: routeA), snapshot.bot(for: routeB))
    }

    func testIdenticallyNamedProfilesRemainDistinct() async throws {
        // Minimal collision case: both gateways serve ONLY a "default" profile.
        let scriptA = rosterScript(profiles: [["name": "default", "path": "/home/a"]])
        let scriptB = rosterScript(profiles: [["name": "default", "path": "/home/b"]])
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
        let idA = gatewayA
        let idB = gatewayB
        let factory: GatewayRosterSessionFactory = { gateway, _ in
            if gateway.id == idA {
                return SingleGatewayConnection(gatewayID: gateway.id, displayName: "A", endpoint: nil, transport: transportA)
            }
            return SingleGatewayConnection(gatewayID: gateway.id, displayName: "B", endpoint: nil, transport: transportB)
        }

        let credentials = TestCredentialStore()
        let (registry, roster) = try await makeRegistry(credentials: credentials, sessionFactory: factory)
        _ = try await registry.addGateway(GatewayRegistration(id: idA, displayName: "A", endpoint: endpointA))
        _ = try await registry.addGateway(GatewayRegistration(id: idB, displayName: "B", endpoint: endpointB))

        let snapshot = await roster.refreshRoster()
        XCTAssertEqual(snapshot.roster.allBots.count, 2, "2 gateways × shared 'default' slug = 2 distinct bots")
        let routeA = Route(gatewayID: gatewayA, profileSlug: ProfileSlug(rawValue: "default"))
        let routeB = Route(gatewayID: gatewayB, profileSlug: ProfileSlug(rawValue: "default"))
        XCTAssertEqual(snapshot.bot(for: routeA)?.gatewayID, gatewayA)
        XCTAssertEqual(snapshot.bot(for: routeB)?.gatewayID, gatewayB)
    }

    // MARK: partial outage — one unreachable gateway must not break another

    func testOneUnreachableGatewayDoesNotBreakAnother() async throws {
        // Gateway A is unreachable (scripted failure); gateway B is healthy
        // (in-process server). The refresh must not throw; B's bots must be
        // present; A must be classified offline.
        let scriptB = rosterScript(profiles: [["name": "default", "path": "/home/b"]])
        let serverB = try InProcessWebSocketServer(script: scriptB)
        try await serverB.start()
        defer { serverB.stop() }

        let transportB = makeTransport(serverPort: serverB.listeningPort)
        let idA = gatewayA
        let idB = gatewayB
        let factory: GatewayRosterSessionFactory = { gateway, _ in
            if gateway.id == idA {
                return StubRosterSession(gatewayID: gateway.id, connectResult: .failure(.unreachable))
            }
            return SingleGatewayConnection(gatewayID: gateway.id, displayName: "B", endpoint: nil, transport: transportB)
        }

        let credentials = TestCredentialStore()
        let (registry, roster) = try await makeRegistry(credentials: credentials, sessionFactory: factory)
        _ = try await registry.addGateway(GatewayRegistration(id: idA, displayName: "MacBook", endpoint: endpointA))
        _ = try await registry.addGateway(GatewayRegistration(id: idB, displayName: "Arch", endpoint: endpointB))

        let snapshot = await roster.refreshRoster()

        // Partial availability: B loaded, A classified offline.
        XCTAssertEqual(snapshot.outcome(for: gatewayA), .failed(status: .offline, detail: "gateway unreachable"))
        XCTAssertEqual(snapshot.outcome(for: gatewayB), .loaded(profileCount: 1))
        XCTAssertEqual(snapshot.reachableGateways.map(\.id), [gatewayB])
        XCTAssertEqual(snapshot.unreachableGateways.map(\.id), [gatewayA])

        // B's bots are present and routable; A has no bots (fail closed).
        XCTAssertEqual(snapshot.bots(on: gatewayB).count, 1)
        XCTAssertTrue(snapshot.bots(on: gatewayA).isEmpty)
        let routeB = Route(gatewayID: gatewayB, profileSlug: ProfileSlug(rawValue: "default"))
        XCTAssertEqual(snapshot.bot(for: routeB)?.gatewayID, gatewayB)

        // A's gateway entry reflects its last-known state (spec §30).
        XCTAssertEqual(snapshot.roster.gateway(for: gatewayA)?.connectionState, .failed("offline"))
    }

    func testOneGatewayAuthenticationRequiredDoesNotBreakAnother() async throws {
        let scriptB = rosterScript(profiles: [["name": "default", "path": "/home/b"]])
        let serverB = try InProcessWebSocketServer(script: scriptB)
        try await serverB.start()
        defer { serverB.stop() }

        let transportB = makeTransport(serverPort: serverB.listeningPort)
        let idA = gatewayA
        let idB = gatewayB
        let factory: GatewayRosterSessionFactory = { gateway, _ in
            if gateway.id == idA {
                return StubRosterSession(gatewayID: gateway.id, connectResult: .failure(.authenticationRequired))
            }
            return SingleGatewayConnection(gatewayID: gateway.id, displayName: "B", endpoint: nil, transport: transportB)
        }

        let credentials = TestCredentialStore()
        let (registry, roster) = try await makeRegistry(credentials: credentials, sessionFactory: factory)
        _ = try await registry.addGateway(GatewayRegistration(id: idA, displayName: "MacBook", endpoint: endpointA))
        _ = try await registry.addGateway(GatewayRegistration(id: idB, displayName: "Arch", endpoint: endpointB))

        let snapshot = await roster.refreshRoster()
        XCTAssertEqual(snapshot.outcome(for: gatewayA), .failed(status: .authenticationRequired, detail: "authentication required"))
        XCTAssertEqual(snapshot.outcome(for: gatewayB), .loaded(profileCount: 1))
        XCTAssertEqual(snapshot.bots(on: gatewayB).count, 1)
    }

    func testOneGatewayTimeoutDoesNotBreakAnother() async throws {
        let scriptB = rosterScript(profiles: [["name": "default", "path": "/home/b"]])
        let serverB = try InProcessWebSocketServer(script: scriptB)
        try await serverB.start()
        defer { serverB.stop() }

        let transportB = makeTransport(serverPort: serverB.listeningPort)
        let idA = gatewayA
        let idB = gatewayB
        let factory: GatewayRosterSessionFactory = { gateway, _ in
            if gateway.id == idA {
                return StubRosterSession(gatewayID: gateway.id, connectResult: .failure(.timeout))
            }
            return SingleGatewayConnection(gatewayID: gateway.id, displayName: "B", endpoint: nil, transport: transportB)
        }

        let credentials = TestCredentialStore()
        let (registry, roster) = try await makeRegistry(credentials: credentials, sessionFactory: factory)
        _ = try await registry.addGateway(GatewayRegistration(id: idA, displayName: "MacBook", endpoint: endpointA))
        _ = try await registry.addGateway(GatewayRegistration(id: idB, displayName: "Arch", endpoint: endpointB))

        let snapshot = await roster.refreshRoster()
        XCTAssertEqual(snapshot.outcome(for: gatewayA), .failed(status: .offline, detail: "gateway connect timed out"))
        XCTAssertEqual(snapshot.outcome(for: gatewayB), .loaded(profileCount: 1))
    }

    // MARK: empty registry

    func testEmptyRegistryYieldsEmptySnapshotWithoutThrowing() async throws {
        let credentials = TestCredentialStore()
        let factory: GatewayRosterSessionFactory = { gateway, _ in
            StubRosterSession(gatewayID: gateway.id)
        }
        let (_, roster) = try await makeRegistry(credentials: credentials, sessionFactory: factory)
        let snapshot = await roster.refreshRoster()
        XCTAssertTrue(snapshot.roster.allGateways.isEmpty)
        XCTAssertTrue(snapshot.roster.allBots.isEmpty)
        XCTAssertTrue(snapshot.gatewayOutcomes.isEmpty)
    }

    // MARK: credential flows to the session factory (auth config)

    func testStoredCredentialFlowsToSessionFactory() async throws {
        final class ObservedBox: @unchecked Sendable {
            var value: String?
        }
        let observed = ObservedBox()
        let factory: GatewayRosterSessionFactory = { gateway, credential in
            observed.value = credential?.rawValue
            return StubRosterSession(gatewayID: gateway.id)
        }
        let credentials = TestCredentialStore()
        let (registry, roster) = try await makeRegistry(credentials: credentials, sessionFactory: factory)
        _ = try await registry.addGateway(GatewayRegistration(id: gatewayA, displayName: "MacBook", endpoint: endpointA))
        try await registry.saveCredential(GatewayCredential(rawValue: "stored-token"), for: gatewayA)

        _ = await roster.refreshRoster()
        XCTAssertEqual(observed.value, "stored-token", "the stored credential flows to the roster session factory")
    }

    // MARK: teardown — the probe session is ALWAYS disconnected (ADR #3)

    func testRosterSessionTornDownOnSuccess() async throws {
        let script = rosterScript(profiles: [["name": "default", "path": "/home/a"]])
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        let session = SingleGatewayConnection(gatewayID: gatewayA, displayName: "MacBook", endpoint: nil, transport: transport)
        let factory: GatewayRosterSessionFactory = { gateway, _ in session }
        let credentials = TestCredentialStore()
        let (registry, roster) = try await makeRegistry(credentials: credentials, sessionFactory: factory)
        _ = try await registry.addGateway(GatewayRegistration(id: gatewayA, displayName: "MacBook", endpoint: endpointA))

        let snapshot = await roster.refreshRoster()
        XCTAssertEqual(snapshot.outcome(for: gatewayA), .loaded(profileCount: 1))
        // The probe must have torn its socket down: transport reached a
        // terminal (disconnected) state rather than being abandoned.
        XCTAssertEqual(transport.state, .disconnected,
            "roster refresh must tear down its probe connection before returning")
    }

    func testRosterSessionTornDownOnFailure() async throws {
        let recording = StubRosterSession(gatewayID: gatewayA, connectResult: .failure(.unreachable))
        let factory: GatewayRosterSessionFactory = { gateway, _ in recording }
        let credentials = TestCredentialStore()
        let (registry, roster) = try await makeRegistry(credentials: credentials, sessionFactory: factory)
        _ = try await registry.addGateway(GatewayRegistration(id: gatewayA, displayName: "MacBook", endpoint: endpointA))

        _ = await roster.refreshRoster()
        XCTAssertEqual(recording.disconnectCount, 1,
            "roster refresh must tear down its probe session on the failure path too")
    }

    // MARK: gateway entry reflects adopted ready metadata (server authoritative)

    func testGatewayEntryAdoptsCapabilitiesAndReplayEpoch() async throws {
        let readyFrame = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true,"heartbeat":true,"replay_epoch":"epoch-9"}}}"#
        let script = InProcessWebSocketServer.Script(
            onOpen: [readyFrame],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "profiles.list" {
                    return [Self.responseFrame(id: id, key: "profiles", arrayJSON: #"[{"name":"default","path":"/home/a"}]"#)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        let factory: GatewayRosterSessionFactory = { gateway, _ in
            SingleGatewayConnection(gatewayID: gateway.id, displayName: "MacBook", endpoint: nil, transport: transport)
        }
        let credentials = TestCredentialStore()
        let (registry, roster) = try await makeRegistry(credentials: credentials, sessionFactory: factory)
        _ = try await registry.addGateway(GatewayRegistration(id: gatewayA, displayName: "MacBook", endpoint: endpointA))

        let snapshot = await roster.refreshRoster()
        let entry = try XCTUnwrap(snapshot.roster.gateway(for: gatewayA))
        XCTAssertEqual(entry.connectionState, .connected)
        XCTAssertEqual(entry.capabilities, ["heartbeat", "change_events"])
        XCTAssertEqual(entry.replayEpoch, "epoch-9")
    }

    // MARK: fixture script helpers (mirror RosterClientTests)

    private func rosterScript(
        profiles: [[String: Any]]
    ) -> InProcessWebSocketServer.Script {
        let profilesJSON = Self.jsonArray(profiles)
        return InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                switch method {
                case "profiles.list":
                    return [Self.responseFrame(id: id, key: "profiles", arrayJSON: profilesJSON)]
                case "gateway.ping":
                    return [Self.responseFrame(id: id, resultObject: #"{"ok":true}"#)]
                default:
                    return []
                }
            }
        )
    }

    private func makeTransport(
        serverPort: UInt16,
        requestTimeout: Duration = .seconds(2)
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
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: config
        )
    }

    private static func readyFrame() -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":false,"heartbeat":false,"replay_epoch":"epoch-1"}}}"#
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

    private static func responseFrame(id: String, key: String, arrayJSON: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","result":{"\#(key)":\#(arrayJSON)}}"#
    }

    private static func responseFrame(id: String, resultObject: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","result":\#(resultObject)}}"#
    }
}
