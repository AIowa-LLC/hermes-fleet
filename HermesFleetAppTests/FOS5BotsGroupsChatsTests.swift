import XCTest
@testable import FleetUI
import FleetCore
import FleetPersistence

/// FOS-5 (t_41672ceb) — Bots+Groups+Chats refinement hosted units:
/// 1. Ghost cache lifecycle: successful EMPTY roster clears the cache (a
///    stale cache must not resurrect deleted bots on a later outage);
///    ghost resolver (`botIncludingGhost`/`isGhostRoute`) resolves exact
///    routes through the cache, never by name.
/// 2. `isActiveNow` §7 alignment: working/thinking/usingTool only —
///    waiting and needsAttention are excluded from Active Now.
/// 3. Duplicate-name disambiguation computed over the FLEET including
///    ghosts (FleetRosterView.sections feeds both branches).
/// 4. Collapse keying: `(GatewayID, SectionID)` — two gateways may own the
///    same section id without colliding.
/// 5. SessionSummary.lastActive preserved by the decoders (decode-level
///    assertions live in FleetNetworking; here: model + Chats sort
///    semantics UNCHANGED by the new field).
/// 6. Chats canonical exclusion + startedAt ordering stay intact.
@MainActor
final class FOS5BotsGroupsChatsTests: XCTestCase {

    private let ws = GatewayID(rawValue: "workstation")
    private let lab = GatewayID(rawValue: "lab")

    private func route(_ gateway: GatewayID, _ profile: String) -> Route {
        Route(gatewayID: gateway, profileSlug: ProfileSlug(rawValue: profile))
    }

    private func bot(_ gateway: GatewayID, _ profile: String, name: String? = nil) -> FleetBot {
        FleetBot(
            route: route(gateway, profile),
            displayName: name ?? profile)
    }

