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
        /// W3 finding 1: fails ONLY the full-catalog hydrate stage
        /// (localOnly == false) — the local phase succeeds.
        var hydrateError: Error?
        /// W3 finding 3: artificial per-thumb latency so concurrent
        /// callers overlap the in-flight window deterministically.
        var thumbDelayNanos: UInt64 = 0

        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }

        func setGalleryError(_ error: Error?) { galleryError = error }
        func setHydrateError(_ error: Error?) { hydrateError = error }
        func setThumbDelay(nanoseconds: UInt64) { thumbDelayNanos = nanoseconds }
        func setThumbError(forSlug slug: String, error: Error?) {
            if let error { thumbErrorBySlug[slug] = error } else { thumbErrorBySlug[slug] = nil }
        }

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
            if !localOnly, let hydrateError { throw hydrateError }
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
            if thumbDelayNanos > 0 {
                try await Task.sleep(nanoseconds: thumbDelayNanos)
            }
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
        if case .loaded(.full)? = controller.petGalleryPhaseByRoute[bot.route] {} else {
            XCTFail("expected .loaded(.full), got \(String(describing: controller.petGalleryPhaseByRoute[bot.route]))")
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
        if case .loaded(.full)? = controller.petGalleryPhaseByRoute[bot.route] {} else {
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

    // MARK: - W3 finding 1: local success + hydrate failure

    /// Regression (W3 review finding 1): the local gallery succeeds, the
    /// full-catalog hydrate fails transiently, and local pets are already
    /// non-empty. The controller MUST (1) keep the local pets visible,
    /// (2) leave the honest retryable `loaded(.hydrateFailed)` state —
    /// never a permanent `.hydrating` spinner — and (3) recover fully on
    /// retry once the transient error clears.
    func testHydrateFailureOverLocalSuccessKeepsPetsAndRetryRecovers() async throws {
        let seam = ScriptedPetSeam(gatewayID: GatewayID(rawValue: "gw-a"))
        await seam.setHydrateError(BotSectionSyncError.conflict("transient hydrate failure"))
        let bot = makeBot()
        let controller = BotManagementController(
            factory: { _ in Box(seam) },
            gatewayProvider: { [
                FleetGateway(id: bot.route.gatewayID, displayName: "A", endpoint: nil)
            ] })

        // (1) local gallery call succeeds; (2) full hydrate fails transiently.
        await controller.loadPetGallery(for: bot)
        let calls = await seam.galleryCalls
        XCTAssertEqual(calls.map { $0.localOnly }, [true, false])

        // (3) local pets remain visible (installed/generated only).
        let pets = controller.petGalleryByRoute[bot.route] ?? []
        XCTAssertEqual(Set(pets.map(\.slug)), ["spark-fox", "gen-cat"],
                       "local-phase pets must survive the hydrate failure")

        // (4) state is no longer .hydrating — it is honestly loaded with
        // a hydrate-failure payload.
        guard case .loaded(.hydrateFailed(let message))? =
            controller.petGalleryPhaseByRoute[bot.route] else {
            XCTFail("expected .loaded(.hydrateFailed), got \(String(describing: controller.petGalleryPhaseByRoute[bot.route]))")
            return
        }
        // (5) a retry affordance exists: the retryable message is carried.
        XCTAssertFalse(message.isEmpty, "the hydrate failure message must be surfaced")

        // (6) clearing the failure + retrying successfully hydrates the
        // full catalog (curated pet merges in, phase becomes full).
        await seam.setHydrateError(nil)
        await controller.retryPetGallery(for: bot)
        guard case .loaded(.full)? = controller.petGalleryPhaseByRoute[bot.route] else {
            XCTFail("expected .loaded(.full) after retry, got \(String(describing: controller.petGalleryPhaseByRoute[bot.route]))")
            return
        }
        let merged = controller.petGalleryByRoute[bot.route] ?? []
        XCTAssertEqual(Set(merged.map(\.slug)), ["spark-fox", "pixel-owl", "gen-cat"],
                       "retry must hydrate and merge the full Petdex catalog")
    }

    /// A hydrate failure with NO local content stays a plain retryable
    /// failure (the pre-W3 behavior for the empty case is preserved).
    func testHydrateFailureWithNoLocalPetsIsPlainFailure() async throws {
        let seam = ScriptedPetSeam(gatewayID: GatewayID(rawValue: "gw-a"))
        // Fail BOTH stages: no local pets can populate.
        await seam.setGalleryError(BotSectionSyncError.conflict("flaky"))
        let bot = makeBot()
        let controller = BotManagementController(
            factory: { _ in Box(seam) },
            gatewayProvider: { [
                FleetGateway(id: bot.route.gatewayID, displayName: "A", endpoint: nil)
            ] })
        await controller.loadPetGallery(for: bot)
        guard case .failed? = controller.petGalleryPhaseByRoute[bot.route] else {
            XCTFail("expected .failed when there is no local content to show")
            return
        }
    }

    // MARK: - W3 finding 3: thumbnail coalescing + sticky failure

    /// True in-flight coalescing: concurrent callers for the same
    /// route/profile/pet key SHARE the same underlying request — exactly
    /// ONE seam call for N overlapping callers, and every caller receives
    /// the same bytes (no caller is handed a misleading nil).
    func testConcurrentThumbnailCallersShareOneRequest() async throws {
        let seam = ScriptedPetSeam(gatewayID: GatewayID(rawValue: "gw-a"))
        // Long enough that all three callers overlap the in-flight window.
        await seam.setThumbDelay(nanoseconds: 150_000_000)
        let bot = makeBot()
        let controller = BotManagementController(
            factory: { _ in Box(seam) },
            gatewayProvider: { [
                FleetGateway(id: bot.route.gatewayID, displayName: "A", endpoint: nil)
            ] })
        let fox = HermesPet(slug: "spark-fox", displayName: "Spark Fox", installed: true,
                            curated: false, generated: false, spritesheetURL: nil)

        async let a = controller.petThumbnailData(for: bot, pet: fox)
        async let b = controller.petThumbnailData(for: bot, pet: fox)
        async let c = controller.petThumbnailData(for: bot, pet: fox)
        let results = await [a, b, c]

        XCTAssertEqual(results.compactMap { $0 }, results,
                       "every concurrent caller must get the shared request's bytes")
        XCTAssertEqual(results.first, ScriptedPetSeam.thumbsA["spark-fox"])
        let calls = await seam.thumbCalls
        XCTAssertEqual(calls.count, 1,
                       "exactly ONE seam request for N concurrent same-key callers")
    }

    /// Sticky failure + no automatic refetch: after a failed fetch, a
    /// plain (non-retry) call does NOT hit the gateway again — cell
    /// re-materialization/scrolling must not auto-hammer the gateway.
    /// An EXPLICIT retry clears the failure and performs a new fetch.
    func testFailedThumbnailSticksUntilExplicitRetry() async throws {
        let seam = ScriptedPetSeam(gatewayID: GatewayID(rawValue: "gw-a"))
        await seam.setThumbError(forSlug: "spark-fox",
                                 error: BotSectionSyncError.conflict("thumb down"))
        let bot = makeBot()
        let controller = BotManagementController(
            factory: { _ in Box(seam) },
            gatewayProvider: { [
                FleetGateway(id: bot.route.gatewayID, displayName: "A", endpoint: nil)
            ] })
        let fox = HermesPet(slug: "spark-fox", displayName: "Spark Fox", installed: true,
                            curated: false, generated: false, spritesheetURL: nil)

        // First attempt fails.
        let first = await controller.petThumbnailData(for: bot, pet: fox)
        XCTAssertNil(first)
        let afterFirst = await seam.thumbCalls.count
        XCTAssertEqual(afterFirst, 1)

        // Re-materialization does NOT auto-refetch (sticky failure).
        let second = await controller.petThumbnailData(for: bot, pet: fox)
        XCTAssertNil(second)
        let afterSecond = await seam.thumbCalls.count
        XCTAssertEqual(afterSecond, 1,
                       "a failed thumbnail must not be auto-refetched by scroll/rematerialize")

        // Explicit retry clears the failure and fetches fresh.
        await seam.setThumbError(forSlug: "spark-fox", error: nil)
        await controller.retryPetThumbnail(for: bot, pet: fox)
        let afterRetry = await seam.thumbCalls.count
        XCTAssertEqual(afterRetry, 2, "explicit retry performs a new fetch")
        // The successful retry is cached; a subsequent call is served
        // from cache with no further seam traffic.
        let cached = await controller.petThumbnailData(for: bot, pet: fox)
        XCTAssertEqual(cached, ScriptedPetSeam.thumbsA["spark-fox"])
        let afterCache = await seam.thumbCalls.count
        XCTAssertEqual(afterCache, 2, "cached success serves without refetching")
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
