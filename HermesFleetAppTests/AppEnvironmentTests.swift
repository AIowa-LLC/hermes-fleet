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

    private struct TestRosterSession: GatewayRosterSession {
        let gatewayID: GatewayID
        let profiles: [ProfileDescriptor]
        var status: GatewayStatus = .online

        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] { profiles }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    /// Build a runtime over scripted seams. `seed` registers gateways first
    /// so `load()` finds a non-empty registry (production behavior).
    private func makeEnvironment(
        gateways: [GatewayRegistration],
        profiles: [ProfileDescriptor] = []
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
}
