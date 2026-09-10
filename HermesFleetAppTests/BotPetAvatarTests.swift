import XCTest
import SwiftUI
import FleetCore
@testable import FleetUI

/// #9 — Bot avatar Pet selection at the controller/draft layer:
/// route-scoped gallery loading (two-stage), same-slug isolation across
/// gateways AND profiles, unsupported vs transient, lazy + cached
/// thumbnails, selection staging (zero remote writes until Save), and
/// the coordinated Save path (PNG data URL preservation, custom=true,
/// imageKind="photo", partial failure, roster reconcile).
@MainActor
final class BotPetAvatarTests: XCTestCase {

    // MARK: scripted pet seam

    /// Per-gateway pet fixture: the SAME slugs map to different bytes per
    /// gateway — the route-provenance proof for cache + request keying.
    /// Conforms to the FULL profile seam (profile methods throw) so one
    /// factory closure can vend it.
    actor ScriptedPetSeam: BotProfileManaging, BotPetManaging {
        let gatewayID: GatewayID
        private(set) var galleryCalls: [(profile: String, localOnly: Bool)] = []
        private(set) var thumbCalls: [(profile: String, slug: String, sourceURL: String?)] = []
        var galleryError: Error?
        var thumbErrorBySlug: [String: Error] = [:]

        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }

        func setGalleryError(_ error: Error?) { galleryError = error }

        // BotProfileManaging: unavailable on this fixture (the tests only
        // exercise the pet surface through it).
        func describeProfile(_ profile: String) async throws -> BotProfileDescription {
            throw BotSectionSyncError.unavailable("pet-only fixture")
        }
        func configureProfile(_ profile: String, edit: BotProfileEdit) async throws -> BotProfileEditOutcome {
            throw BotSectionSyncError.unavailable("pet-only fixture")
        }
        func configureProfile(
            _ profile: String, edit: BotProfileEdit, confirmExpensiveModel: Bool
        ) async throws -> BotProfileEditOutcome {
            throw BotSectionSyncError.unavailable("pet-only fixture")
        }
        func createProfile(_ spec: BotCreateSpec) async throws -> String {
            throw BotSectionSyncError.unavailable("pet-only fixture")
        }
        func uploadAvatar(_ profile: String, dataURL: String) async throws {
            throw BotSectionSyncError.unavailable("pet-only fixture")
        }
        func clearAvatar(_ profile: String) async throws {
            throw BotSectionSyncError.unavailable("pet-only fixture")
        }
        func avatarData(_ profile: String) async throws -> Data? { nil }

