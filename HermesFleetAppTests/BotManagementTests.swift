import XCTest
import FleetCore
import FleetPersistence
@testable import FleetUI

/// Slice 2 hosted unit tests: BotManagementController behavior over scripted
/// seams (sections load/save CAS, edit outcomes, duplicate naming, create),
/// the D03 canonical-title helper, roster ghost retention, and relative-time
/// copy.
@MainActor
final class BotManagementTests: XCTestCase {

    // MARK: scripted seams

    /// Actor-based scripted profile seam (async-safe by construction).
    actor ScriptedProfileSeam: BotProfileManaging, BotSectionRegistryLoading, BotSectionRegistryWriting {
        private var sections: [BotSection] = []
        private var sectionsRevision = 0
        private var revisions: [String: Int] = [:]

        func describeProfile(_ profile: String) async throws -> BotProfileDescription {
            BotProfileDescription(name: profile, soul: "soul text", defaultModel: "m1", provider: "nous")
        }

        func configureProfile(_ profile: String, edit: BotProfileEdit) async throws -> BotProfileEditOutcome {
            try await configureProfile(profile, edit: edit, confirmExpensiveModel: false)
        }

        func configureProfile(
            _ profile: String, edit: BotProfileEdit, confirmExpensiveModel: Bool
        ) async throws -> BotProfileEditOutcome {
            var applied: [String: Bool] = [:]
            if let metadata = edit.metadata {
                let current = revisions[profile] ?? 0
                if let expected = edit.metadataExpectedRevision, expected != current {
                    throw BotSectionSyncError.conflict("stale")
                }
                revisions[profile] = current + 1
                applied["ui_meta"] = true
            }
            if edit.soul != nil { applied["soul"] = true }
            if edit.descriptionText != nil { applied["description"] = true }
            if edit.hasModelSection { applied["model"] = true }
            return BotProfileEditOutcome(edit: edit, applied: applied)
        }

        func createProfile(_ spec: BotCreateSpec) async throws -> String { spec.name }

        func uploadAvatar(_ profile: String, dataURL: String) async throws {}
        func clearAvatar(_ profile: String) async throws {}
        func avatarData(_ profile: String) async throws -> Data? { nil }

        func loadSectionRegistry() async throws -> (sections: [BotSection], revision: Int?) {
            (sections, sectionsRevision)
        }

        func writeSectionRegistry(
            value: MetadataValue, expectedRevision: Int?
        ) async throws -> MetadataWriteReceiptLike {
            if let expected = expectedRevision, expected != sectionsRevision {
                throw BotSectionSyncError.conflict("stale registry")
            }
            sections = BotSectionRegistry.normalize(value)
            sectionsRevision += 1
            return MetadataWriteReceiptLike(applied: true, newRevisions: [:])
        }
    }

    /// Roster double whose snapshot the test sets directly.
    actor SnapshotRoster: FleetRosterProviding {
        private var snapshot = FleetRosterSnapshot()
        func set(_ value: FleetRosterSnapshot) { snapshot = value }
        func refreshRoster() async -> FleetRosterSnapshot { snapshot }
    }

    final class EmptySessionList: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    final class StubConnection: GatewayConnectivityProviding {
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