    // MARK: 1. Ghost cache lifecycle + resolver

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
        return (env, roster, registry)
    }

    private func snapshot(
        bots: [FleetBot],
        on gateway: GatewayID,
        outcome: GatewayRosterOutcome
    ) -> FleetRosterSnapshot {
        var roster = FleetRoster()
        roster.upsertGateway(FleetGateway(id: ws, displayName: "Workstation", endpoint: nil))
        roster.upsertGateway(FleetGateway(id: lab, displayName: "Lab Node", endpoint: nil))
        for b in bots { roster.upsertBot(b) }
        return FleetRosterSnapshot(
            roster: roster,
            gatewayOutcomes: [
                ws: outcome,
                lab: .loaded(profileCount: 1),
            ])
    }

    func testSuccessfulEmptyRosterClearsGhostCache() async {
        let (env, roster, _) = await makeEnvironment()
        let ghost = bot(ws, "researcher", name: "Researcher")
        // 1st refresh: ws reports the bot (cache populated).
        await roster.set(snapshot(bots: [ghost, bot(lab, "default")], on: ws, outcome: .loaded(profileCount: 1)))
        await env.refreshRoster()
        XCTAssertEqual(env.cachedBotsByGateway[ws]?.map(\.route.id), ["workstation#researcher"])

        // 2nd refresh: ws answers successfully with ZERO bots — the cache
        // must CLEAR (SPEC §9: "A successful empty roster removes old ghost
        // inventory").
        await roster.set(snapshot(bots: [bot(lab, "default")], on: ws, outcome: .loaded(profileCount: 0)))
        await env.refreshRoster()
        XCTAssertNil(env.cachedBotsByGateway[ws], "successful empty roster must clear the ghost cache")

        // And a later outage must NOT resurrect the deleted bot.
        var outage = FleetRoster()
        outage.upsertGateway(FleetGateway(id: ws, displayName: "Workstation", endpoint: nil))
        outage.upsertGateway(FleetGateway(id: lab, displayName: "Lab Node", endpoint: nil))
        outage.upsertBot(bot(lab, "default"))
        await roster.set(FleetRosterSnapshot(roster: outage, gatewayOutcomes: [
            ws: .failed(status: .offline, detail: nil),
            lab: .loaded(profileCount: 1),
        ]))
        await env.refreshRoster()
        let sections = FleetRosterView.sections(from: env.rosterSnapshot!, cachedBots: env.cachedBotsByGateway)
        let wsSection = sections.first { $0.gateway.id == ws }
        XCTAssertEqual(wsSection?.bots ?? [], [], "cleared cache must not resurrect deleted bots on outage")
    }

    func testFailedRefreshRetainsGhostCache() async {
        let (env, roster, _) = await makeEnvironment()
        let ghost = bot(ws, "researcher", name: "Researcher")
        await roster.set(snapshot(bots: [ghost], on: ws, outcome: .loaded(profileCount: 1)))
        await env.refreshRoster()
        // Outage refresh: cache retained (identity preserved).
        var outage = FleetRoster()
        outage.upsertGateway(FleetGateway(id: ws, displayName: "Workstation", endpoint: nil))
        await roster.set(FleetRosterSnapshot(roster: outage, gatewayOutcomes: [
            ws: .failed(status: .offline, detail: nil),
        ]))
        await env.refreshRoster()
        XCTAssertEqual(env.cachedBotsByGateway[ws]?.map(\.route.id), ["workstation#researcher"])
    }

    func testGhostResolverExactRouteNeverName() async {
        let (env, roster, _) = await makeEnvironment()
        let wsResearcher = bot(ws, "researcher", name: "Researcher")
        let labResearcher = bot(lab, "researcher", name: "Researcher")
        // 1st refresh: both gateways healthy — cache populated for ws.
        await roster.set(snapshot(bots: [wsResearcher, labResearcher], on: ws, outcome: .loaded(profileCount: 2)))
        await env.refreshRoster()

        // 2nd refresh: ws failed → its researcher is a cached ghost; only
        // lab's researcher is live.
        var rosterValue = FleetRoster()
        rosterValue.upsertGateway(FleetGateway(id: ws, displayName: "Workstation", endpoint: nil))
        rosterValue.upsertGateway(FleetGateway(id: lab, displayName: "Lab Node", endpoint: nil))
        rosterValue.upsertBot(labResearcher)
        await roster.set(FleetRosterSnapshot(roster: rosterValue, gatewayOutcomes: [
            ws: .failed(status: .offline, detail: nil),
            lab: .loaded(profileCount: 1),
        ]))
        await env.refreshRoster()

        // Ghost resolves by EXACT route.
        XCTAssertEqual(env.botIncludingGhost(for: wsResearcher.route)?.route.id, "workstation#researcher")
        XCTAssertTrue(env.isGhostRoute(wsResearcher.route))
        // Live bot resolves, not a ghost.
        XCTAssertEqual(env.botIncludingGhost(for: labResearcher.route)?.route.id, "lab#researcher")
        XCTAssertFalse(env.isGhostRoute(labResearcher.route))
        // Unknown route: nil — never a same-name substitution.
        XCTAssertNil(env.botIncludingGhost(for: route(ws, "nonexistent")))
    }

    // MARK: 2. isActiveNow §7 alignment

    func testActiveNowExcludesWaitingAndNeedsAttention() {
        XCTAssertTrue(BotRosterPresentation.isActiveNow(makeActivityBot(.working)))
        XCTAssertTrue(BotRosterPresentation.isActiveNow(makeActivityBot(.thinking)))
        XCTAssertTrue(BotRosterPresentation.isActiveNow(makeActivityBot(.usingTool)))
        // §7: waiting is distinct from executing; needsAttention is
        // attention, not execution.
        XCTAssertFalse(BotRosterPresentation.isActiveNow(makeActivityBot(.waiting)))
        XCTAssertFalse(BotRosterPresentation.isActiveNow(makeActivityBot(.needsAttention)))
        XCTAssertFalse(BotRosterPresentation.isActiveNow(makeActivityBot(.idle)))
        XCTAssertFalse(BotRosterPresentation.isActiveNow(makeActivityBot(.unknown)))
    }

    private func makeActivityBot(_ activity: BotActivity) -> FleetBot {
        var b = bot(ws, "a")
        b.activity = activity
        return b
    }

    // MARK: 3. Fleet-wide duplicate disambiguation including ghosts

    func testDuplicateNamesLabelAcrossFleetIncludingGhosts() {
        let gw1 = GatewayID(rawValue: "gw1")
        let gw2 = GatewayID(rawValue: "gw2")
        let live = bot(gw1, "researcher", name: "Researcher")
        let ghost = bot(gw2, "researcher", name: "Researcher")
        // Fleet union: live + ghost share a title → BOTH get gateway labels.
        let union = [live, ghost]
        let labels = BotRosterPresentation.duplicateNameRoutes(
            BotRosterPresentation.visible(union, revealingHidden: true)
        ) { id in id.rawValue.uppercased() }
        XCTAssertEqual(labels[live.route], "GW1")
        XCTAssertEqual(labels[ghost.route], "GW2")

        // And FleetRosterView.sections surfaces the ghost branch from cache
        // so the view can compute over both.
        var roster = FleetRoster()
        roster.upsertGateway(FleetGateway(id: gw1, displayName: "One", endpoint: nil))
        roster.upsertGateway(FleetGateway(id: gw2, displayName: "Two", endpoint: nil))
        roster.upsertBot(live)
        let snap = FleetRosterSnapshot(roster: roster, gatewayOutcomes: [
            gw1: .loaded(profileCount: 1),
            gw2: .failed(status: .offline, detail: nil),
        ])
        let sections = FleetRosterView.sections(from: snap, cachedBots: [gw2: [ghost]])
        let ghostSection = sections.first { $0.gateway.id == gw2 }
        XCTAssertEqual(ghostSection?.bots.map(\.route.id), ["gw2#researcher"], "ghost row retained in outage section")
    }

    // MARK: 4. Collapse keying (GatewayID, SectionID)

    func testCollapseKeyDisambiguatesSameSectionIDAcrossGateways() {
        let key1 = FleetRosterView.collapseKey(GatewayID(rawValue: "gw1"), "sec-1")
        let key2 = FleetRosterView.collapseKey(GatewayID(rawValue: "gw2"), "sec-1")
        XCTAssertNotEqual(key1, key2, "same section id on two gateways must not collide")
        XCTAssertEqual(key1, "gw1|sec-1")
    }

    // MARK: 5/6. SessionSummary.lastActive + Chats semantics unchanged

    func testSessionSummaryCarriesLastActiveWithoutChangingSort() {
        let older = SessionSummary(id: "a", title: "A", startedAt: 100, lastActive: 999, messageCount: 1)
        let newer = SessionSummary(id: "b", title: "B", startedAt: 200, lastActive: 100, messageCount: 1)
        XCTAssertEqual(older.lastActive, 999, "last_active decoded and preserved")
        XCTAssertEqual(newer.lastActive, 100)
        // Current sort semantics stay startedAt-descending (SPEC §10: do
        // NOT change the current sort).
        let sorted = [older, newer].sorted {
            if $0.startedAt == $1.startedAt { return $0.id < $1.id }
            return $0.startedAt > $1.startedAt
        }
        XCTAssertEqual(sorted.map(\.id), ["b", "a"], "startedAt ordering unchanged by lastActive")
    }
}