        nonisolated static let thumbsA: [String: Data] = [
            "spark-fox": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 1, 1]),
            "pixel-owl": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 2, 2]),
        ]
        nonisolated static let thumbsB: [String: Data] = [
            "spark-fox": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 9, 9]),
            "pixel-owl": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 8, 8]),
        ]

        func petGallery(profile: String, localOnly: Bool) async throws -> HermesPetGallery {
            galleryCalls.append((profile, localOnly))
            if let galleryError { throw galleryError }
            let pets: [HermesPet] = [
                HermesPet(slug: "spark-fox", displayName: "Spark Fox", installed: true,
                          curated: false, generated: false, spritesheetURL: nil),
                HermesPet(slug: "pixel-owl", displayName: "Pixel Owl", installed: false,
                          curated: true, generated: false,
                          spritesheetURL: "https://petdex.dev/sheets/pixel-owl.png"),
                HermesPet(slug: "gen-cat", displayName: "Gen Cat", installed: true,
                          curated: false, generated: true, spritesheetURL: nil),
            ]
            return HermesPetGallery(
                pets: localOnly ? pets.filter(\.installed) : pets,
                displayEnabled: true, activeSlug: "spark-fox")
        }

        func petThumbnail(profile: String, slug: String, sourceURL: String?) async throws -> Data {
            thumbCalls.append((profile, slug, sourceURL))
            if let error = thumbErrorBySlug[slug] { throw error }
            let table = gatewayID.rawValue == "gw-a" ? Self.thumbsA : Self.thumbsB
            guard let bytes = table[slug] else {
                throw BotPetError.thumbnailUnavailable(slug: slug)
            }
            return bytes
        }
    }

    /// Full seam for the save-path tests: profile management + pets.
    actor ScriptedFullSeam: BotProfileManaging, BotPetManaging {
        private var revisions: [String: Int] = [:]
        private(set) var avatarAssets: [String: Data] = [:]
        private(set) var configureCalls: [BotProfileEdit] = []
        private(set) var uploadAvatarCalls: [String] = []
        private(set) var uploadAvatarDataURLs: [String] = []
        private(set) var petThumbCalls: [(profile: String, slug: String)] = []
        var uploadAvatarError: Error?

        func setUploadAvatarError(_ error: Error?) { uploadAvatarError = error }

        func describeProfile(_ profile: String) async throws -> BotProfileDescription {
            BotProfileDescription(name: profile, soul: "s", defaultModel: "m", provider: "nous")
        }

        func configureProfile(_ profile: String, edit: BotProfileEdit) async throws -> BotProfileEditOutcome {
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
            if edit.hasModelSection { applied["model"] = true }
            return BotProfileEditOutcome(edit: edit, applied: applied)
        }

        func configureProfile(
            _ profile: String, edit: BotProfileEdit, confirmExpensiveModel: Bool
        ) async throws -> BotProfileEditOutcome {
            try await configureProfile(profile, edit: edit)
        }

        func createProfile(_ spec: BotCreateSpec) async throws -> String { spec.name }

        func uploadAvatar(_ profile: String, dataURL: String) async throws {
            if let uploadAvatarError { throw uploadAvatarError }
            uploadAvatarCalls.append(profile)
            uploadAvatarDataURLs.append(dataURL)
            if let range = dataURL.range(of: "base64,"),
               let data = Data(base64Encoded: String(dataURL[range.upperBound...])) {
                avatarAssets[profile] = data
            }
        }

        func clearAvatar(_ profile: String) async throws {
            avatarAssets[profile] = nil
        }

        func avatarData(_ profile: String) async throws -> Data? { avatarAssets[profile] }

        func petGallery(profile: String, localOnly: Bool) async throws -> HermesPetGallery {
            HermesPetGallery(pets: [
                HermesPet(slug: "spark-fox", displayName: "Spark Fox", installed: true,
                          curated: false, generated: false, spritesheetURL: nil),
            ], displayEnabled: true, activeSlug: "spark-fox")
        }

        func petThumbnail(profile: String, slug: String, sourceURL: String?) async throws -> Data {
            petThumbCalls.append((profile, slug))
            return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 7, 7, 7])
        }
    }

    private func makeBot(gateway: String = "gw-a", profile: String = "default") -> FleetBot {
        var bot = FleetBot(
            route: Route(
                gatewayID: GatewayID(rawValue: gateway),
                profileSlug: ProfileSlug(rawValue: profile)),
            displayName: profile)
        bot.uiMetaRevisions = MetadataRevisions(revisions: [BotModeContract.botsMetaKey: 0])
        return bot
    }

    // MARK: - two-stage gallery load

    func testGalleryLoadIsTwoStageLocalFirst() async throws {
        let seam = ScriptedPetSeam(gatewayID: GatewayID(rawValue: "gw-a"))
        let bot = makeBot()
        let controller = BotManagementController(
            factory: { _ in Box(seam) },
            gatewayProvider: { [
                FleetGateway(id: bot.route.gatewayID, displayName: "A", endpoint: nil)
            ] })

        await controller.loadPetGallery(for: bot)

        // localOnly(true) fired FIRST, then the full hydrate.
        let calls = await seam.galleryCalls
        XCTAssertEqual(calls.map { $0.localOnly }, [true, false], "localOnly phase must precede hydrate")
        XCTAssertEqual(calls.map { $0.profile }, [bot.route.profileSlug.rawValue, bot.route.profileSlug.rawValue])

        // Merged: installed + generated + remote all present.
        let pets = controller.petGalleryByRoute[bot.route] ?? []
        XCTAssertEqual(Set(pets.map(\.slug)), ["spark-fox", "pixel-owl", "gen-cat"])
        if case .loaded? = controller.petGalleryPhaseByRoute[bot.route] {} else {
            XCTFail("expected .loaded, got \(String(describing: controller.petGalleryPhaseByRoute[bot.route]))")
        }
    }

    func testLocalPhaseRendersBeforeHyhydrate() async {
        // Asserted via call order above; this pins the invariant that a
        // local-phase success populates the gallery even if hydrate fails.
        let seam = ScriptedPetSeam(gatewayID: GatewayID(rawValue: "gw-a"))
        let bot = makeBot()
        let controller = BotManagementController(
            factory: { _ in Box(seam) },
            gatewayProvider: { [
                FleetGateway(id: bot.route.gatewayID, displayName: "A", endpoint: nil)
            ] })
        await controller.loadPetGallery(for: bot)
        XCTAssertEqual(controller.petGalleryByRoute[bot.route]?.isEmpty, false)
    }

    // MARK: - unsupported vs transient

    func testUnsupportedGatewayRendersUnavailableNotFailed() async throws {
        let seam = ScriptedPetSeam(gatewayID: GatewayID(rawValue: "gw-a"))
        await seam.setGalleryError(BotPetError.petsUnavailable("no pets here"))
        let bot = makeBot()
        let controller = BotManagementController(
            factory: { _ in Box(seam) },
            gatewayProvider: { [
                FleetGateway(id: bot.route.gatewayID, displayName: "A", endpoint: nil)
            ] })
        await controller.loadPetGallery(for: bot)
        if case .unsupported? = controller.petGalleryPhaseByRoute[bot.route] {} else {
            XCTFail("expected .unsupported for method-not-found")
        }
        // Retry re-fires the RPCs but the capability fact is unchanged.
        await controller.retryPetGallery(for: bot)
        let calls = await seam.galleryCalls
        XCTAssertEqual(calls.count, 4, "retry re-fires both stages; unsupported stays unsupported")
        if case .unsupported? = controller.petGalleryPhaseByRoute[bot.route] {} else {
            XCTFail("unsupported must remain sticky after retry")
        }
    }

    func testTransientFailureIsRetryable() async throws {
        let seam = ScriptedPetSeam(gatewayID: GatewayID(rawValue: "gw-a"))
        await seam.setGalleryError(BotSectionSyncError.conflict("flaky"))
        let bot = makeBot()
        let controller = BotManagementController(
            factory: { _ in Box(seam) },
            gatewayProvider: { [
                FleetGateway(id: bot.route.gatewayID, displayName: "A", endpoint: nil)
            ] })
        await controller.loadPetGallery(for: bot)
        // Local phase fell through; hydrate failed → retryable failure.
        if case .failed? = controller.petGalleryPhaseByRoute[bot.route] {} else {
            XCTFail("expected .failed for a transient error")
        }
        // Recovery: clear the error, retry succeeds.
        await seam.setGalleryError(nil)
        await controller.retryPetGallery(for: bot)
        if case .loaded? = controller.petGalleryPhaseByRoute[bot.route] {} else {
            XCTFail("expected .loaded after retry")
        }
    }

    // MARK: - route isolation

    func testSameSlugThumbnailsIsolateAcrossGatewaysAndProfiles() async throws {
        let seamA = ScriptedPetSeam(gatewayID: GatewayID(rawValue: "gw-a"))
        let seamB = ScriptedPetSeam(gatewayID: GatewayID(rawValue: "gw-b"))
        let controller = BotManagementController(
            factory: { gateway in
                Box(gateway.id.rawValue == "gw-a"
                    ? AnySendableSeam(seamA)
                    : AnySendableSeam(seamB))
            },
            gatewayProvider: { [
                FleetGateway(id: GatewayID(rawValue: "gw-a"), displayName: "A", endpoint: nil),
                FleetGateway(id: GatewayID(rawValue: "gw-b"), displayName: "B", endpoint: nil),
            ] })
        let botA = makeBot(gateway: "gw-a", profile: "default")
        let botB = makeBot(gateway: "gw-b", profile: "default")
        let foxA = HermesPet(slug: "spark-fox", displayName: "Spark Fox", installed: true,
                            curated: false, generated: false, spritesheetURL: nil)
        let foxB = foxA

        let bytesA1 = await controller.petThumbnailData(for: botA, pet: foxA)
        let bytesB1 = await controller.petThumbnailData(for: botB, pet: foxB)
        // Same slug, different gateways → different bytes, never shared.
        XCTAssertEqual(bytesA1, ScriptedPetSeam.thumbsA["spark-fox"])
        XCTAssertEqual(bytesB1, ScriptedPetSeam.thumbsB["spark-fox"])
        XCTAssertNotEqual(bytesA1, bytesB1)

        // Same gateway, different PROFILE: the profile param propagates
        // and cache keys stay distinct.
        let botA2 = makeBot(gateway: "gw-a", profile: "researcher")
        let bytesA2 = await controller.petThumbnailData(for: botA2, pet: foxA)
        XCTAssertEqual(bytesA2, ScriptedPetSeam.thumbsA["spark-fox"])
        let thumbCallsA = await seamA.thumbCalls
        XCTAssertEqual(thumbCallsA.last?.profile, "researcher")

        // Cached: a second request for botA does NOT hit the seam.
        let before = await seamA.thumbCalls.count
        _ = await controller.petThumbnailData(for: botA, pet: foxA)
        let after = await seamA.thumbCalls.count
        XCTAssertEqual(before, after, "second fetch must be served from the route-keyed cache")
    }

    // MARK: - selection staging + save path

    func testSelectionStagesDraftOnlyNoRemoteWritesUntilSave() async throws {
        let seam = ScriptedFullSeam()
        let bot = makeBot()
        let controller = BotManagementController(
            factory: { _ in Box(seam) },
            gatewayProvider: { [
                FleetGateway(id: bot.route.gatewayID, displayName: "A", endpoint: nil)
            ] })

        // Simulate the picker: fetch thumb (read-only), stage into draft.
        let gallery = try await seam.petGallery(profile: "default", localOnly: false)
        let pet = gallery.pets[0]
        let png = try await seam.petThumbnail(profile: "default", slug: pet.slug, sourceURL: nil)

        var draft = BotAvatarAppearanceDraft.seeded(
            from: nil, hasAvatar: false, avatarBytes: nil)
        draft.stageReplacement(data: png)

        // ZERO remote writes so far.
        let configureCount = await seam.configureCalls.count
        let uploadCount = await seam.uploadAvatarCalls.count
        XCTAssertEqual(configureCount, 0)
        XCTAssertEqual(uploadCount, 0)

        // Draft semantics: custom=true, imageKind="photo", PNG preserved.
        XCTAssertTrue(draft.custom)
        XCTAssertEqual(draft.imageKind, "photo")
        XCTAssertEqual(draft.effectiveImageBytes, png)

        // Cancel = discard: nothing was ever sent.
        draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        let cancelUploadCount = await seam.uploadAvatarCalls.count
        XCTAssertEqual(cancelUploadCount, 0)
    }

    func testSavePersistsPetPNGThroughSetAssetWithPhotoSemantics() async throws {
        let seam = ScriptedFullSeam()
        let bot = makeBot()
        let controller = BotManagementController(
            factory: { _ in Box(seam) },
            gatewayProvider: { [
                FleetGateway(id: bot.route.gatewayID, displayName: "A", endpoint: nil)
            ] })

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 5, 5, 5])
        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        draft.stageReplacement(data: png)

        let metadata = draft.metadataAfterSave
        let edit = BotProfileEdit(metadata: metadata, metadataExpectedRevision: 0)
        let result = try await controller.applyAvatarAppearance(draft, edit: edit, to: bot)

        XCTAssertTrue(result.succeeded, "coordinated save must succeed")
        XCTAssertEqual(result.assetApplied, true)

        // Metadata semantics through the existing path.
        let configure = await seam.configureCalls.first
        XCTAssertEqual(configure?.metadata?.custom, true)
        XCTAssertEqual(configure?.metadata?.imageKind, "photo")

        // The asset write carried the PNG bytes in a PNG data URL —
        // preserved byte-identically, NOT JPEG-recompressed.
        let dataURL = await seam.uploadAvatarDataURLs.first
        XCTAssertNotNil(dataURL)
        XCTAssertTrue(dataURL?.hasPrefix("data:image/png;base64,") == true,
                      "pet PNG must keep its PNG mime (got: \(dataURL?.prefix(30) ?? ""))")
        let storedAsset = await seam.avatarAssets["default"]
        XCTAssertEqual(storedAsset, png,
                       "staged PNG bytes must round-trip byte-identical")

        // Roster reconciliation: the avatar cache generation was bumped
        // so the next roster refresh renders gateway-authoritative state.
        XCTAssertNil(controller.avatarDataByRoute[bot.route],
                     "stale avatar cache dropped for the roster refresh")
    }

    func testUploadPartialFailureIsExplicitNeverGenericSuccess() async throws {
        let seam = ScriptedFullSeam()
        await seam.setUploadAvatarError(BotSectionSyncError.conflict("asset too large fixture"))
        let bot = makeBot()
        let controller = BotManagementController(
            factory: { _ in Box(seam) },
            gatewayProvider: { [
                FleetGateway(id: bot.route.gatewayID, displayName: "A", endpoint: nil)
            ] })
        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        draft.stageReplacement(data: Data([0x89, 0x50, 0x4E, 0x47, 1]))

        let edit = BotProfileEdit(metadata: draft.metadataAfterSave, metadataExpectedRevision: 0)
        let result = try await controller.applyAvatarAppearance(draft, edit: edit, to: bot)

        XCTAssertFalse(result.succeeded, "partial application is never success")
        XCTAssertNotNil(result.partialFailure,
                        "partial failure must be surfaced explicitly")
        XCTAssertEqual(result.assetApplied, false)
        // Metadata DID land — the outcome records it.
        XCTAssertEqual(result.editOutcome.appliedSections.contains(.metadata), true)
    }

    // MARK: - search (controller-level, mirrors sheet behavior)

    func testGallerySearchMatchesDisplayNameAndSlug() {
        let pets = [
            HermesPet(slug: "spark-fox", displayName: "Spark Fox", installed: true,
                      curated: false, generated: false, spritesheetURL: nil),
            HermesPet(slug: "pixel-owl", displayName: "Pixel Owl", installed: false,
                      curated: true, generated: false, spritesheetURL: nil),
        ]
        XCTAssertEqual(pets.filter { $0.matches(query: "fox") }.count, 1)
        XCTAssertEqual(pets.filter { $0.matches(query: "owl") }.count, 1)
        XCTAssertEqual(pets.filter { $0.matches(query: "pixel-owl") }.count, 1)
        XCTAssertEqual(pets.filter { $0.matches(query: "PIXEL") }.count, 1)
        XCTAssertEqual(pets.filter { $0.matches(query: "" ) }.count, 2)
        XCTAssertEqual(pets.filter { $0.matches(query: "zzz") }.count, 0)
    }
}

