import XCTest
@testable import FleetUI
import FleetCore
import FleetPersistence

/// FOS-3 (t_f770d814) — hosted units for the four-root shell:
/// 1. Command Center results carry the OWNING tab + exact destination
///    (bots → Bots, gateway resources → Gateways, conversations → owner),
///    include direct gateway-object results, and EXCLUDE canonical sessions
///    from the ordinary-conversation group (SPEC §13).
/// 2. The System/Light/Dark appearance preference defaults to System and
///    persists (SPEC §12).
final class FOS3FourRootShellTests: XCTestCase {

    // MARK: fixtures (mirror FOS2GatewayScopingTests)

    private let workstation = GatewayID(rawValue: "workstation")
    private let laptop = GatewayID(rawValue: "laptop")

    private func route(_ gateway: GatewayID, _ profile: String) -> Route {
        Route(gatewayID: gateway, profileSlug: ProfileSlug(rawValue: profile))
    }

    private actor SnapshotRoster: FleetRosterProviding {
        private var snapshot = FleetRosterSnapshot()
        func set(_ value: FleetRosterSnapshot) { snapshot = value }
        func refreshRoster() async -> FleetRosterSnapshot { snapshot }
    }

    /// Session-list double: serves a fixed per-route list (the canonical
    /// session id collides with the roster bot's canonical ref).
    private final class SeededSessionList: SessionListProviding {
        let sessions: [Route: [SessionSummary]]
        init(sessions: [Route: [SessionSummary]]) { self.sessions = sessions }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
            sessions[route] ?? []
        }
    }

    private final class StubConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }
        var status: GatewayStatus { .online }
        var liveness: ConnectionLivenessSnapshot? { nil }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
    }

    private final class StubHealth: ConnectionHealthAccumulating, @unchecked Sendable {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    private final class StubRegistry: GatewayRegistryManaging {
        private let gateways: [FleetGateway]
        init(gateways: [FleetGateway]) { self.gateways = gateways }
        func allGateways() async -> [FleetGateway] { gateways }
        func gateway(for id: GatewayID) async -> FleetGateway? {
            gateways.first { $0.id == id }
        }
        func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway {
            FleetGateway(id: registration.id ?? GatewayID(rawValue: registration.displayName),
                         displayName: registration.displayName, endpoint: registration.endpoint)
        }
        func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
            throw GatewayRegistryError.notFound(id)
        }
        func removeGateway(_ id: GatewayID) async throws {}
        func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {}
        func clearCredential(for id: GatewayID) async throws {}
        func hasCredential(for id: GatewayID) async -> Bool { false }
        func testConnection(to id: GatewayID) async throws -> GatewayTestResult {
            GatewayTestResult(status: .online)
        }
        func restorePersistedGateways() async throws -> [FleetGateway] { gateways }
    }

    @MainActor
    private func makeEnvironment(sessions: [Route: [SessionSummary]]) async -> AppEnvironment {
        var roster = FleetRoster()
        roster.upsertBot(FleetBot(route: route(workstation, "default"),
                                  displayName: "Default",
                                  canonicalSession: CanonicalSessionRef(id: "canonical-s0")))
        roster.upsertBot(FleetBot(route: route(laptop, "writer"), displayName: "Writer"))
        let snapshot = FleetRosterSnapshot(
            roster: roster,
            gatewayOutcomes: [workstation: .loaded(profileCount: 1), laptop: .loaded(profileCount: 1)]
        )
        let rosterSeam = SnapshotRoster()
        await rosterSeam.set(snapshot)
        let environment = AppEnvironment(
            registry: StubRegistry(gateways: [
                FleetGateway(id: workstation, displayName: "Workstation", endpoint: nil),
                FleetGateway(id: laptop, displayName: "Laptop", endpoint: nil),
            ]),
            roster: rosterSeam,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: SeededSessionList(sessions: sessions),
            connectionFactory: { gateway, _ in StubConnection(gatewayID: gateway.id) },
            health: StubHealth()
        )
        await environment.load()
        _ = await environment.refreshRoster()
        // Publish the session index the Command Center reads; the default
        // bot's list deliberately includes the canonical session id so the
        // exclusion filter is exercised against real published state.
        for route in sessions.keys {
            await environment.loadSessions(for: route)
        }
        return environment
    }

    // MARK: 1. Command Center results

    @MainActor
    func testCommandCenterResultsRouteToOwningTabs() async {
        let environment = await makeEnvironment(sessions: [
            route(workstation, "default"): [
                SessionSummary(id: "canonical-s0", title: "Bot Chat", preview: "canonical"),
                SessionSummary(id: "ordinary-1", title: "Fleet setup", preview: "ordinary"),
            ],
            route(laptop, "writer"): [
                SessionSummary(id: "writer-1", title: "Writer chat", preview: "ordinary"),
            ],
        ])
        let results = FleetCommandCenterResults(environment: environment)

        // Bots route to the Bots tab with exact destinations.
        let bot = results.items.first { $0.id == "bot:workstation#default" }
        XCTAssertNotNil(bot, "roster bots must appear as results")
        XCTAssertEqual(bot?.screen, .botDetail(route(workstation, "default")))
        XCTAssertEqual(bot?.screen.owner, .bots)

        // Direct gateway-object results route to Gateways + Detail.
        let gateway = results.items.first { $0.id == "gateway:workstation" }
        XCTAssertNotNil(gateway, "gateways must appear as DIRECT object results (FOS-3)")
        XCTAssertEqual(gateway?.screen, .gatewayDetail(workstation))
        XCTAssertEqual(gateway?.screen.owner, .gateways)

        // Gateway resources route to Gateways with exact gateway scope.
        let cron = results.items.first { $0.id == "res:cron:\(workstation.rawValue)" }
        XCTAssertNotNil(cron)
        XCTAssertEqual(cron?.screen.owner, .gateways)
        XCTAssertEqual(cron?.screen.gatewayID, workstation)

        // Conversations route to their owner (ordinary → Chats).
        let ordinary = results.items.first { $0.id == "conv:workstation#default/ordinary-1" }
        XCTAssertNotNil(ordinary, "loaded ordinary sessions must appear as results")
        XCTAssertEqual(ordinary?.screen.owner, .chats)

        // CANONICAL EXCLUSION (§13): the canonical session must NOT appear in
        // the ordinary-conversation results.
        XCTAssertNil(results.items.first { $0.id == "conv:workstation#default/canonical-s0" },
                     "canonical sessions must not appear as ordinary chats in Command Center")
    }

    @MainActor
    func testCommandCenterResultsIncludeGroupsFromRoomUnion() async {
        let environment = await makeEnvironment(sessions: [:])
        let results = FleetCommandCenterResults(environment: environment)
        // No rooms are loaded in this fixture — the group section is simply
        // empty, and bot/gateway results still render.
        XCTAssertTrue(results.items.contains { $0.kind == .bot })
        XCTAssertTrue(results.items.contains { $0.kind == .gateway })
        XCTAssertFalse(results.items.contains { $0.kind == .group })
    }

    // MARK: 2. Appearance preference

    func testAppearanceDefaultsToSystemAndPersists() {
        let suiteName = "fos3-appearance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = FleetAppearanceController(defaults: defaults)
        XCTAssertEqual(controller.selection, .system, "default must be System (§12)")
        XCTAssertNil(controller.selection.colorScheme, "System maps to a nil override")

        controller.selection = .dark
        XCTAssertEqual(controller.selection.colorScheme, .dark)
        XCTAssertEqual(FleetAppearanceController(defaults: defaults).selection, .dark,
                       "the pick must persist across controller instances")

        controller.selection = .light
        XCTAssertEqual(controller.selection.colorScheme, .light)
        XCTAssertEqual(FleetAppearanceController(defaults: defaults).selection, .light)
    }

    func testAppearanceCatalogIsExactlySystemLightDark() {
        XCTAssertEqual(FleetAppearance.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual(FleetAppearance.allCases.map(\.label), ["System", "Light", "Dark"])
    }
}
