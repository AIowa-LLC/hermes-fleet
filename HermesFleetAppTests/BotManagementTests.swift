import XCTest
import SwiftUI
import UIKit
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
    /// #7: records avatar asset mutations + every carried configure so the
    /// coordinated appearance save can be asserted at the controller level.
    actor ScriptedProfileSeam: BotProfileManaging, BotSectionRegistryLoading, BotSectionRegistryWriting {
        private var sections: [BotSection] = []
        private var sectionsRevision = 0
        private var revisions: [String: Int] = [:]
        private(set) var avatarAssets: [String: Data] = [:]
        private(set) var configureCalls: [BotProfileEdit] = []
        private(set) var clearAvatarCalls: [String] = []
        private(set) var uploadAvatarCalls: [String] = []
        private var clearAvatarError: Error?
        private var uploadAvatarError: Error?

        func injectClearAvatarError(_ error: Error?) { clearAvatarError = error }
        func injectUploadAvatarError(_ error: Error?) { uploadAvatarError = error }

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
            configureCalls.append(edit)
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

        func uploadAvatar(_ profile: String, dataURL: String) async throws {
            if let uploadAvatarError { throw uploadAvatarError }
            uploadAvatarCalls.append(profile)
            if let range = dataURL.range(of: "base64,"),
               let data = Data(base64Encoded: String(dataURL[range.upperBound...])) {
                avatarAssets[profile] = data
            }
        }

        func clearAvatar(_ profile: String) async throws {
            if let clearAvatarError { throw clearAvatarError }
            clearAvatarCalls.append(profile)
            avatarAssets[profile] = nil
        }

        func avatarData(_ profile: String) async throws -> Data? { avatarAssets[profile] }

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
    // MARK: - #7 unified avatar appearance save

    /// Controller-level: seeding the draft, staging a shape over an
    /// existing image, saving — metadata applies FIRST, then the asset
    /// clear, and the result succeeds with explicit ordering.
    func testApplyAvatarAppearanceShapeSupersedesImage() async throws {
        let seam = ScriptedProfileSeam()
        let gateway = FleetGateway(id: GatewayID(rawValue: "gw"), displayName: "GW", endpoint: nil)
        let (env, _, _) = await makeEnvironment(gateways: [gateway], profileSeam: seam)
        var bot = FleetBot(
            route: Route(gatewayID: gateway.id, profileSlug: ProfileSlug(rawValue: "default")),
            displayName: "Default")
        bot.hasAvatar = true
        bot.uiMetaRevisions = MetadataRevisions(revisions: [BotModeContract.botsMetaKey: 0])

        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: true)
        draft.selectShape("cloud")
        XCTAssertEqual(draft.image, .remove, "shape selection stages image removal")

        let edit = BotProfileEdit(
            metadata: draft.metadataAfterSave,
            metadataExpectedRevision: 0)
        let result = try await env.botManagement.applyAvatarAppearance(draft, edit: edit, to: bot)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.assetApplied, true)
        let cleared = await seam.clearAvatarCalls
        XCTAssertEqual(cleared, ["default"], "the staged removal must clear the asset on save")
        let configs = await seam.configureCalls
        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs.first?.metadata?.shape, "cloud")
        XCTAssertEqual(configs.first?.metadata?.custom, true)
        XCTAssertEqual(configs.first?.metadata?.imageKind, "shape")
    }

    /// Controller-level: a staged image replacement uploads on save with
    /// imageKind "photo", superseding any existing asset.
    func testApplyAvatarAppearanceImageReplacement() async throws {
        let seam = ScriptedProfileSeam()
        let gateway = FleetGateway(id: GatewayID(rawValue: "gw"), displayName: "GW", endpoint: nil)
        let (env, _, _) = await makeEnvironment(gateways: [gateway], profileSeam: seam)
        var bot = FleetBot(
            route: Route(gatewayID: gateway.id, profileSlug: ProfileSlug(rawValue: "researcher")),
            displayName: "Researcher")
        bot.hasAvatar = false
        bot.uiMetaRevisions = MetadataRevisions(revisions: [BotModeContract.botsMetaKey: 0])

        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        let bytes = Data(repeating: 7, count: 64)
        draft.stageReplacement(data: bytes)

        let edit = BotProfileEdit(
            metadata: draft.metadataAfterSave,
            metadataExpectedRevision: 0)
        let result = try await env.botManagement.applyAvatarAppearance(draft, edit: edit, to: bot)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.assetApplied, true)
        let uploads = await seam.uploadAvatarCalls
        XCTAssertEqual(uploads, ["researcher"])
        let assets = await seam.avatarAssets
        XCTAssertEqual(assets["researcher"], bytes)
        let configs = await seam.configureCalls
        XCTAssertEqual(configs.first?.metadata?.imageKind, "photo")
        XCTAssertEqual(configs.first?.metadata?.custom, true)
    }

    /// Controller-level partial failure: metadata applies but the asset
    /// clear fails — the result must NOT succeed and must carry an
    /// explicit explanation (never generic success).
    func testApplyAvatarAppearancePartialFailureSurfacesExplicitly() async throws {
        let seam = ScriptedProfileSeam()
        await seam.injectClearAvatarError(BotSectionSyncError.conflict("asset clear failed"))
        let gateway = FleetGateway(id: GatewayID(rawValue: "gw"), displayName: "GW", endpoint: nil)
        let (env, _, _) = await makeEnvironment(gateways: [gateway], profileSeam: seam)
        var bot = FleetBot(
            route: Route(gatewayID: gateway.id, profileSlug: ProfileSlug(rawValue: "default")),
            displayName: "Default")
        bot.hasAvatar = true
        bot.uiMetaRevisions = MetadataRevisions(revisions: [BotModeContract.botsMetaKey: 0])

        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: true)
        draft.selectShape("cloud")

        let edit = BotProfileEdit(
            metadata: draft.metadataAfterSave,
            metadataExpectedRevision: 0)
        let result = try await env.botManagement.applyAvatarAppearance(draft, edit: edit, to: bot)
        XCTAssertFalse(result.succeeded, "partial application must never read as success")
        XCTAssertEqual(result.assetApplied, false)
        XCTAssertNotNil(result.partialFailure)
        XCTAssertTrue(result.partialFailure?.contains("could not be removed") ?? false,
                      "the partial failure names the image-still-active state")
        // Metadata DID apply — the failure message must reflect reality.
        let configs = await seam.configureCalls
        XCTAssertEqual(configs.count, 1)
    }

    /// Controller-level: a CAS conflict on the metadata write must throw
    /// BEFORE any asset mutation (the previous image is never cleared).
    func testApplyAvatarAppearanceCASConflictNeverClearsImage() async throws {
        let seam = ScriptedProfileSeam()
        let gateway = FleetGateway(id: GatewayID(rawValue: "gw"), displayName: "GW", endpoint: nil)
        let (env, _, _) = await makeEnvironment(gateways: [gateway], profileSeam: seam)
        var bot = FleetBot(
            route: Route(gatewayID: gateway.id, profileSlug: ProfileSlug(rawValue: "default")),
            displayName: "Default")
        bot.hasAvatar = true
        // The roster reported revision 0, but the gateway is at 5 — a
        // stale local view (another client wrote).
        bot.uiMetaRevisions = MetadataRevisions(revisions: [BotModeContract.botsMetaKey: 0])
        // Seed the seam's revision to 5 by writing once through it.
        _ = try await seam.configureProfile("default", edit: BotProfileEdit(
            metadata: BotModeMetadata(title: "someone else"), metadataExpectedRevision: nil))

        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: true)
        draft.selectShape("cloud")
        let edit = BotProfileEdit(
            metadata: draft.metadataAfterSave,
            metadataExpectedRevision: 0)
        do {
            _ = try await env.botManagement.applyAvatarAppearance(draft, edit: edit, to: bot)
            XCTFail("expected a CAS conflict")
        } catch {
            // expected: stale revision
        }
        let cleared = await seam.clearAvatarCalls
        XCTAssertTrue(cleared.isEmpty, "a conflicted metadata write must never clear the image")
    }

    /// Draft lifecycle: an untouched draft performs ZERO remote writes
    /// (Cancel semantics — save would send nothing).
    func testUntouchedAvatarDraftPerformsNoWrites() async throws {
        let seam = ScriptedProfileSeam()
        let gateway = FleetGateway(id: GatewayID(rawValue: "gw"), displayName: "GW", endpoint: nil)
        let (env, _, _) = await makeEnvironment(gateways: [gateway], profileSeam: seam)
        var bot = FleetBot(
            route: Route(gatewayID: gateway.id, profileSlug: ProfileSlug(rawValue: "default")),
            displayName: "Default")
        bot.hasAvatar = false
        bot.uiMetaRevisions = MetadataRevisions(revisions: [BotModeContract.botsMetaKey: 0])

        var meta = BotModeMetadata()
        meta.shape = "cloud"
        meta.custom = true
        meta.imageKind = "shape"
        let draft = BotAvatarAppearanceDraft.seeded(from: meta, hasAvatar: false)
        XCTAssertFalse(draft.isDirty)

        // The sheet's save() would not carry a metadata section for an
        // untouched draft; the coordinator is never invoked with one.
        let edit = BotProfileEdit(metadata: nil, metadataExpectedRevision: 0)
        let result = try await env.botManagement.applyAvatarAppearance(draft, edit: edit, to: bot)
        XCTAssertTrue(result.succeeded)
        let cleared = await seam.clearAvatarCalls
        let uploads = await seam.uploadAvatarCalls
        XCTAssertTrue(cleared.isEmpty && uploads.isEmpty,
                      "an untouched draft must cause zero avatar asset writes")
        let configs = await seam.configureCalls
        XCTAssertTrue(configs.allSatisfy { $0.metadata == nil && $0.isEmpty },
                      "an untouched draft carries no writable sections")
    }

    // MARK: - D2 (FOS-DF dogfood): slug keyboard traits

    /// D2 regression: the Create Bot "Name (profile slug)" field must disable
    /// autocapitalization and autocorrection — the default keyboard mangles
    /// slugs ("df-ops-bot" -> "DF Ops Bot") and the gateway rejects them
    /// (4062, rule [a-z0-9][a-z0-9_-]{0,63}). Asserted on the resolved
    /// UITextField traits through a real UIKit window, the layer iOS actually
    /// applies the SwiftUI modifiers at.
    func testCreateBotSlugFieldDisablesAutocapitalizeAndAutocorrect() async throws {
        let gateways = [FleetGateway(
            id: GatewayID(rawValue: "gw"),
            displayName: "GW",
            endpoint: nil)]
        let environment = AppEnvironment(
            registry: StubRegistry(gateways: gateways),
            roster: SnapshotRoster(),
            cache: try SwiftDataCacheStore.makeInMemory(),
            sessionList: EmptySessionList(),
            connectionFactory: { gateway, _ in StubConnection(gatewayID: gateway.id) },
            health: StubHealth()
        )
        await environment.load()

        let sheet = CreateBotSheet(environment: environment) { _, _ in }
        let hosted = UIHostingController(rootView: sheet)
        hosted.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hosted
        window.makeKeyAndVisible()

        var slugField: UITextField?
        var titleField: UITextField?
        for _ in 0..<50 where slugField == nil || titleField == nil {
            hosted.view.setNeedsLayout()
            hosted.view.layoutIfNeeded()
            var stack: [UIView] = [hosted.view]
            while let view = stack.popLast() {
                if let field = view as? UITextField {
                    if field.accessibilityIdentifier == "fleet.bot.create.name"
                        || field.placeholder == "Name (profile slug)" {
                        slugField = field
                    }
                    if field.accessibilityIdentifier == "fleet.bot.create.title"
                        || field.placeholder == "Title (display name, optional)" {
                        titleField = field
                    }
                }
                stack.append(contentsOf: view.subviews)
            }
            if slugField == nil || titleField == nil {
                await Task.yield()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        window.isHidden = true

        let unwrappedSlug = try XCTUnwrap(
            slugField, "slug field materialized in the UIKit hierarchy")
        let unwrappedTitle = try XCTUnwrap(
            titleField, "title field materialized in the UIKit hierarchy")
        XCTAssertEqual(unwrappedSlug.autocapitalizationType, .none,
                       "slug field must not autocapitalize (gateway rejects uppercase)")
        XCTAssertEqual(unwrappedSlug.autocorrectionType, .no,
                       "slug field must not autocorrect (keyboard mangles slugs)")
        // Sanity: the plain display-name field next to it keeps default
        // behavior — the modifiers are targeted, not form-wide.
        XCTAssertNotEqual(unwrappedTitle.autocapitalizationType, .none,
                          "display-name field keeps default capitalization")
    }
}
