import XCTest
@testable import FleetUI
import FleetCore
import FleetPersistence

/// FOS-2 (t_e2169548) — explicit profile scoping evidence (hosted units):
/// 1. FleetScreen route scope carries the exact gateway+profile identity
///    (two-gateway fixture asserts exact scope, never order).
/// 2. Snapshot persistence keys are profile-aware — a second profile never
///    reads the first profile's cache.
/// 3. The management seam receives the exact profile scope on every read.
final class FOS2GatewayScopingTests: XCTestCase {

    // MARK: fixtures — TWO gateways, distinct profiles

    private let workstation = GatewayID(rawValue: "workstation")
    private let laptop = GatewayID(rawValue: "laptop")

    private func route(_ gateway: GatewayID, _ profile: String) -> Route {
        Route(gatewayID: gateway, profileSlug: ProfileSlug(rawValue: profile))
    }

    /// Snapshot roster double whose state the test sets directly.
    private actor SnapshotRoster: FleetRosterProviding {
        private var snapshot = FleetRosterSnapshot()
        func set(_ value: FleetRosterSnapshot) { snapshot = value }
        func refreshRoster() async -> FleetRosterSnapshot { snapshot }
    }

    private final class EmptySessionList: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
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
    }

    /// Records every management call's profile argument (exact-scope probe).
    private final class RecordingManagementSeam: GatewayManagementProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var cronProfiles: [String] = []
        private var skillsProfiles: [String] = []
        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
        func listCronJobs(profile: String?) async throws -> [CronJob] {
            withLock { cronProfiles.append(profile ?? "<nil>") }
            return []
        }
        func createCronJob(draft: CronJobDraft, profile: String?) async throws -> CronJob {
            throw GatewayManagementError.unsupportedAction("create")
        }
        func setCronJob(_ jobID: String, enabled: Bool, profile: String?) async throws -> CronJob {
            throw GatewayManagementError.unsupportedAction("pause")
        }
        func fireCronJob(_ jobID: String, profile: String?) async throws {
            throw GatewayManagementError.unsupportedAction("run")
        }
        func deleteCronJob(_ jobID: String, profile: String?) async throws {
            throw GatewayManagementError.unsupportedAction("delete")
        }
        func skillsCatalog(profile: String) async throws -> SkillsCatalog {
            withLock { skillsProfiles.append(profile) }
            return SkillsCatalog(categories: [], enabledByName: [:])
        }
        func setSkill(_ name: String, enabled: Bool, profile: String) async throws -> Bool {
            throw GatewayManagementError.unsupportedAction("setSkill")
        }
        func recordedCronProfiles() -> [String] { withLock { cronProfiles } }
        func recordedSkillsProfiles() -> [String] { withLock { skillsProfiles } }
    }

    @MainActor
    private func makeEnvironment(
        gateways: [FleetGateway],
        snapshot: FleetRosterSnapshot
    ) async -> (AppEnvironment, SnapshotRoster) {
        let roster = SnapshotRoster()
        await roster.set(snapshot)
        let environment = AppEnvironment(
            registry: StubRegistry(gateways: gateways),
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: EmptySessionList(),
            connectionFactory: { gateway, _ in StubConnection(gatewayID: gateway.id) },
            health: StubHealth()
        )
        await environment.load()
        return (environment, roster)
    }

    private func twoGatewaySnapshot() -> FleetRosterSnapshot {
        var roster = FleetRoster()
        // Workstation: default + researcher. Laptop: writer (only).
        for (gateway, profiles) in [(workstation, ["default", "researcher"]), (laptop, ["writer"])] {
            for profile in profiles {
                roster.upsertBot(FleetBot(route: route(gateway, profile),
                                          displayName: profile.capitalized))
            }
        }
        return FleetRosterSnapshot(
            roster: roster,
            gatewayOutcomes: [
                workstation: .loaded(profileCount: 2),
                laptop: .loaded(profileCount: 1),
            ]
        )
    }

    private func emptyTree() -> ProjectsTree {
        ProjectsTree(projects: [], activeID: nil, scopedSessionIDs: [])
    }

    private func emptyGraph() -> LearningGraph {
        LearningGraph(buckets: [], summary: LearningGraphSummary(lines: [], start: "", end: "", totalCount: 0))
    }

    // MARK: 1 — route scope exactness

    func testRouteScopeCarriesExactGatewayAndProfile() {
        let fromBotDetail = FleetScreen.skills(workstation, profile: ProfileSlug(rawValue: "researcher"))
        XCTAssertEqual(fromBotDetail.gatewayID, workstation)
        guard case .skills(let id, let profile) = fromBotDetail else { return XCTFail("expected skills route") }
        XCTAssertEqual(id, workstation)
        XCTAssertEqual(profile, ProfileSlug(rawValue: "researcher"))
    }

    func testFleetScreenGatewayIDScopesEveryResourceRoute() {
        XCTAssertEqual(FleetScreen.cron(workstation, profile: nil).gatewayID, workstation)
        XCTAssertEqual(FleetScreen.memoryGraph(laptop, profile: nil).gatewayID, laptop)
        XCTAssertEqual(FleetScreen.projects(workstation, profile: nil, focusPath: "p/q").focusPath, "p/q")
        XCTAssertEqual(FleetScreen.gatewayKanban(laptop, board: "ops").gatewayID, laptop)
        XCTAssertEqual(FleetScreen.gatewayDetail(workstation).gatewayID, workstation)
        XCTAssertEqual(FleetScreen.gatewayConnection(laptop).gatewayID, laptop)
        XCTAssertEqual(FleetScreen.gatewayGroups(workstation).gatewayID, workstation)
        XCTAssertEqual(FleetScreen.gatewayHealth(laptop).gatewayID, laptop)
    }

    // MARK: 2 — profile-aware snapshot keys

    func testProjectSnapshotsAreProfileIsolated() async throws {
        // Typed to a single seam protocol — the concrete store conforms to
        // both snapshot protocols whose `load` signatures would be ambiguous.
        let store: any ProjectsSnapshotStoring = try SwiftDataCacheStore.makeInMemory()
        // Save under workstation#researcher.
        try await store.save(emptyTree(), for: workstation, profile: ProfileSlug(rawValue: "researcher"))
        // A load scoped to laptop (different gateway) must NOT see it.
        let otherGateway = try await store.load(for: laptop, profile: ProfileSlug(rawValue: "researcher"))
        XCTAssertNil(otherGateway, "a different gateway must never read another gateway's snapshot")
        // A load scoped to workstation but a different profile must NOT see it.
        let otherProfile = try await store.load(for: workstation, profile: ProfileSlug(rawValue: "default"))
        XCTAssertNil(otherProfile, "a different profile must never read the first profile's snapshot")
        // The exact scope round-trips.
        let exact = try await store.load(for: workstation, profile: ProfileSlug(rawValue: "researcher"))
        XCTAssertNotNil(exact, "the exact gateway+profile scope must round-trip")
    }

    func testLearningGraphSnapshotsAreProfileIsolated() async throws {
        let store: any LearningGraphSnapshotStoring = try SwiftDataCacheStore.makeInMemory()
        try await store.save(emptyGraph(), for: workstation, profile: ProfileSlug(rawValue: "researcher"))
        let crossProfile = try await store.load(for: workstation, profile: ProfileSlug(rawValue: "default"))
        let crossGateway = try await store.load(for: laptop, profile: ProfileSlug(rawValue: "researcher"))
        let exactGraph = try await store.load(for: workstation, profile: ProfileSlug(rawValue: "researcher"))
        XCTAssertNil(crossProfile)
        XCTAssertNil(crossGateway)
        XCTAssertNotNil(exactGraph)
    }

    // MARK: 3 — management seam exact scope

    @MainActor
    func testManagementSeamReceivesExactProfileScope() async throws {
        let seam = RecordingManagementSeam()
        let gateways = [
            FleetGateway(id: workstation, displayName: "Workstation", endpoint: nil),
            FleetGateway(id: laptop, displayName: "Laptop", endpoint: nil),
        ]
        let (_, _) = await makeEnvironment(gateways: gateways, snapshot: twoGatewaySnapshot())

        let model = ManagementPanesViewModel(gatewayID: workstation, management: seam)
        await model.start(profile: "researcher")

        XCTAssertEqual(seam.recordedCronProfiles(), ["researcher"],
                       "cron reads must carry the exact profile, never first/default")
        // start() also loads the skills catalog for the exact profile.
        XCTAssertEqual(seam.recordedSkillsProfiles(), ["researcher"])
    }

    // MARK: 4 — Kanban route keeps its exact gateway (no connection-order swap)

    func testKanbanRouteKeepsExactGatewayAcrossTwoGatewayFleet() {
        // The typed route — not connection order — names the board's owner.
        let route = FleetScreen.gatewayKanban(laptop, board: "ops")
        XCTAssertEqual(route.gatewayID, laptop)
        // The legacy unscoped entry explicitly does NOT name a gateway.
        XCTAssertNil(FleetScreen.kanban.gatewayID)
    }
}
