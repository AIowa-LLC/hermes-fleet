import XCTest
import os
import FleetCore
import FleetNetworking

/// U2 `session.list` read path (`GatewaySessionListService`) tests: the
/// read-only sessions seam a Bot-detail screen drives.
///
/// Happy path runs against the in-process WS fixture server (consistent with
/// M1–M8); fail-closed paths use scripted stub sessions so classification is
/// deterministic. Asserts ADR #3 probe teardown on the success path and the
/// M9 routing guard.
final class GatewaySessionListServiceTests: XCTestCase {

    private let gatewayA = GatewayID(rawValue: "workstation")

    // MARK: helpers

    /// An in-memory credential store local to this test target (FleetNetworking
    /// must not depend on FleetSecurity — M0 module boundary).
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

    /// A stub registry in-memory (the service only needs `gateway(for:)`).
    private final class TestRegistry: GatewayRegistryManaging, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[String: FleetGateway]>(initialState: [:])
        func register(_ gateway: FleetGateway) {
            lock.withLock { $0[gateway.id.rawValue] = gateway }
        }
        func allGateways() async -> [FleetGateway] {
            lock.withLock { Array($0.values).sorted { $0.id.rawValue < $1.id.rawValue } }
        }
        func gateway(for id: GatewayID) async -> FleetGateway? {
            lock.withLock { $0[id.rawValue] }
        }
        func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway {
            let gateway = FleetGateway(
                id: registration.id ?? GatewayID(endpoint: registration.endpoint),
                displayName: registration.displayName,
                endpoint: registration.endpoint,
                authConfiguration: registration.authConfiguration)
            register(gateway)
            return gateway
        }
        func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
            let current = await gateway(for: id)
            guard var gateway = current else { throw GatewayRegistryError.notFound(id) }
            gateway = edits.applied(to: gateway)
            register(gateway)
            return gateway
        }
        func removeGateway(_ id: GatewayID) async throws {
            lock.withLock { $0.removeValue(forKey: id.rawValue) }
        }
        func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {}
        func clearCredential(for id: GatewayID) async throws {}
        func hasCredential(for id: GatewayID) async -> Bool { false }
        func testConnection(to id: GatewayID) async throws -> GatewayTestResult {
            GatewayTestResult(status: .offline)
        }
    }

    /// A stub roster session that records `disconnect()` invocations so tests
    /// can assert ADR #3 teardown on every exit path.
    private final class RecordingRosterSession: GatewayRosterSession, @unchecked Sendable {
        let gatewayID: GatewayID
        let sessions: [SessionSummary]
        let connectError: GatewayConnectivityError?
        let fetchError: RosterError?
        private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)

        init(
            gatewayID: GatewayID,
            sessions: [SessionSummary] = [],
            connectError: GatewayConnectivityError? = nil,
            fetchError: RosterError? = nil
        ) {
            self.gatewayID = gatewayID
            self.sessions = sessions
            self.connectError = connectError
            self.fetchError = fetchError
        }

        var disconnectCount: Int { lock.withLock { $0 } }
        var status: GatewayStatus { connectError == nil ? .online : .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {
            if let connectError { throw connectError }
        }
        func disconnect() async { lock.withLock { $0 += 1 } }
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] { [] }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
            if let fetchError { throw fetchError }
            return sessions
        }
    }

    private func route(_ slug: String = "default") -> Route {
        Route(gatewayID: gatewayA, profileSlug: ProfileSlug(rawValue: slug))
    }

    private func makeService(
        registry: TestRegistry,
        sessionFactory: @escaping GatewayRosterSessionFactory
    ) -> GatewaySessionListService {
        GatewaySessionListService(
            registry: registry,
            credentials: TestCredentialStore(),
            sessionFactory: sessionFactory)
    }

    private func registerGateway(_ registry: TestRegistry) async throws {
        _ = try await registry.addGateway(GatewayRegistration(
            id: gatewayA, displayName: "MacBook",
            endpoint: URL(string: "http://127.0.0.1:8642")!))
    }

    // MARK: happy path — in-process server + ADR #3 teardown

    func testFetchSessionsHappyPathOverInProcessServer() async throws {
        // Real in-process server answering session.list with the verified
        // wire shape (methods_session.py). The response echoes the request id
        // so the transport's correlation resolves (ids are "rpc-N").
        let readyFrame = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{},"change_events":true,"heartbeat":true,"replay_epoch":"epoch-9"}}}"#
        let script = InProcessWebSocketServer.Script(
            onOpen: [readyFrame],
            onText: { frame in
                guard let id = Self.extractRequestID(frame) else { return [] }
                let sessionsJSON = #"[{"id":"s1","title":"hello","preview":"hi","started_at":1700000000,"message_count":2,"source":"tui"}]"#
                return [Self.sessionsResponse(id: id, sessionsJSON: sessionsJSON)]
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(server.listeningPort)")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30), inboundDeadline: .seconds(30),
            connectTimeout: .seconds(10), requestTimeout: .seconds(10))
        let transport = GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTestTicketMinter(),
            configuration: config)
        let registry = TestRegistry()
        try await registerGateway(registry)
        let service = makeService(registry: registry) { gateway, _ in
            SingleGatewayConnection(
                gatewayID: gateway.id, displayName: gateway.displayName,
                endpoint: gateway.endpoint, transport: transport)
        }

        let sessions = try await service.fetchSessions(for: route(), limit: 50)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "s1")
        XCTAssertEqual(sessions[0].title, "hello")
        // ADR #3 — the probe torn down its connection before returning.
        XCTAssertEqual(transport.state, .disconnected,
            "fetchSessions must tear down the probe connection before returning")
    }

    /// Extract the JSON-RPC request id from an inbound frame (echoed back so
    /// the transport's correlation resolves).
    private static func extractRequestID(_ frame: String) -> String? {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { return nil }
        return id
    }

    /// `{"jsonrpc":"2.0","id":<id>,"result":{"sessions":<arrayJSON>}}`
    private static func sessionsResponse(id: String, sessionsJSON: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","result":{"sessions":\#(sessionsJSON)}}"#
    }

    // MARK: fail closed — registry, routing guard, connectivity

    func testFetchSessionsUnknownGatewayThrowsNotFound() async {
        let registry = TestRegistry()  // no gateways registered
        let service = makeService(registry: registry) { gateway, _ in
            RecordingRosterSession(gatewayID: gateway.id)
        }
        do {
            _ = try await service.fetchSessions(for: route(), limit: 20)
            XCTFail("expected gatewayNotFound")
        } catch let error as RosterError {
            XCTAssertEqual(error, .gatewayNotFound(gatewayA))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFetchSessionsRejectsUnsafeRouteBeforeAnyRPC() async {
        let registry = TestRegistry()
        try! await registerGateway(registry)
        // A session factory that would blow up if the transport were touched —
        // the M9 guard must reject the unsafe route first.
        let service = makeService(registry: registry) { gateway, _ in
            RecordingRosterSession(gatewayID: gateway.id)
        }
        let unsafeRoute = Route(
            gatewayID: gatewayA,
            profileSlug: ProfileSlug(rawValue: "../etc"))
        do {
            _ = try await service.fetchSessions(for: unsafeRoute, limit: 20)
            XCTFail("expected invalidRoute")
        } catch let error as RosterError {
            guard case .invalidRoute = error else {
                return XCTFail("expected invalidRoute, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFetchSessionsConnectFailureClassifiesNotConnected() async {
        let registry = TestRegistry()
        try! await registerGateway(registry)
        let session = RecordingRosterSession(
            gatewayID: gatewayA, connectError: .unreachable)
        let service = makeService(registry: registry) { _, _ in session }

        do {
            _ = try await service.fetchSessions(for: route(), limit: 20)
            XCTFail("expected notConnected")
        } catch let error as RosterError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFetchSessionsFailurePathTearsDownProbe() async {
        // A classified read failure must also tear the probe session down
        // (ADR #3) — no path abandons an open socket.
        let registry = TestRegistry()
        try! await registerGateway(registry)
        let session = RecordingRosterSession(
            gatewayID: gatewayA, fetchError: .notConnected)
        let service = makeService(registry: registry) { _, _ in session }

        do {
            _ = try await service.fetchSessions(for: route(), limit: 20)
            XCTFail("expected notConnected")
        } catch let error as RosterError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(session.disconnectCount, 1,
            "fetchSessions must tear down the probe on the failure path too")
    }

    func testFetchSessionsSuccessPathTearsDownProbe() async throws {
        let registry = TestRegistry()
        try! await registerGateway(registry)
        let session = RecordingRosterSession(
            gatewayID: gatewayA,
            sessions: [SessionSummary(id: "s1", title: "hello")])
        let service = makeService(registry: registry) { _, _ in session }

        let sessions = try await service.fetchSessions(for: route(), limit: 20)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(session.disconnectCount, 1,
            "fetchSessions must tear down the probe on the success path too")
    }

    // MARK: static minter for the in-process happy path

    private struct StaticTestTicketMinter: WSTicketMinting {
        func mintTicket() async throws -> WSTicket {
            WSTicket(token: "fixture-ticket", ttlSeconds: 30)
        }
    }
}
