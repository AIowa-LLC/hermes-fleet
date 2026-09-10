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
    actor ScriptedProfileSeam: BotProfileManaging, BotSectionRegistryLoading, BotSectionRegistryWriting, BotPetManaging {
        private var sections: [BotSection] = []
        private var sectionsRevision = 0
        private var revisions: [String: Int] = [:]
        private(set) var avatarAssets: [String: Data] = [:]
        private(set) var configureCalls: [BotProfileEdit] = []
        private(set) var clearAvatarCalls: [String] = []
        private(set) var uploadAvatarCalls: [String] = []
        private(set) var describeCalls: [String] = []
        private var clearAvatarFailures = 0
        private var uploadAvatarFailures = 0
        private var reportsRevisions = true
        private(set) var clearAvatarAttempts = 0
        private(set) var uploadAvatarAttempts = 0
        private var clearAvatarError: Error?
        private var uploadAvatarError: Error?

        func injectClearAvatarError(_ error: Error?) { clearAvatarError = error }
        func injectUploadAvatarError(_ error: Error?) { uploadAvatarError = error }
        /// Scripted N-shot clear failures (t_3ce28479 retry-path tests):
        /// the first N clear attempts throw, later ones succeed.
        func failNextClearAvatar(_ count: Int) { clearAvatarFailures = count }
        /// Scripted N-shot upload failures (t_3ce28479 retry-path tests).
        func failNextUploadAvatar(_ count: Int) { uploadAvatarFailures = count }
        /// Toggle revision reporting (t_3ce28479: exercises the sheet's
        /// roster-revision fallback when an outcome carries no
        /// `newMetadataRevisions`).
        func setReportsRevisions(_ value: Bool) { reportsRevisions = value }

        /// The scripted gateway is asset-capable (mirrors the DEBUG
        /// Workstation scripted fleet, which has avatar assets).
        func supportsAvatarUpload(_ profile: String) async -> Bool { true }

        func describeProfile(_ profile: String) async throws -> BotProfileDescription {
            describeCalls.append(profile)
            return BotProfileDescription(name: profile, soul: "soul text", defaultModel: "m1", provider: "nous")
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
            // Real-client parity (GatewayBotModeClient.decodeEditOutcome):
            // a successful ui_meta write reports the bumped revision.
            let newRevisions: [String: Int] =
                (applied["ui_meta"] == true && reportsRevisions)
                ? [BotModeContract.botsMetaKey: revisions[profile] ?? 0]
                : [:]
            return BotProfileEditOutcome(
                edit: edit, applied: applied, newMetadataRevisions: newRevisions)
        }

        func createProfile(_ spec: BotCreateSpec) async throws -> String { spec.name }

        func uploadAvatar(_ profile: String, dataURL: String) async throws {
            uploadAvatarAttempts += 1
            if uploadAvatarFailures > 0 {
                uploadAvatarFailures -= 1
                throw BotSectionSyncError.conflict("scripted upload failure")
            }
            if let uploadAvatarError { throw uploadAvatarError }
            uploadAvatarCalls.append(profile)
            if let range = dataURL.range(of: "base64,"),
               let data = Data(base64Encoded: String(dataURL[range.upperBound...])) {
                avatarAssets[profile] = data
            }
        }

        func clearAvatar(_ profile: String) async throws {
            clearAvatarAttempts += 1
            if clearAvatarFailures > 0 {
                clearAvatarFailures -= 1
                throw BotSectionSyncError.conflict("scripted clear failure")
            }
            if let clearAvatarError { throw clearAvatarError }
            clearAvatarCalls.append(profile)
            avatarAssets[profile] = nil
        }

        func avatarData(_ profile: String) async throws -> Data? { avatarAssets[profile] }

        /// Live hermes-bots revision for one profile (t_3ce28479 dynamic
        /// roster double: a real gateway's roster refresh reports the
        /// authoritative post-write revision).
        func currentMetadataRevision(_ profile: String) async -> Int {
            revisions[profile] ?? 0
        }

        // #9 — scripted pet surface
        private(set) var petGalleryCalls: [(profile: String, localOnly: Bool)] = []
        private(set) var petThumbCalls: [(profile: String, slug: String, sourceURL: String?)] = []
        var petGalleryError: Error?
        var petThumbError: Error?
        /// Pet thumbnails keyed by slug; per-gateway divergence is driven
        /// by the seam's gateway identity when the test constructs it.
        var petThumbnails: [String: Data] = [
            "spark-fox": Data([0x89, 0x50, 0x4E, 0x47, 1, 1, 1]),
            "pixel-owl": Data([0x89, 0x50, 0x4E, 0x47, 2, 2, 2]),
        ]

        func petGallery(profile: String, localOnly: Bool) async throws -> HermesPetGallery {
            petGalleryCalls.append((profile, localOnly))
            if let petGalleryError { throw petGalleryError }
            let pets: [HermesPet] = [
                HermesPet(slug: "spark-fox", displayName: "Spark Fox", installed: true,
                          curated: false, generated: false, spritesheetURL: nil),
                HermesPet(slug: "pixel-owl", displayName: "Pixel Owl", installed: false,
                          curated: true, generated: false,
                          spritesheetURL: "https://petdex.dev/sheets/pixel-owl.png"),
                HermesPet(slug: "gen-cat", displayName: "Gen Cat", installed: true,
                          curated: false, generated: true, spritesheetURL: nil),
            ]
            // Two-stage truth: localOnly returns installed/generated only.
            return HermesPetGallery(
                pets: localOnly ? pets.filter(\.installed) : pets,
                displayEnabled: true, activeSlug: "spark-fox")
        }

        func petThumbnail(profile: String, slug: String, sourceURL: String?) async throws -> Data {
            petThumbCalls.append((profile, slug, sourceURL))
            if let petThumbError { throw petThumbError }
            guard let bytes = petThumbnails[slug] else {
                throw BotPetError.thumbnailUnavailable(slug: slug)
            }
            return bytes
        }

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

    /// Roster double whose bot revision tracks the seam's LIVE revision —
    /// models a real gateway whose roster refresh reports the
    /// authoritative post-write ui_meta revision (t_3ce28479 fallback
    /// path: outcomes that carry no `newMetadataRevisions`).
    actor SeamTrackingRoster: FleetRosterProviding {
        private let seam: ScriptedProfileSeam
        private let gateway: FleetGateway
        private let botSeed: FleetBot
        init(seam: ScriptedProfileSeam, gateway: FleetGateway, bot: FleetBot) {
            self.seam = seam
            self.gateway = gateway
            self.botSeed = bot
        }
        func refreshRoster() async -> FleetRosterSnapshot {
            var bot = botSeed
            let revision = await seam.currentMetadataRevision(
                bot.route.profileSlug.rawValue)
            bot.uiMetaRevisions = MetadataRevisions(
                revisions: [BotModeContract.botsMetaKey: revision])
            var roster = FleetRoster()
            roster.upsertGateway(gateway)
            roster.upsertBot(bot)
            return FleetRosterSnapshot(
                roster: roster,
                gatewayOutcomes: [gateway.id: .loaded(profileCount: 1)])
        }
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

    // MARK: - t_3ce28479: stale CAS revision on partial-failure retry

    /// The real sheet reseed logic (EditBotSheet.partialFailureReseed):
    /// after a partial failure (metadata applied, asset clear failed) the
    /// draft's metadata baseline advances and the CAS revision reseeds
    /// from the outcome's newMetadataRevisions — so a retry Save carries
    /// only the still-failing asset mutation, never a stale metadata
    /// write against the already-bumped gateway revision.
    func testPartialFailureReseedAdvancesDraftAndRevision() async throws {
        let seam = ScriptedProfileSeam()
        await seam.failNextClearAvatar(1)
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
            metadata: draft.metadataAfterSave, metadataExpectedRevision: 0)
        let result = try await env.botManagement.applyAvatarAppearance(draft, edit: edit, to: bot)
        XCTAssertNotNil(result.partialFailure, "clear failed as scripted")

        let reseeded = EditBotSheet.partialFailureReseed(
            draft: draft, metadataRevision: 0,
            outcome: result.editOutcome, rosterRevision: nil)

        XCTAssertEqual(reseeded.draft.image, .remove,
                       "the staged removal is preserved for the retry")
        XCTAssertEqual(reseeded.draft.metadataAfterSave, reseeded.draft.baseline,
                       "the metadata section is no longer dirty after reseed")
        XCTAssertEqual(reseeded.revision, 1,
                       "revision reseeds from the outcome's newMetadataRevisions")
    }

    /// Roster fallback: when the outcome carries NO newMetadataRevisions
    /// the reseed must take the refreshed roster's revision instead of
    /// keeping the stale pre-write one.
    func testPartialFailureReseedFallsBackToRosterRevision() async throws {
        let seam = ScriptedProfileSeam()
        await seam.setReportsRevisions(false)
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
            metadata: draft.metadataAfterSave, metadataExpectedRevision: 0)
        let result = try await env.botManagement.applyAvatarAppearance(draft, edit: edit, to: bot)
        XCTAssertTrue(result.editOutcome.appliedSections.contains(.metadata))
        XCTAssertTrue(result.editOutcome.newMetadataRevisions.isEmpty,
                      "scripted gateway reports no revisions")

        let reseeded = EditBotSheet.partialFailureReseed(
            draft: draft, metadataRevision: 0,
            outcome: result.editOutcome, rosterRevision: 1)

        XCTAssertEqual(reseeded.revision, 1,
                       "revision falls back to the refreshed roster's revision")
        XCTAssertEqual(reseeded.draft.metadataAfterSave, reseeded.draft.baseline,
                       "draft baseline still advances")
    }

    /// Full acceptance sequence: metadata applies + asset clear fails →
    /// retry save with the reseeded state (metadata section nil because it
    /// matches the applied baseline; revision reseeded) → the second save
    /// does NOT throw a CAS conflict and the clear is re-attempted.
    /// The negative control reproduces the defect mechanism: retrying the
    /// ORIGINAL edit (stale revision + applied metadata) CAS-throws.
    func testRetryAfterPartialFailureSavesWithoutCASConflict() async throws {
        let seam = ScriptedProfileSeam()
        await seam.failNextClearAvatar(1)
        let gateway = FleetGateway(id: GatewayID(rawValue: "gw"), displayName: "GW", endpoint: nil)
        var bot = FleetBot(
            route: Route(gatewayID: gateway.id, profileSlug: ProfileSlug(rawValue: "default")),
            displayName: "Default")
        bot.hasAvatar = true
        bot.uiMetaRevisions = MetadataRevisions(revisions: [BotModeContract.botsMetaKey: 0])

        var roster = FleetRoster()
        roster.upsertGateway(gateway)
        roster.upsertBot(bot)
        let (env, rosterDouble, _) = await makeEnvironment(
            gateways: [gateway],
            snapshot: FleetRosterSnapshot(roster: roster, gatewayOutcomes: [:]),
            profileSeam: seam)
        await env.refreshRoster()

        // First save: metadata applies (revision 0→1), clear FAILS.
        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: true)
        draft.selectShape("cloud")
        let edit = BotProfileEdit(
            metadata: draft.metadataAfterSave, metadataExpectedRevision: 0)
        let first = try await env.botManagement.applyAvatarAppearance(draft, edit: edit, to: bot)
        XCTAssertNotNil(first.partialFailure)

        // The sheet refreshes the roster, then reseeds (real sheet logic).
        bot.uiMetaRevisions = MetadataRevisions(revisions: [BotModeContract.botsMetaKey: 1])
        roster.upsertBot(bot)
        await rosterDouble.set(FleetRosterSnapshot(roster: roster, gatewayOutcomes: [:]))
        await env.refreshRoster()
        let reseeded = EditBotSheet.partialFailureReseed(
            draft: draft, metadataRevision: 0,
            outcome: first.editOutcome,
            rosterRevision: env.bot(for: bot.route)?
                .uiMetaRevisions?[BotModeContract.botsMetaKey])

        // The retry edit the sheet builds from the reseeded state: the
        // metadata matches the applied baseline → nil (never re-sent).
        let retryMetadata = reseeded.draft.metadataAfterSave
        let metadataCarried = (retryMetadata != reseeded.draft.baseline) ? retryMetadata : nil
        let retryEdit = BotProfileEdit(
            metadata: metadataCarried, metadataExpectedRevision: reseeded.revision)
        XCTAssertNil(retryEdit.metadata,
                     "retry must not re-send the applied metadata section")

        // Second save: NO CAS conflict, clear re-attempted, succeeds.
        let second = try await env.botManagement.applyAvatarAppearance(
            reseeded.draft, edit: retryEdit, to: bot)
        XCTAssertNil(second.partialFailure)
        XCTAssertTrue(second.succeeded, "the retry must complete the transaction")
        let attempts = await seam.clearAvatarAttempts
        XCTAssertEqual(attempts, 2, "the clear is re-attempted on retry")

        // Negative control — the defect mechanism itself: retrying the
        // ORIGINAL edit (applied metadata + stale revision 0) CAS-throws.
        do {
            _ = try await env.botManagement.applyAvatarAppearance(draft, edit: edit, to: bot)
            XCTFail("the stale-revision retry must CAS-conflict")
        } catch {
            // expected: revision conflict on the already-bumped key
        }
    }

    // MARK: - D2 (FOS-DF dogfood): slug keyboard traits

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
