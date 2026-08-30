import XCTest
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

/// U1 runtime tests: the `AppEnvironment` observable application runtime
/// composes the registry / roster / cache / connection seams and OWNS the
/// connection lifecycle (connect / disconnect / reconnect states observable).
///
/// All seams are scripted (in-memory stores + scripted connections) — no
/// network, no Keychain writes. This is the app-target test bundle, so it may
/// import FleetNetworking (the app composition root is the ONLY allowed
/// consumer); FleetUI itself stays import-free of the transport module.
@MainActor
final class AppEnvironmentTests: XCTestCase {

    // MARK: Fixture seams

    private struct TestConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        let result: Result<Void, GatewayConnectivityError>
        /// A successful scripted connect leaves the gateway online (the
        /// runtime reads this after `connect()` returns).
        var status: GatewayStatus { .online }

        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "test", heartbeatEnabled: true, changeEventsEnabled: true)
        }
        func connect() async throws {
            try result.get()
        }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
    }

    /// A connection that throws `invalidState` on a SECOND connect — exactly
    /// what the real transport does (`GatewayWebSocketTransport.connect()` on
    /// an open socket). Counts calls so the test can prove the runtime never
    /// drives a second connect on an already-connected gateway.
    private final class InvalidStateOnSecondConnect: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        /// Single-threaded test fixture (all access on the main actor); marked
        /// `nonisolated(unsafe)` so the Sendable-conforming class can count
        /// connect calls without lock machinery.
        nonisolated(unsafe) private(set) var connectCount = 0
        var status: GatewayStatus { .online }

        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }

        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "test", heartbeatEnabled: true, changeEventsEnabled: true)
        }
        func connect() async throws {
            connectCount += 1
            if connectCount > 1 {
                throw GatewayConnectivityError.invalidState("connect() from open")
            }
        }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
    }

    private struct TestRosterSession: GatewayRosterSession {
        let gatewayID: GatewayID
        let profiles: [ProfileDescriptor]
        var status: GatewayStatus = .online
        /// Scripted `profiles.list` failure (e.g. an unreachable gateway) so a
        /// test can drive a partial-outage refresh deterministically.
        let rosterError: RosterError?

        init(
            gatewayID: GatewayID,
            profiles: [ProfileDescriptor],
            status: GatewayStatus = .online,
            rosterError: RosterError? = nil
        ) {
            self.gatewayID = gatewayID
            self.profiles = profiles
            self.status = status
            self.rosterError = rosterError
        }

        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] {
            if let rosterError { throw rosterError }
            return profiles
        }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    /// Scripted read-only `session.list` double for U2 Bot-detail tests.
    private struct TestSessionList: SessionListProviding {
        let sessions: [SessionSummary]
        let error: RosterError?

        init(sessions: [SessionSummary] = [], error: RosterError? = nil) {
            self.sessions = sessions
            self.error = error
        }

        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
            if let error { throw error }
            return sessions
        }
    }

    /// Build a runtime over scripted seams. `seed` registers gateways first
    /// so `load()` finds a non-empty registry (production behavior).
    private func makeEnvironment(
        gateways: [GatewayRegistration],
        profiles: [ProfileDescriptor] = [],
        sessionList: any SessionListProviding = TestSessionList()
    ) async -> (AppEnvironment, GatewayRegistryService) {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            }
        )
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: profiles)
            }
        )
        let cache = try! SwiftDataCacheStore.makeInMemory()
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: cache,
            sessionList: sessionList,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            },
            seedRegistrations: gateways
        )
        await environment.load()
        return (environment, registry)
    }

    private func registration(_ id: String, name: String) -> GatewayRegistration {
        GatewayRegistration(
            id: GatewayID(rawValue: id),
            displayName: name,
            endpoint: URL(string: "http://127.0.0.1:\(id.count)")!
        )
    }

    // MARK: Load / registry seam

    func testLoadSeedsAndPublishesGateways() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("<dev-workstation>", name: "MacBook M5"),
            registration("gaming-4090", name: "Gaming 4090"),
        ])

        XCTAssertEqual(environment.gateways.map(\.id.rawValue).sorted(),
                       ["gaming-4090", "<dev-workstation>"])
        // Fresh registry entries are idle until a connect attempt.
        XCTAssertEqual(environment.connectionStates[GatewayID(rawValue: "<dev-workstation>")], .idle)
        XCTAssertEqual(environment.connectionStates[GatewayID(rawValue: "gaming-4090")], .idle)
    }

    func testLoadSeedsOnlyWhenRegistryEmpty() async {
        // Registry pre-seeded with one gateway → seedRegistrations are NOT
        // applied (user-managed fleet is authoritative).
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            }
        )
        _ = try! await registry.addGateway(registration("existing", name: "Existing"))
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: [])
            }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            },
            seedRegistrations: [registration("<dev-workstation>", name: "MacBook M5")]
        )
        await environment.load()

        XCTAssertEqual(environment.gateways.map(\.id.rawValue), ["existing"])
    }

    // MARK: Connection lifecycle — observable states

    func testConnectTransitionsConnectingToConnected() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("<dev-workstation>", name: "MacBook M5"),
        ])
        let id = GatewayID(rawValue: "<dev-workstation>")
        XCTAssertEqual(environment.connectionStates[id], .idle)

        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected,
                       "connect() succeeds → observable state is connected")
    }

    func testConnectFailureClassifiesOffline() async {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .failure(.unreachable))
            }
        )
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: [])
            }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .failure(.unreachable))
            },
            seedRegistrations: [registration("<dev-workstation>", name: "MacBook M5")]
        )
        await environment.load()

        let id = GatewayID(rawValue: "<dev-workstation>")
        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .failed(.offline),
                       "unreachable connect → classified offline, never throws to UI")
    }

    func testDisconnectIsSafeAndObservable() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("<dev-workstation>", name: "MacBook M5"),
        ])
        let id = GatewayID(rawValue: "<dev-workstation>")

        await environment.disconnect(from: id)
        XCTAssertEqual(environment.connectionStates[id], .disconnected,
                       "disconnect before any connect is safe (spec §31)")

        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected)
        await environment.disconnect(from: id)
        XCTAssertEqual(environment.connectionStates[id], .disconnected)
    }

    func testReconnectTearsDownThenConnects() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("<dev-workstation>", name: "MacBook M5"),
        ])
        let id = GatewayID(rawValue: "<dev-workstation>")

        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected)
        await environment.reconnect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected,
                       "reconnect leaves the gateway connected")
    }

    func testConnectWhileAlreadyConnectedIsNoOp() async {
        // Faithful Release repro: the real transport throws invalidState on a
        // second connect. The runtime must NEVER drive a second connect on an
        // already-connected gateway — connect-while-connected is a no-op and
        // the observable state stays .connected (never flips to .failed).
        let connection = InvalidStateOnSecondConnect(gatewayID: GatewayID(rawValue: "<dev-workstation>"))
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in connection }
        )
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: [])
            }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in connection },
            seedRegistrations: [registration("<dev-workstation>", name: "MacBook M5")]
        )
        await environment.load()
        let id = GatewayID(rawValue: "<dev-workstation>")

        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected)
        XCTAssertEqual(connection.connectCount, 1)

        // Second connect while already connected: guard short-circuits, the
        // transport is never touched, and the state stays connected.
        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected,
                       "connect-while-connected must stay .connected")
        XCTAssertEqual(connection.connectCount, 1,
                       "runtime must not drive a second connect on an open connection")
    }

    // MARK: Roster seam (M8 union aggregation observable)

    func testRefreshRosterPublishesBots() async {
        let profile = ProfileDescriptor(
            name: "default", path: "~/.hermes/profiles/default", isDefault: true,
            model: "hermes", provider: "nous", displayName: "Default",
            skillCount: 12, hasAvatar: true
        )
        let (environment, _) = await makeEnvironment(
            gateways: [registration("<dev-workstation>", name: "MacBook M5")],
            profiles: [profile]
        )

        XCTAssertTrue(environment.bots(on: GatewayID(rawValue: "<dev-workstation>")).isEmpty,
                      "no snapshot before refresh → fail closed")

        await environment.refreshRoster()

        let bots = environment.bots(on: GatewayID(rawValue: "<dev-workstation>"))
        XCTAssertEqual(bots.map(\.profileSlug.rawValue), ["default"])
        XCTAssertEqual(bots.first?.route.gatewayID.rawValue, "<dev-workstation>",
                       "owning gateway provenance preserved")
        XCTAssertNotNil(environment.rosterSnapshot)
        XCTAssertFalse(environment.isRefreshing)
    }

    // MARK: Cache seam (M10 behind FleetCore seam)

    func testCacheSeamIsWiredObservable() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("<dev-workstation>", name: "MacBook M5"),
        ])
        // Fresh in-memory cache → zero watermarks, observable on the runtime.
        XCTAssertEqual(environment.cachedWatermarkCount, 0)
    }

    // MARK: U2 — Gateway registry management over the seam

    func testUpdateGatewayAppliesEdits() async throws {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("<dev-workstation>", name: "MacBook M5"),
        ])
        let id = GatewayID(rawValue: "<dev-workstation>")

        let updated = try await environment.updateGateway(
            id,
            edits: GatewayEdit(
                displayName: "MacBook M5 Pro",
                endpoint: URL(string: "http://127.0.0.1:8643")!
            )
        )

        XCTAssertEqual(updated.displayName, "MacBook M5 Pro")
        XCTAssertEqual(updated.endpoint?.absoluteString, "http://127.0.0.1:8643")
        // The observable gateway list reflects the edit.
        XCTAssertEqual(environment.gateways.first?.displayName, "MacBook M5 Pro")
    }

    func testRemoveGatewayClearsObservableState() async throws {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("<dev-workstation>", name: "MacBook M5"),
        ])
        let id = GatewayID(rawValue: "<dev-workstation>")

        try await environment.removeGateway(id)

        XCTAssertTrue(environment.gateways.isEmpty)
        XCTAssertNil(environment.connectionStates[id])
        XCTAssertNil(environment.testResults[id])
    }

    // MARK: U2 — test connection (reachable/unreachable per §13, observable)

    func testTestConnectionStoresReachableResult() async throws {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("<dev-workstation>", name: "MacBook M5"),
        ])
        let id = GatewayID(rawValue: "<dev-workstation>")

        try await environment.testConnection(to: id)

        let result = try XCTUnwrap(environment.testResults[id])
        XCTAssertEqual(result.status, .online, "healthy probe → online (reachable)")
        XCTAssertTrue(environment.testingGatewayIDs.isEmpty)
        XCTAssertEqual(environment.connectionStates[id], .connected,
                       "reachable probe reflects into the observable lifecycle")
    }

    func testTestConnectionClassifiesUnreachableWithoutThrowing() async throws {
        // Registry probe factory throws unreachable → classified .offline and
        // stored, never thrown to the UI (spec §31 reachable/unreachable).
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .failure(.unreachable))
            }
        )
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                TestRosterSession(gatewayID: gateway.id, profiles: [])
            }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .failure(.unreachable))
            },
            seedRegistrations: [registration("<dev-workstation>", name: "MacBook M5")]
        )
        await environment.load()
        let id = GatewayID(rawValue: "<dev-workstation>")

        try await environment.testConnection(to: id)  // no throw

        let result = try XCTUnwrap(environment.testResults[id])
        XCTAssertEqual(result.status, .offline, "unreachable probe → classified offline")
        XCTAssertEqual(environment.connectionStates[id], .failed(.offline))
    }

    func testTestConnectionThrowsForAbsentGateway() async {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("<dev-workstation>", name: "MacBook M5"),
        ])
        do {
            try await environment.testConnection(to: GatewayID(rawValue: "ghost"))
            XCTFail("expected notFound for absent gateway")
        } catch let error as GatewayRegistryError {
            XCTAssertEqual(error, .notFound(GatewayID(rawValue: "ghost")))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: U2 — auth config entry (M7 credential flow, observable)

    func testSaveAndClearCredentialIsObservable() async throws {
        let (environment, _) = await makeEnvironment(gateways: [
            registration("<dev-workstation>", name: "MacBook M5"),
        ])
        let id = GatewayID(rawValue: "<dev-workstation>")

        let initialHas = await environment.hasCredential(for: id)
        XCTAssertFalse(initialHas)

        try await environment.saveCredential(GatewayCredential(rawValue: "fixture-token"), for: id)

        let storedHas = await environment.hasCredential(for: id)
        XCTAssertTrue(storedHas)
        XCTAssertEqual(environment.gateways.first?.authConfigured, true)
        XCTAssertEqual(environment.gateways.first?.authConfiguration.credentialStored, true)

        try await environment.clearCredential(for: id)

        let afterClear = await environment.hasCredential(for: id)
        XCTAssertFalse(afterClear)
        XCTAssertEqual(environment.gateways.first?.authConfigured, false)
    }

    // MARK: U2 — Bot detail session list (read-only `session.list` seam)

    func testLoadSessionsPublishesSessionsForRoute() async {
        let session = SessionSummary(
            id: "s1", title: "Fleet setup", preview: "hello",
            startedAt: 1_754_000_000, messageCount: 6, source: "ios"
        )
        let (environment, _) = await makeEnvironment(
            gateways: [registration("<dev-workstation>", name: "MacBook M5")],
            sessionList: TestSessionList(sessions: [session])
        )
        let route = Route(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
            profileSlug: ProfileSlug(rawValue: "default")
        )

        XCTAssertNil(environment.sessions(for: route), "no fetch yet → fail closed nil")
        await environment.loadSessions(for: route)

        XCTAssertEqual(environment.sessions(for: route)?.map(\.id), ["s1"])
        XCTAssertNil(environment.sessionReadErrors[route])
        XCTAssertFalse(environment.loadingRoutes.contains(route))
    }

    func testLoadSessionsRecordsClassifiedError() async {
        let (environment, _) = await makeEnvironment(
            gateways: [registration("<dev-workstation>", name: "MacBook M5")],
            sessionList: TestSessionList(error: .notConnected)
        )
        let route = Route(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
            profileSlug: ProfileSlug(rawValue: "default")
        )

        await environment.loadSessions(for: route)

        XCTAssertNil(environment.sessions(for: route))
        XCTAssertEqual(environment.sessionReadErrors[route], "gateway not connected",
                       "classified read error surfaced non-secret, no crash")
    }

    // MARK: U2 — union roster partial availability (M8 aggregation observable)

    func testRosterOutcomeClassifiesPartialOutage() async throws {
        // One reachable + one unreachable gateway: refresh never throws, the
        // reachable gateway's bots stay in the union, and the unreachable one
        // is classified (spec §31 / §30).
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            }
        )
        _ = try! await registry.addGateway(registration("<dev-workstation>", name: "MacBook M5"))
        _ = try! await registry.addGateway(registration("arch", name: "Arch"))

        let reachableProfile = ProfileDescriptor(
            name: "default", path: "~/.hermes/profiles/default", isDefault: true,
            model: "hermes", provider: "nous", displayName: "Default"
        )
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                if gateway.id.rawValue == "arch" {
                    return TestRosterSession(
                        gatewayID: gateway.id,
                        profiles: [],
                        status: .offline,
                        rosterError: .notConnected)
                }
                return TestRosterSession(gatewayID: gateway.id, profiles: [reachableProfile])
            }
        )
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id, result: .success(()))
            }
        )
        await environment.load()
        await environment.refreshRoster()

        let snapshot = try XCTUnwrap(environment.rosterSnapshot)
        XCTAssertEqual(snapshot.reachableGateways.map(\.id.rawValue), ["<dev-workstation>"])
        XCTAssertEqual(snapshot.unreachableGateways.map(\.id.rawValue), ["arch"])
        XCTAssertEqual(environment.bots(on: GatewayID(rawValue: "<dev-workstation>")).count, 1,
                       "reachable gateway's bots stay available during partial outage")
        XCTAssertTrue(environment.bots(on: GatewayID(rawValue: "arch")).isEmpty)
        if case .failed(let status, _) = snapshot.outcome(for: GatewayID(rawValue: "arch")) {
            XCTAssertEqual(status, .offline)
        } else {
            XCTFail("expected arch classified failed")
        }
    }
}
