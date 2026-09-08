import XCTest
@testable import FleetUI
import FleetCore
import FleetPersistence

/// FOS-4 (t_2f5bf49a) — Truthful Fleet Home hosted units:
/// 1. Continue index persistence (≤50 / 30 days / dedupe / prune-on-removal,
///    exact source-qualified identity, no same-name substitution);
/// 2. Needs You aggregation from ALREADY-OBSERVED items only (gateway
///    auth/config episodes + published room observations, dedupe by
///    request/generation, coverage caveat);
/// 3. unknown ≠ zero truth on the summary seam (coverage text inputs).
@MainActor
final class FOS4TruthfulHomeTests: XCTestCase {

    private let ws = GatewayID(rawValue: "workstation")
    private let lab = GatewayID(rawValue: "lab")

    private func route(_ gateway: GatewayID, _ profile: String) -> Route {
        Route(gatewayID: gateway, profileSlug: ProfileSlug(rawValue: profile))
    }

    // MARK: fixtures

    private actor SnapshotRoster: FleetRosterProviding {
        private var snapshot = FleetRosterSnapshot()
        func set(_ value: FleetRosterSnapshot) { snapshot = value }
        func refreshRoster() async -> FleetRosterSnapshot { snapshot }
    }

    private final class StubConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }
        var status: GatewayStatus { .online }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
    }

    private actor StubRegistry: GatewayRegistryManaging {
        private var gateways: [FleetGateway] = []
        func set(_ value: [FleetGateway]) { gateways = value }
        func allGateways() async -> [FleetGateway] { gateways }
        func gateway(for id: GatewayID) async -> FleetGateway? { gateways.first { $0.id == id } }
        func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway {
            FleetGateway(id: registration.id ?? GatewayID(rawValue: "x"), displayName: "x", endpoint: nil)
        }
        func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
            FleetGateway(id: id, displayName: "x", endpoint: nil)
        }
        func removeGateway(_ id: GatewayID) async throws {}
        func testConnection(to id: GatewayID) async throws -> GatewayTestResult { GatewayTestResult(status: .offline) }
        func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {}
        func clearCredential(for id: GatewayID) async throws {}
        func hasCredential(for id: GatewayID) async -> Bool { false }
        func restorePersistedGateways() async throws -> [FleetGateway] { [] }
    }

    private final class EmptySessionList: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private final class EmptyHealth: ConnectionHealthAccumulating {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    private func makeEnvironment(
        roster: SnapshotRoster = SnapshotRoster(),
        registry: StubRegistry = StubRegistry()
    ) async -> (AppEnvironment, SnapshotRoster, StubRegistry) {
        // Seed the registered fleet (two gateways) so projections see them.
        await registry.set([
            FleetGateway(id: ws, displayName: "Workstation", endpoint: nil),
            FleetGateway(id: lab, displayName: "Lab Node", endpoint: nil),
        ])
        let env = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: EmptySessionList(),
            connectionFactory: { gateway, _ in StubConnection(gatewayID: gateway.id) },
            health: EmptyHealth()
        )
        // Hermetic continue index: fresh temp file per test.
        env.attachContinueIndex(FleetContinueIndexStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("fos4-continue-\(UUID().uuidString).json")))
        return (env, roster, registry)
    }

    private func snapshotWith(outcomes: [GatewayID: GatewayRosterOutcome]) -> FleetRosterSnapshot {
        var roster = FleetRoster()
        roster.upsertGateway(FleetGateway(id: ws, displayName: "Workstation", endpoint: nil))
        roster.upsertGateway(FleetGateway(id: lab, displayName: "Lab Node", endpoint: nil))
        return FleetRosterSnapshot(roster: roster, gatewayOutcomes: outcomes)
    }

    /// Mutable injectable clock (Swift 6 sendable-safe via a locked box).
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Date
        init(_ start: Date) { _value = start }
        var value: Date {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            _value = _value.addingTimeInterval(seconds)
        }
    }

    // MARK: 1. Continue index

    func testContinueIndexRecordsExactSourceQualifiedIdentity() async {
        let clock = Clock(Date(timeIntervalSince1970: 2000))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fos4-a-\(UUID().uuidString).json")
        let store = FleetContinueIndexStore(url: url, now: { clock.value })
        let r1 = route(ws, "researcher")
        store.recordConversationOpen(route: r1, sessionID: "sess-1", canonical: false,
                                     title: "Release notes", subtitle: "Researcher · Workstation")
        // Same-named conversation on ANOTHER gateway/session is a DIFFERENT
        // identity (never substituted, never merged).
        let r2 = route(lab, "researcher")
        store.recordConversationOpen(route: r2, sessionID: "sess-9", canonical: false,
                                     title: "Release notes", subtitle: "Researcher · Lab Node")
        var entries = store.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, FleetContinueIndexStore.conversationID(route: r2, sessionID: "sess-9"))
        XCTAssertNotEqual(entries[0].id, entries[1].id)

        // Re-opening the SAME exact conversation moves it to the front and
        // does NOT duplicate (dedupe by source-qualified id).
        clock.advance(50)
        store.recordConversationOpen(route: r1, sessionID: "sess-1", canonical: false,
                                     title: "Release notes", subtitle: "Researcher · Workstation")
        entries = store.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, FleetContinueIndexStore.conversationID(route: r1, sessionID: "sess-1"))
        XCTAssertEqual(entries[0].openedAt, clock.value, "re-open refreshes recency")
    }

    func testContinueIndexPersistsAcrossStoreReload() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fos4-b-\(UUID().uuidString).json")
        let store = FleetContinueIndexStore(url: url)
        store.recordConversationOpen(route: route(ws, "default"), sessionID: "s1", canonical: true,
                                     title: "Bot Chat", subtitle: "default · Workstation")
        store.recordRoomOpen(
            room: FleetRoomID(provenance: .hosted, gatewayID: ws, key: "room-alpha"),
            title: "Launch Crew", subtitle: "Workstation")
        // A NEW store over the same file sees both entries (durability).
        let reloaded = FleetContinueIndexStore(url: url)
        let entries = reloaded.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].kind, .room)
        XCTAssertEqual(entries[1].kind, .canonicalBotChat)
    }

    func testContinueIndexCapsAtFiftyAndPrunesThirtyDayOlds() async {
        let clock = Clock(Date(timeIntervalSince1970: 3000))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fos4-c-\(UUID().uuidString).json")
        let store = FleetContinueIndexStore(url: url, now: { clock.value })
        for i in 0..<60 {
            store.recordConversationOpen(
                route: route(ws, "bot\(i)"), sessionID: "s\(i)", canonical: false,
                title: "t\(i)", subtitle: "bot\(i) · Workstation")
        }
        XCTAssertEqual(store.entries().count, 50, "hard cap 50")
        // Advance 31 days: everything expires; a fresh open survives alone.
        clock.advance(31 * 24 * 3600)
        store.recordConversationOpen(
            route: route(ws, "default"), sessionID: "fresh", canonical: false,
            title: "fresh", subtitle: "default · Workstation")
        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].sessionID, "fresh")
    }

    func testContinueIndexPrunesRemovedGateway() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fos4-d-\(UUID().uuidString).json")
        let store = FleetContinueIndexStore(url: url)
        store.recordConversationOpen(route: route(ws, "default"), sessionID: "s1", canonical: false,
                                     title: "a", subtitle: "s")
        store.recordConversationOpen(route: route(lab, "default"), sessionID: "s2", canonical: false,
                                     title: "b", subtitle: "s")
        store.prune(gatewayID: lab)
        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].gatewayIDRaw, "workstation",
                       "a removed source's entries must not resolve to another gateway")
    }

    // MARK: 2. Needs You aggregation (observed items only)

    func testNeedsYouAggregatesGatewayAuthAndObservedRoomItems() async {
        let (env, roster, _) = await makeEnvironment()
        let snap = snapshotWith(outcomes: [
            ws: .loaded(profileCount: 2),
            lab: .failed(status: .authenticationRequired, detail: nil),
        ])
        await roster.set(snap)
        await env.load()
        await env.refreshRoster()

        // Before any room observation: exactly the auth episode.
        var items = env.attentionItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .gatewayAuthRequired)

        // An OPENED room publishes its driver observations (approval).
        let room = FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: ws, key: "room-alpha"),
            name: "Launch Crew",
            members: [],
            hosted: nil)
        let approval = RoomPendingApproval(
            memberID: "researcher", taskID: "task-1", executionGeneration: 3, requestID: "req-9",
            approval: ["prompt": .string("Allow the web tool?")])
        env.publishRoomAttention(room: room, status: RoomDriverStatus(
            working: false, blocked: false, counts: [:],
            pendingRetries: [], pendingApprovals: [approval]))

        items = env.attentionItems()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].kind, .roomApproval, "approvals sort before auth")
        // Dedupe: re-publishing the SAME room (same request/generation ids)
        // replaces rather than stacks.
        env.publishRoomAttention(room: room, status: RoomDriverStatus(
            working: false, blocked: false, counts: [:],
            pendingRetries: [], pendingApprovals: [approval]))
        XCTAssertEqual(env.attentionItems().count, 2, "same request/generation deduped")

        // Coverage: with a room pending observed elsewhere, coverage is
        // incomplete → the caveat copy is required.
        XCTAssertFalse(env.attentionCoverage().allGatewaysClassified)
    }

    func testNeedsYouHiddenWhenNothingObserved() async {
        let (env, roster, _) = await makeEnvironment()
        await roster.set(snapshotWith(outcomes: [
            ws: .loaded(profileCount: 1),
            lab: .loaded(profileCount: 1),
        ]))
        await env.load()
        await env.refreshRoster()
        XCTAssertTrue(env.attentionItems().isEmpty)
        XCTAssertTrue(env.attentionCoverage().allGatewaysClassified)
    }

    // MARK: 3. unknown ≠ zero / partial outage

    func testUnknownRosterNeverClaimsZero() async {
        let (env, _, registry) = await makeEnvironment()
        await registry.set([
            FleetGateway(id: ws, displayName: "Workstation", endpoint: nil),
            FleetGateway(id: lab, displayName: "Lab Node", endpoint: nil),
        ])
        await env.load()
        // No refresh yet: rosterSnapshot is nil — unknown ≠ zero.
        XCTAssertNil(env.rosterSnapshot)
        XCTAssertFalse(env.attentionCoverage().allGatewaysClassified)
    }

    func testPartialOutageRetainsCoverageTruth() async {
        let (env, roster, _) = await makeEnvironment()
        await roster.set(snapshotWith(outcomes: [
            ws: .loaded(profileCount: 2),
            lab: .failed(status: .offline, detail: "unreachable"),
        ]))
        await env.load()
        await env.refreshRoster()
        // Offline ≠ attention item (SPEC §7: transient classes are coverage).
        XCTAssertTrue(env.attentionItems().isEmpty)
        // But the roster DID classify every gateway (outcome present).
        XCTAssertTrue(env.attentionCoverage().allGatewaysClassified)
    }

    // MARK: 4. summary seam coalescing

    func testRefreshSummaryIfDueRefreshesOnceThenJoins() async {
        let (env, roster, _) = await makeEnvironment()
        let counting = CountingRoster(base: roster)
        // A second environment with a SEEDED registry (gateways registered →
        // due → the coalescing behavior is observable).
        let seededRegistry = StubRegistry()
        await seededRegistry.set([
            FleetGateway(id: ws, displayName: "Workstation", endpoint: nil),
        ])
        let env2 = AppEnvironment(
            registry: seededRegistry,
            roster: counting,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: EmptySessionList(),
            connectionFactory: { gateway, _ in StubConnection(gatewayID: gateway.id) },
            health: EmptyHealth())
        await env2.load()
        // Gateways registered → due → refresh happens.
        await env2.refreshSummaryIfDue()
        let afterFirst = await counting.count
        XCTAssertEqual(afterFirst, 1, "Home entry triggers exactly one refresh when due")
        // Immediately due again? No — fresh success within the 30s cadence.
        await env2.refreshSummaryIfDue()
        let afterSecond = await counting.count
        XCTAssertEqual(afterSecond, 1, "a fresh observation is not re-driven within the cadence")
    }
}

/// Roster wrapper that counts refreshes (coalescing proof).
private actor CountingRoster: FleetRosterProviding {
    let base: FleetRosterProviding
    private(set) var count = 0
    init(base: FleetRosterProviding) { self.base = base }
    func refreshRoster() async -> FleetRosterSnapshot {
        count += 1
        return await base.refreshRoster()
    }
}
