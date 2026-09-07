import XCTest
import os
import FleetCore
import FleetNetworking

/// M7 Gateway Registry service tests (spec §15.2 Gateways / §31 Gateway /
/// §12 model): add/edit/remove, auth config, test connection, capability
/// surface, fail-closed lookups, credential cleanup on remove.
///
/// Happy-path `testConnection` runs against the in-process WS fixture server
/// (consistent with M1–M6); failure paths use a scripted stub connection so
/// the service's error classification is deterministic.
final class GatewayRegistryServiceTests: XCTestCase {

    private let gatewayA = GatewayID(rawValue: "workstation")
    private let endpointA = URL(string: "http://127.0.0.1:8642")!

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

    /// A stub connection whose connect either succeeds (ready adopted) or
    /// throws a scripted `GatewayConnectivityError`. Used for deterministic
    /// failure-path classification without a live socket.
    private struct StubConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        let connectResult: Result<GatewayReadyAdoption?, GatewayConnectivityError>

        var status: GatewayStatus {
            switch connectResult {
            case .success: return .online
            case .failure(let error): return GatewayStatus(connectivityError: error)
            }
        }
        func adoptedReady() async -> GatewayReadyAdoption? {
            if case .success(let ready) = connectResult { return ready }
            return nil
        }
        func connect() async throws {
            if case .failure(let error) = connectResult { throw error }
        }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            var g = FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
            if case .success(let ready) = connectResult {
                g.capabilities = ready?.capabilities ?? []
                g.authConfigured = ready != nil
            }
            return g
        }
    }

    /// A stub connection that RECORDS `disconnect()` invocations, so tests can
    /// assert the probe is always torn down (ADR #3) even on classified-failure
    /// paths where no real socket exists.
    private final class RecordingStubConnection: GatewayConnectivityProviding, @unchecked Sendable {
        let gatewayID: GatewayID
        private let connectError: GatewayConnectivityError?
        private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)

        init(gatewayID: GatewayID, connectError: GatewayConnectivityError?) {
            self.gatewayID = gatewayID
            self.connectError = connectError
        }

        var disconnectCount: Int { lock.withLock { $0 } }

        var status: GatewayStatus {
            guard let connectError else { return .online }
            return GatewayStatus(connectivityError: connectError)
        }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {
            if let connectError { throw connectError }
        }
        func disconnect() async {
            lock.withLock { $0 += 1 }
        }
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
    }

    /// A credential store whose delete always fails — proves P1-8: registry
    /// removal / clear must surface (not swallow) Keychain cleanup failures.
    private final class FailingDeleteCredentialStore: CredentialStoring, @unchecked Sendable {
        func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {}
        func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? { nil }
        func deleteCredential(for gatewayID: GatewayID) async throws {
            throw CredentialStoreError.storeUnavailable("injected failure")
        }
    }

    private func makeService(
        credentials: CredentialStoring,
        factory: @escaping GatewayConnectionFactory
    ) -> GatewayRegistryService {
        GatewayRegistryService(credentials: credentials, connectionFactory: factory)
    }

    private func successFactory(ready: GatewayReadyAdoption? = nil) -> GatewayConnectionFactory {
        { gateway, _ in StubConnection(gatewayID: gateway.id, connectResult: .success(ready)) }
    }

    private func failureFactory(_ error: GatewayConnectivityError) -> GatewayConnectionFactory {
        { gateway, _ in StubConnection(gatewayID: gateway.id, connectResult: .failure(error)) }
    }

    private func register(_ service: GatewayRegistryService, id: GatewayID = GatewayID(rawValue: "workstation")) async throws {
        _ = try await service.addGateway(GatewayRegistration(id: id, displayName: "MacBook", endpoint: endpointA))
    }

    // MARK: add

    func testAddGatewayWithExplicitID() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        let registration = GatewayRegistration(id: gatewayA, displayName: "MacBook", endpoint: endpointA)
        let gateway = try await service.addGateway(registration)
        XCTAssertEqual(gateway.id, gatewayA)
        XCTAssertEqual(gateway.displayName, "MacBook")
        XCTAssertEqual(gateway.endpoint, endpointA)
        let count = await service.allGateways().count
        XCTAssertEqual(count, 1)
    }

    func testAddGatewayDerivesIDFromEndpoint() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        let gateway = try await service.addGateway(
            GatewayRegistration(displayName: "MacBook", endpoint: endpointA))
        XCTAssertEqual(gateway.id, GatewayID(endpoint: endpointA))
        XCTAssertEqual(gateway.id.rawValue, "127.0.0.1:8642")
    }

    func testAddGatewayDuplicateRejected() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        try await register(service)
        do {
            _ = try await service.addGateway(GatewayRegistration(id: gatewayA, displayName: "B", endpoint: endpointA))
            XCTFail("expected duplicate")
        } catch let error as GatewayRegistryError {
            XCTAssertEqual(error, .duplicate(gatewayA))
        }
    }

    func testAddGatewayEmptyDisplayNameRejected() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        do {
            _ = try await service.addGateway(GatewayRegistration(id: gatewayA, displayName: "  ", endpoint: endpointA))
            XCTFail("expected empty display name")
        } catch let error as GatewayRegistryError {
            XCTAssertEqual(error, .emptyDisplayName)
        }
    }

    func testAddGatewayInvalidEndpointRejected() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        let bad = URL(string: "ftp://host")!
        do {
            _ = try await service.addGateway(GatewayRegistration(id: gatewayA, displayName: "A", endpoint: bad))
            XCTFail("expected invalid endpoint")
        } catch let error as GatewayRegistryError {
            XCTAssertEqual(error, .invalidEndpoint)
        }
    }

    // MARK: P1-6 — endpoint must be a clean ORIGIN (no user-info, no query/fragment)

    func testAddGatewayRejectsEndpointWithUserInfo() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        let bad = URL(string: "http://alice:password@127.0.0.1:8642")!
        do {
            _ = try await service.addGateway(GatewayRegistration(id: gatewayA, displayName: "A", endpoint: bad))
            XCTFail("expected invalidEndpoint for user-info endpoint")
        } catch let error as GatewayRegistryError {
            XCTAssertEqual(error, .invalidEndpoint)
        }
    }

    func testAddGatewayStripsQueryAndFragmentFromEndpoint() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        let dirty = URL(string: "http://127.0.0.1:8642/base?token=secret#frag")!
        let gateway = try await service.addGateway(
            GatewayRegistration(displayName: "MacBook", endpoint: dirty))
        XCTAssertNil(gateway.endpoint?.query, "query must not be persisted")
        XCTAssertNil(gateway.endpoint?.fragment, "fragment must not be persisted")
        XCTAssertEqual(gateway.endpoint?.absoluteString, "http://127.0.0.1:8642/base")
        XCTAssertFalse(gateway.endpoint?.absoluteString.contains("secret") == true,
                       "query secret never survives the registry boundary")
    }

    func testUpdateGatewayRejectsEndpointWithUserInfo() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        try await register(service)
        let bad = URL(string: "http://bob:sekrit@127.0.0.1:8642")!
        do {
            _ = try await service.updateGateway(
                gatewayA, edits: GatewayEdit(endpoint: bad))
            XCTFail("expected invalidEndpoint for user-info endpoint")
        } catch let error as GatewayRegistryError {
            XCTAssertEqual(error, .invalidEndpoint)
        }
    }

    func testAddGatewayUnsafeIDRejected() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        for raw in ["../gateway", "a/b", "a#b", "a\\b"] {
            do {
                _ = try await service.addGateway(GatewayRegistration(
                    id: GatewayID(rawValue: raw), displayName: "A", endpoint: endpointA))
                XCTFail("expected invalidGatewayID for '\(raw)'")
            } catch let error as GatewayRegistryError {
                guard case .invalidGatewayID = error else {
                    return XCTFail("expected invalidGatewayID for '\(raw)', got \(error)")
                }
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testAddGatewaySafeDerivedIDAccepted() async throws {
        // host:port derived IDs (dots + colon within a token) are valid route
        // components — the M9 guard must not reject them.
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        let gateway = try await service.addGateway(
            GatewayRegistration(displayName: "MacBook", endpoint: endpointA))
        XCTAssertEqual(gateway.id.rawValue, "127.0.0.1:8642")
    }

    // MARK: lookup (fail closed)

    func testLookupFailsClosedForUnknownGateway() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        let gateway = await service.gateway(for: gatewayA)
        XCTAssertNil(gateway)
    }

    func testUpdateUnknownGatewayThrowsNotFound() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        do {
            _ = try await service.updateGateway(gatewayA, edits: GatewayEdit(displayName: "X"))
            XCTFail("expected notFound")
        } catch let error as GatewayRegistryError {
            XCTAssertEqual(error, .notFound(gatewayA))
        }
    }

    func testRemoveUnknownGatewayThrowsNotFound() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        do {
            try await service.removeGateway(gatewayA)
            XCTFail("expected notFound")
        } catch let error as GatewayRegistryError {
            XCTAssertEqual(error, .notFound(gatewayA))
        }
    }

    // MARK: update

    func testUpdateGatewayEditsDisplayNameAndEndpoint() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        try await register(service)
        let newEndpoint = URL(string: "http://127.0.0.1:9119")!
        let updated = try await service.updateGateway(
            gatewayA, edits: GatewayEdit(displayName: "New", endpoint: newEndpoint))
        XCTAssertEqual(updated.displayName, "New")
        XCTAssertEqual(updated.endpoint, newEndpoint)
    }

    func testUpdateGatewayEditsAuthConfiguration() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        try await register(service)
        let config = GatewayAuthConfiguration(strategy: .sessionToken, credentialStored: true)
        let updated = try await service.updateGateway(gatewayA, edits: GatewayEdit(authConfiguration: config))
        XCTAssertEqual(updated.authConfiguration, config)
    }

    // MARK: remove + credential cleanup

    func testRemoveGatewayRemovesAndClearsCredential() async throws {
        let store = TestCredentialStore()
        let service = makeService(credentials: store, factory: successFactory())
        try await register(service)
        try await service.saveCredential(GatewayCredential(rawValue: "secret"), for: gatewayA)
        let before = await service.hasCredential(for: gatewayA)
        XCTAssertTrue(before)

        try await service.removeGateway(gatewayA)
        let removed = await service.gateway(for: gatewayA)
        let after = await service.hasCredential(for: gatewayA)
        XCTAssertNil(removed)
        XCTAssertFalse(after, "credential removed with the gateway")
    }

    // MARK: P1-8 — removal / clear surface credential-cleanup failure

    func testRemoveGatewaySurfacesCredentialCleanupFailure() async throws {
        let store = FailingDeleteCredentialStore()
        let service = makeService(credentials: store, factory: successFactory())
        try await register(service)

        do {
            try await service.removeGateway(gatewayA)
            XCTFail("expected credentialStoreFailed when Keychain cleanup fails")
        } catch let error as GatewayRegistryError {
            guard case .credentialStoreFailed = error else {
                return XCTFail("expected credentialStoreFailed, got \(error)")
            }
        }
        // The gateway must remain registered — no silent half-removed state.
        let stillThere = await service.gateway(for: gatewayA)
        XCTAssertNotNil(stillThere)
    }

    func testClearCredentialSurfacesDeletionFailure() async throws {
        let store = FailingDeleteCredentialStore()
        let service = makeService(credentials: store, factory: successFactory())
        try await register(service)
        try await service.saveCredential(GatewayCredential(rawValue: "secret"), for: gatewayA)

        do {
            try await service.clearCredential(for: gatewayA)
            XCTFail("expected credentialStoreFailed when Keychain delete fails")
        } catch let error as GatewayRegistryError {
            guard case .credentialStoreFailed = error else {
                return XCTFail("expected credentialStoreFailed, got \(error)")
            }
        }
        // authConfigured must NOT be flipped while the secret may still exist.
        let gatewayValue = await service.gateway(for: gatewayA)
        let gateway = try XCTUnwrap(gatewayValue)
        XCTAssertTrue(gateway.authConfigured, "credential still configured after a failed clear")
    }

    // MARK: auth config (credential storage)

    func testSaveCredentialMarksGatewayConfigured() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        try await register(service)
        // The gateway registered with its configured strategy (loopback here,
        // as the U2 UI would set via addGateway registration).
        _ = try await service.updateGateway(
            gatewayA,
            edits: GatewayEdit(authConfiguration: GatewayAuthConfiguration(
                strategy: .loopbackToken, credentialStored: false)))
        try await service.saveCredential(GatewayCredential(rawValue: "secret"), for: gatewayA)

        let has = await service.hasCredential(for: gatewayA)
        XCTAssertTrue(has)
        let gatewayValue = await service.gateway(for: gatewayA)
        let gateway = try XCTUnwrap(gatewayValue)
        XCTAssertTrue(gateway.authConfigured)
        // L1 finding #2: the configured strategy is preserved — saveCredential
        // must NOT force-override it to .sessionToken.
        XCTAssertEqual(gateway.authConfiguration.strategy, .loopbackToken)
        XCTAssertTrue(gateway.authConfiguration.credentialStored)
    }

    /// L1 finding #2 regression: saveCredential preserves the gateway's
    /// configured strategy (whatever the U2 UI selected) instead of forcing
    /// .sessionToken.
    func testSaveCredentialPreservesConfiguredStrategy() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        for strategy in [GatewayAuthConfiguration.Strategy.loopbackToken, .sessionToken, .bearerToken] {
            let id = GatewayID(rawValue: "strategy-\(strategy.rawValue)")
            _ = try await service.addGateway(GatewayRegistration(
                id: id, displayName: "S", endpoint: endpointA,
                authConfiguration: GatewayAuthConfiguration(strategy: strategy, credentialStored: false)))
            try await service.saveCredential(GatewayCredential(rawValue: "secret-\(id.rawValue)"), for: id)
            let gatewayValue = await service.gateway(for: id)
            let gateway = try XCTUnwrap(gatewayValue, "gateway \(id.rawValue) present")
            XCTAssertEqual(gateway.authConfiguration.strategy, strategy,
                           "saveCredential must preserve the configured \(strategy.rawValue) strategy")
            XCTAssertTrue(gateway.authConfiguration.credentialStored)
        }
    }

    func testClearCredentialUnmarksGateway() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        try await register(service)
        try await service.saveCredential(GatewayCredential(rawValue: "secret"), for: gatewayA)
        try await service.clearCredential(for: gatewayA)

        let has = await service.hasCredential(for: gatewayA)
        XCTAssertFalse(has)
        let gatewayValue = await service.gateway(for: gatewayA)
        let gateway = try XCTUnwrap(gatewayValue)
        XCTAssertFalse(gateway.authConfigured)
        XCTAssertEqual(gateway.authConfiguration, .none)
    }

    func testSaveCredentialForUnknownGatewayThrowsNotFound() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        do {
            try await service.saveCredential(GatewayCredential(rawValue: "secret"), for: gatewayA)
            XCTFail("expected notFound")
        } catch let error as GatewayRegistryError {
            XCTAssertEqual(error, .notFound(gatewayA))
        }
    }

    // MARK: test connection — happy path (in-process server)

    func testTestConnectionOnlineAdoptsCapabilities() async throws {
        // Real in-process server with a gateway.ready frame carrying
        // heartbeat + change_events + replay_epoch.
        let readyFrame = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{},"change_events":true,"heartbeat":true,"replay_epoch":"epoch-9"}}}"#
        let script = InProcessWebSocketServer.Script(onOpen: [readyFrame])
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
        let factory: GatewayConnectionFactory = { gateway, _ in
            SingleGatewayConnection(
                gatewayID: gateway.id, displayName: gateway.displayName,
                endpoint: gateway.endpoint, transport: transport)
        }
        let service = makeService(credentials: TestCredentialStore(), factory: factory)
        let id = GatewayID(rawValue: "workstation")
        try await register(service, id: id)

        let result = try await service.testConnection(to: id)
        XCTAssertEqual(result.status, .online)
        XCTAssertTrue(result.capabilities.contains(.heartbeat))
        XCTAssertTrue(result.capabilities.contains(.changeEvents))

        // Teardown assertion (ADR #3): the probe closed its own connection
        // before returning — the transport reached a terminal state rather
        // than being abandoned with running receive/heartbeat tasks.
        XCTAssertEqual(transport.state, .disconnected,
            "testConnection must tear down the probe connection before returning")

        // Registry entry reflects the adopted capability surface (spec §5.3).
        let gatewayValue = await service.gateway(for: id)
        let gateway = try XCTUnwrap(gatewayValue)
        XCTAssertEqual(gateway.connectionState, .connected)
        XCTAssertEqual(gateway.capabilities, ["heartbeat", "change_events"])
        XCTAssertEqual(gateway.replayEpoch, "epoch-9")
    }

    func testTestConnectionUnknownGatewayThrowsNotFound() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: successFactory())
        do {
            _ = try await service.testConnection(to: gatewayA)
            XCTFail("expected notFound")
        } catch let error as GatewayRegistryError {
            XCTAssertEqual(error, .notFound(gatewayA))
        }
    }

    // MARK: test connection — failure classification (scripted stubs)

    func testTestConnectionAuthenticationRequiredClassified() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: failureFactory(.authenticationRequired))
        try await register(service)
        let result = try await service.testConnection(to: gatewayA)
        XCTAssertEqual(result.status, .authenticationRequired)
    }

    func testTestConnectionUnreachableClassifiedOffline() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: failureFactory(.unreachable))
        try await register(service)
        let result = try await service.testConnection(to: gatewayA)
        XCTAssertEqual(result.status, .offline)
    }

    func testTestConnectionTimeoutClassifiedOffline() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: failureFactory(.timeout))
        try await register(service)
        let result = try await service.testConnection(to: gatewayA)
        XCTAssertEqual(result.status, .offline)
    }

    func testTestConnectionUnsupportedClassified() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: failureFactory(.unsupported("chat disabled")))
        try await register(service)
        let result = try await service.testConnection(to: gatewayA)
        XCTAssertEqual(result.status, .unsupported)
    }

    func testTestConnectionServerErrorClassifiedDegraded() async throws {
        let service = makeService(credentials: TestCredentialStore(), factory: failureFactory(.connectionFailed("server error (1011)")))
        try await register(service)
        let result = try await service.testConnection(to: gatewayA)
        XCTAssertEqual(result.status, .degraded)
    }

    // MARK: test connection — probe teardown on every exit path (ADR #3)

    func testTestConnectionFailurePathTearsDownProbe() async throws {
        // A classified failure must also tear the probe connection down — no
        // path may abandon an open socket / running tasks.
        let recording = RecordingStubConnection(gatewayID: gatewayA, connectError: .unreachable)
        let factory: GatewayConnectionFactory = { _, _ in recording }
        let service = makeService(credentials: TestCredentialStore(), factory: factory)
        try await register(service)

        let result = try await service.testConnection(to: gatewayA)
        XCTAssertEqual(result.status, .offline)
        XCTAssertEqual(recording.disconnectCount, 1,
            "testConnection must tear down the probe connection on the failure path too")
    }

    // MARK: test connection — credential passed to the factory (auth config)

    func testTestConnectionPassesStoredCredentialToFactory() async throws {
        // The factory closure is @Sendable: capture a Sendable box + a local
        // Sendable ID instead of self/mutable locals (Swift 6).
        final class ObservedBox: @unchecked Sendable {
            var value: String?
        }
        let observed = ObservedBox()
        let gatewayID = gatewayA
        let factory: GatewayConnectionFactory = { _, credential in
            observed.value = credential?.rawValue
            return StubConnection(gatewayID: gatewayID, connectResult: .success(nil))
        }
        let service = makeService(credentials: TestCredentialStore(), factory: factory)
        try await register(service)
        try await service.saveCredential(GatewayCredential(rawValue: "stored-token"), for: gatewayA)

        _ = try await service.testConnection(to: gatewayA)
        XCTAssertEqual(observed.value, "stored-token", "the stored credential flows to the connection factory")
    }

    // MARK: static minter for the in-process happy path

    private struct StaticTestTicketMinter: WSTicketMinting {
        func mintTicket() async throws -> WSTicket {
            WSTicket(token: "fixture-ticket", ttlSeconds: 30)
        }
    }
}