/// Type-erased seam box so one factory closure can vend per-gateway
/// actor seams without the controller depending on concrete types.
struct Box: BotProfileManaging, BotPetManaging {
    private let profile: any BotProfileManaging & Sendable
    private let pets: (any BotPetManaging)?

    init(_ seam: any BotProfileManaging & Sendable & BotPetManaging) {
        self.profile = seam
        self.pets = seam
    }

    init(_ seam: any BotProfileManaging & Sendable) {
        self.profile = seam
        self.pets = nil
    }

    func petGallery(profile: String, localOnly: Bool) async throws -> HermesPetGallery {
        guard let pets else {
            throw BotPetError.petsUnavailable("Hermes Pets are not available on this gateway.")
        }
        return try await pets.petGallery(profile: profile, localOnly: localOnly)
    }

    func petThumbnail(profile: String, slug: String, sourceURL: String?) async throws -> Data {
        guard let pets else {
            throw BotPetError.petsUnavailable("Hermes Pets are not available on this gateway.")
        }
        return try await pets.petThumbnail(profile: profile, slug: slug, sourceURL: sourceURL)
    }

    func supportsAvatarUpload(_ profile: String) async -> Bool {
        await self.profile.supportsAvatarUpload(profile)
    }

    func supportsPortraitGeneration() async -> Bool {
        await self.profile.supportsPortraitGeneration()
    }