    final class StubHealth: ConnectionHealthAccumulating, @unchecked Sendable {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    final class StubRegistry: GatewayRegistryManaging {
        private let gateways: [FleetGateway]
        init(gateways: [FleetGateway]) { self.gateways = gateways }
        func allGateways() async -> [FleetGateway] { gateways }
        func gateway(for id: GatewayID) async -> FleetGateway? {
            gateways.first { $0.id == id }
        }
        func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway {
            let id = registration.id ?? GatewayID(rawValue: registration.displayName)
            return FleetGateway(id: id, displayName: registration.displayName, endpoint: registration.endpoint)
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

    private func makeEnvironment(
        gateways: [FleetGateway] = [],
        snapshot: FleetRosterSnapshot = FleetRosterSnapshot(),
        profileSeam: ScriptedProfileSeam = ScriptedProfileSeam()
    ) async -> (AppEnvironment, SnapshotRoster, ScriptedProfileSeam) {
        let roster = SnapshotRoster()
        await roster.set(snapshot)
        let environment = AppEnvironment(
            registry: StubRegistry(gateways: gateways),
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: EmptySessionList(),
            connectionFactory: { gateway, _ in StubConnection(gatewayID: gateway.id) },
            botProfileFactory: { _ in profileSeam },
            health: StubHealth()
        )
        await environment.load()
        return (environment, roster, profileSeam)
    }

    // MARK: sections

    func testSectionsLoadAndSaveRoundTrip() async throws {
        let seam = ScriptedProfileSeam()
        let gateway = FleetGateway(id: GatewayID(rawValue: "gw"), displayName: "GW", endpoint: nil)
        let (env, _, _) = await makeEnvironment(gateways: [gateway], profileSeam: seam)
        await env.botManagement.loadSections(from: gateway.id)
        XCTAssertEqual(env.botManagement.sectionsByGateway[gateway.id], [])

        let sections = [BotSection(id: "s1", name: "Alpha"), BotSection(id: "s2", name: "Beta")]
        try await env.botManagement.saveSections(sections, on: gateway.id)
        XCTAssertEqual(env.botManagement.sectionsByGateway[gateway.id], sections)

        await env.botManagement.loadSections(from: gateway.id)
        XCTAssertEqual(env.botManagement.sectionsByGateway[gateway.id], sections)
    }

    // MARK: edit

    func testApplyEditSurfacesAppliedSections() async throws {
        let seam = ScriptedProfileSeam()
        let gateway = FleetGateway(id: GatewayID(rawValue: "gw"), displayName: "GW", endpoint: nil)
        let (env, roster, _) = await makeEnvironment(gateways: [gateway], profileSeam: seam)
        var bot = FleetBot(
            route: Route(gatewayID: gateway.id, profileSlug: ProfileSlug(rawValue: "b")),
            displayName: "b")
        bot.uiMetaRevisions = MetadataRevisions(revisions: [BotModeContract.botsMetaKey: 0])
        var snapshotRoster = FleetRoster()
        snapshotRoster.upsertGateway(gateway)
        snapshotRoster.upsertBot(bot)
        await roster.set(FleetRosterSnapshot(roster: snapshotRoster, gatewayOutcomes: [:]))

        let outcome = try await env.botManagement.applyEdit(
            BotProfileEdit(soul: "new soul", descriptionText: "d"), to: bot)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.appliedSections, [.soul, .description])
    }

    func testMoveBotWritesSectionIDMetadata() async throws {
        let seam = ScriptedProfileSeam()
        let gateway = FleetGateway(id: GatewayID(rawValue: "gw"), displayName: "GW", endpoint: nil)
        let (env, _, _) = await makeEnvironment(gateways: [gateway], profileSeam: seam)
        var bot = FleetBot(
            route: Route(gatewayID: gateway.id, profileSlug: ProfileSlug(rawValue: "b")),
            displayName: "b")
        // The roster-reported revision for a never-written profile is 0 on
        // this scripted gateway (mirrors `ui_meta_revisions: {}` semantics).
        bot.uiMetaRevisions = MetadataRevisions(revisions: [BotModeContract.botsMetaKey: 0])
        let outcome = try await env.botManagement.moveBot(bot, toSection: "sec-1")
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.appliedSections, [.metadata])
    }

    // MARK: create

    func testCreateBotRoutesToTargetGateway() async throws {
        let seam = ScriptedProfileSeam()
        let gateway = FleetGateway(id: GatewayID(rawValue: "gw"), displayName: "GW", endpoint: nil)
        let (env, _, _) = await makeEnvironment(gateways: [gateway], profileSeam: seam)
        let name = try await env.botManagement.createBot(
            BotCreateSpec(name: "scribe", title: "Scribe"), on: gateway.id)
        XCTAssertEqual(name, "scribe")
    }

    // MARK: duplicate

    func testDuplicateBotUsesFirstFreeName() async throws {
        let seam = ScriptedProfileSeam()
        let gateway = FleetGateway(id: GatewayID(rawValue: "gw"), displayName: "GW", endpoint: nil)
        let (env, _, _) = await makeEnvironment(gateways: [gateway], profileSeam: seam)
        var bot = FleetBot(
            route: Route(gatewayID: gateway.id, profileSlug: ProfileSlug(rawValue: "researcher")),
            displayName: "Researcher")
        bot.botModeMetadata = BotModeMetadata(title: "Researcher")
        let newName = try await env.botManagement.duplicateBot(
            bot, occupiedNames: ["researcher"])
        XCTAssertEqual(newName, "researcher-2")
    }

    // MARK: D03 canonical title

    func testIsCanonicalBotChatMatchesRosterCanonicalAndOpenPath() async throws {
        let gateway = FleetGateway(id: GatewayID(rawValue: "gw"), displayName: "GW", endpoint: nil)
        var bot = FleetBot(
            route: Route(gatewayID: gateway.id, profileSlug: ProfileSlug(rawValue: "b")),
            displayName: "b")
        bot.canonicalSession = CanonicalSessionRef(id: "canon-1", resolvedID: "tip-9")
        var roster = FleetRoster()
        roster.upsertGateway(gateway)
        roster.upsertBot(bot)
        let (env, _, _) = await makeEnvironment(
            gateways: [gateway],
            snapshot: FleetRosterSnapshot(roster: roster, gatewayOutcomes: [:]))
        // The roster snapshot becomes observable only after a refresh.
        await env.refreshRoster()

        XCTAssertTrue(env.isCanonicalBotChat(route: bot.route, sessionID: "canon-1"))
        XCTAssertTrue(env.isCanonicalBotChat(route: bot.route, sessionID: "tip-9"))
        XCTAssertFalse(env.isCanonicalBotChat(route: bot.route, sessionID: "other"))

        env.openBotChat(route: bot.route, sessionID: "minted-7")
        XCTAssertTrue(env.isCanonicalBotChat(route: bot.route, sessionID: "minted-7"))
    }

    // MARK: roster ghost retention

    func testRosterSectionsRetainCachedGhostsOnOutage() {
        let gw1 = GatewayID(rawValue: "gw1")
        let gw2 = GatewayID(rawValue: "gw2")
        let ghostBot = FleetBot(
            route: Route(gatewayID: gw1, profileSlug: ProfileSlug(rawValue: "researcher")),
            displayName: "Researcher")
        let otherBot = FleetBot(
            route: Route(gatewayID: gw2, profileSlug: ProfileSlug(rawValue: "researcher")),
            displayName: "Researcher")

        var outage = FleetRoster()
        outage.upsertGateway(FleetGateway(id: gw1, displayName: "One", endpoint: nil))
        outage.upsertGateway(FleetGateway(id: gw2, displayName: "Two", endpoint: nil))
        outage.upsertBot(otherBot)
        let outageSnapshot = FleetRosterSnapshot(
            roster: outage,
            gatewayOutcomes: [
                gw1: .failed(status: .offline, detail: nil),
                gw2: .loaded(profileCount: 1),
            ])

        let sections = FleetRosterView.sections(
            from: outageSnapshot, cachedBots: [gw1: [ghostBot]])
        let ghostSection = sections.first { $0.gateway.id == gw1 }
        XCTAssertNotNil(ghostSection, "outage section preserved")
        XCTAssertNotNil(ghostSection?.outage)
        // The cached ghost keeps its identity — gw1#researcher — and is
        // NEVER substituted by gw2's same-name bot.
        XCTAssertEqual(ghostSection?.bots.map(\.route.id), ["gw1#researcher"])
        let healthySection = sections.first { $0.gateway.id == gw2 }
        XCTAssertEqual(healthySection?.bots.map(\.route.id), ["gw2#researcher"])
    }

    // MARK: relative time copy

    func testRelativeTimeBuckets() {
        let now = 1_000_000.0
        XCTAssertEqual(BotRowView.relativeTime(1_000_000 - 30, now: now), "now")
        XCTAssertEqual(BotRowView.relativeTime(1_000_000 - 300, now: now), "5m")
        XCTAssertEqual(BotRowView.relativeTime(1_000_000 - 7_200, now: now), "2h")
        XCTAssertEqual(BotRowView.relativeTime(1_000_000 - 172_800, now: now), "2d")
    }
}