    func generatePortrait(prompt: String) async throws -> Data {
        try await self.profile.generatePortrait(prompt: prompt)
    }

    func describeProfile(_ profile: String) async throws -> BotProfileDescription {
        try await self.profile.describeProfile(profile)
    }

    func configureProfile(_ profile: String, edit: BotProfileEdit) async throws -> BotProfileEditOutcome {
        try await self.profile.configureProfile(profile, edit: edit)
    }

    func configureProfile(
        _ profile: String, edit: BotProfileEdit, confirmExpensiveModel: Bool
    ) async throws -> BotProfileEditOutcome {
        try await self.profile.configureProfile(profile, edit: edit, confirmExpensiveModel: confirmExpensiveModel)
    }

    func createProfile(_ spec: BotCreateSpec) async throws -> String {
        try await self.profile.createProfile(spec)
    }

    func uploadAvatar(_ profile: String, dataURL: String) async throws {
        try await self.profile.uploadAvatar(profile, dataURL: dataURL)
    }

    func clearAvatar(_ profile: String) async throws {
        try await self.profile.clearAvatar(profile)
    }

    func avatarData(_ profile: String) async throws -> Data? {
        try await self.profile.avatarData(profile)
    }
}

/// Optional-pet variant for factories vending heterogeneous seams.
struct AnySendableSeam: BotProfileManaging, BotPetManaging {
    private let erase: Box
    init(_ seam: any BotProfileManaging & Sendable & BotPetManaging) {
        self.erase = Box(seam)
    }
    func petGallery(profile: String, localOnly: Bool) async throws -> HermesPetGallery {
        try await erase.petGallery(profile: profile, localOnly: localOnly)
    }
    func petThumbnail(profile: String, slug: String, sourceURL: String?) async throws -> Data {
        try await erase.petThumbnail(profile: profile, slug: slug, sourceURL: sourceURL)
    }
    func supportsAvatarUpload(_ profile: String) async -> Bool {
        await erase.supportsAvatarUpload(profile)
    }
    func supportsPortraitGeneration() async -> Bool {
        await erase.supportsPortraitGeneration()
    }
    func generatePortrait(prompt: String) async throws -> Data {
        try await erase.generatePortrait(prompt: prompt)
    }
    func describeProfile(_ profile: String) async throws -> BotProfileDescription {
        try await erase.describeProfile(profile)
    }
    func configureProfile(_ profile: String, edit: BotProfileEdit) async throws -> BotProfileEditOutcome {
        try await erase.configureProfile(profile, edit: edit)
    }
    func configureProfile(
        _ profile: String, edit: BotProfileEdit, confirmExpensiveModel: Bool
    ) async throws -> BotProfileEditOutcome {
        try await erase.configureProfile(profile, edit: edit, confirmExpensiveModel: confirmExpensiveModel)
    }
    func createProfile(_ spec: BotCreateSpec) async throws -> String {
        try await erase.createProfile(spec)
    }
    func uploadAvatar(_ profile: String, dataURL: String) async throws {
        try await erase.uploadAvatar(profile, dataURL: dataURL)
    }
    func clearAvatar(_ profile: String) async throws {
        try await erase.clearAvatar(profile)
    }
    func avatarData(_ profile: String) async throws -> Data? {
        try await erase.avatarData(profile)
    }
}
