import XCTest
@testable import FleetCore

/// #7 — unified staged avatar appearance draft: seeding, staging semantics,
/// image supersession, explicit customization metadata, and the derived
/// save payload. All deterministic domain behavior; no networking.
final class BotAvatarAppearanceDraftTests: XCTestCase {

    // MARK: - Seeding

    func testSeededFromShapeOnlyBot() {
        var meta = BotModeMetadata()
        meta.shape = "hexagon"
        meta.color = "#334455"
        let draft = BotAvatarAppearanceDraft.seeded(from: meta, hasAvatar: false)
        XCTAssertEqual(draft.shape, "hexagon")
        XCTAssertEqual(draft.color, "#334455")
        XCTAssertEqual(draft.image, .unchanged)
        XCTAssertFalse(draft.hasRemoteImage)
        XCTAssertNil(draft.previewImageBytes)
        XCTAssertFalse(draft.isDirty)
    }

    func testSeededFromBotWithActiveImageAsset() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        var meta = BotModeMetadata()
        meta.shape = "circle"
        meta.custom = true
        meta.imageKind = "photo"
        let draft = BotAvatarAppearanceDraft.seeded(
            from: meta, hasAvatar: true, avatarBytes: bytes)
        XCTAssertTrue(draft.hasRemoteImage)
        XCTAssertEqual(draft.previewImageBytes, bytes)
        XCTAssertEqual(draft.imageKind, "photo")
        XCTAssertEqual(draft.effectiveImageBytes, bytes)
        XCTAssertFalse(draft.isDirty)
        // Metadata round-trips unchanged when untouched.
        XCTAssertEqual(draft.metadataAfterSave, meta)
    }

    func testSeedFromAbsentMetadataIsTheEmptyDraft() {
        let draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        XCTAssertNil(draft.shape)
        XCTAssertNil(draft.color)
        XCTAssertEqual(draft.image, .unchanged)
        XCTAssertFalse(draft.custom)
        XCTAssertFalse(draft.isDirty)
    }

    // MARK: - Shape selection

    func testSelectingShapeStagesImageRemovalNotImmediateMutation() {
        let draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: true)
        var edited = draft
        edited.selectShape("cloud")
        XCTAssertEqual(edited.shape, "cloud")
        XCTAssertEqual(edited.image, .remove, "shape selection must STAGE removal")
        XCTAssertNil(edited.effectiveImageBytes, "preview must fall back to the shape")
    }

    func testSelectingShapeWithoutExistingImageDoesNotStageRemoval() {
        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        draft.selectShape("hexagon")
        XCTAssertEqual(draft.image, .unchanged)
    }

    func testSelectingShapeSetsExplicitCustomizationMetadata() {
        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        draft.selectShape("cloud")
        XCTAssertTrue(draft.isDirty)
        let meta = draft.metadataAfterSave
        XCTAssertEqual(meta.shape, "cloud")
        XCTAssertEqual(meta.custom, true)
        XCTAssertEqual(meta.imageKind, "shape")
    }

    func testSelectingShapeOnDefaultProfileMarksCustom() {
        // The primary `default` profile must honor explicit customization
        // instead of remaining on the deterministic fallback — no
        // special-casing, same metadata semantics for every profile.
        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        draft.selectShape("drop")
        XCTAssertEqual(draft.metadataAfterSave.custom, true)
        XCTAssertEqual(draft.metadataAfterSave.imageKind, "shape")
    }

    func testSelectingDeterministicDefaultClearsStagedShape() {
        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        draft.selectShape("cloud")
        draft.selectShape("")
        XCTAssertNil(draft.shape)
        XCTAssertTrue(draft.custom, "an explicit choice stays customization")
    }

    // MARK: - Color

    func testSelectingColorSetsCustomizationKeepsShapeKind() {
        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        draft.selectShape("pill")
        draft.selectColor("#101010")
        XCTAssertEqual(draft.metadataAfterSave.color, "#101010")
        XCTAssertEqual(draft.metadataAfterSave.imageKind, "shape")
        XCTAssertTrue(draft.metadataAfterSave.custom ?? false)
    }

    // MARK: - Image staging

    func testSelectingImageStagesReplacementAndCorrectImageKind() {
        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        let bytes = Data(repeating: 1, count: 16)
        draft.stageReplacement(data: bytes)
        XCTAssertEqual(draft.image, .replacement(bytes))
        XCTAssertEqual(draft.previewImageBytes, bytes)
        XCTAssertEqual(draft.effectiveImageBytes, bytes)
        let meta = draft.metadataAfterSave
        XCTAssertEqual(meta.custom, true)
        XCTAssertEqual(meta.imageKind, "photo")
    }

    func testImageStagedOverExistingImageSupersedesIt() {
        let old = Data(repeating: 2, count: 8)
        var draft = BotAvatarAppearanceDraft.seeded(
            from: nil, hasAvatar: true, avatarBytes: old)
        let fresh = Data(repeating: 3, count: 9)
        draft.stageReplacement(data: fresh)
        XCTAssertEqual(draft.image, .replacement(fresh))
        XCTAssertEqual(draft.effectiveImageBytes, fresh)
    }

    func testClearStagesRemovalAndFallsBackToShape() {
        var meta = BotModeMetadata()
        meta.shape = "squircle"
        meta.custom = true
        meta.imageKind = "photo"
        var draft = BotAvatarAppearanceDraft.seeded(
            from: meta, hasAvatar: true, avatarBytes: Data([1]))
        draft.stageRemoval()
        XCTAssertEqual(draft.image, .remove)
        XCTAssertNil(draft.effectiveImageBytes)
        XCTAssertEqual(draft.metadataAfterSave.imageKind, "shape")
        XCTAssertEqual(draft.metadataAfterSave.shape, "squircle")
    }

    // MARK: - Transitions

    func testShapeToImageTransition() {
        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        draft.selectShape("cloud")
        let bytes = Data(repeating: 9, count: 4)
        draft.stageReplacement(data: bytes)
        XCTAssertEqual(draft.image, .replacement(bytes))
        XCTAssertEqual(draft.metadataAfterSave.imageKind, "photo")
        // Shape stays persisted as fallback metadata (upstream allows it).
        XCTAssertEqual(draft.metadataAfterSave.shape, "cloud")
    }

    func testImageToShapeTransitionStagesRemoval() {
        var draft = BotAvatarAppearanceDraft.seeded(
            from: nil, hasAvatar: true, avatarBytes: Data([1]))
        draft.stageReplacement(data: Data([2]))
        draft.selectShape("triangle")
        XCTAssertEqual(draft.image, .remove)
        XCTAssertEqual(draft.metadataAfterSave.imageKind, "shape")
        XCTAssertEqual(draft.metadataAfterSave.shape, "triangle")
    }

    func testImageToShapeThenBackToImageIsReplacement() {
        var draft = BotAvatarAppearanceDraft.seeded(
            from: nil, hasAvatar: true, avatarBytes: Data([1]))
        draft.selectShape("circle")
        draft.stageReplacement(data: Data([5]))
        XCTAssertEqual(draft.image, .replacement(Data([5])))
        XCTAssertEqual(draft.effectiveImageBytes, Data([5]))
    }

    // MARK: - Baseline retention

    func testUnknownMetadataKeysSurviveTheDraft() {
        var meta = BotModeMetadata()
        meta.shape = "circle"
        meta.unknownKeys = ["futureField": .string("keep-me")]
        var draft = BotAvatarAppearanceDraft.seeded(from: meta, hasAvatar: false)
        draft.selectShape("cloud")
        XCTAssertEqual(
            draft.metadataAfterSave.unknownKeys["futureField"],
            .string("keep-me"),
            "unknown hermes-bots keys must round-trip the draft")
    }

    func testBaselineFieldsSurviveIntoSavePayload() {
        var meta = BotModeMetadata()
        meta.title = "Researcher"
        meta.hidden = true
        meta.sectionID = "sec-1"
        var draft = BotAvatarAppearanceDraft.seeded(from: meta, hasAvatar: false)
        draft.selectShape("cloud")
        let saved = draft.metadataAfterSave
        XCTAssertEqual(saved.title, "Researcher")
        XCTAssertEqual(saved.hidden, true)
        XCTAssertEqual(saved.sectionID, "sec-1")
        XCTAssertEqual(saved.shape, "cloud")
    }

    // MARK: - Dirty tracking

    func testUntouchedDraftIsNotDirtyAndCancelIsASafeNoOp() {
        var meta = BotModeMetadata()
        meta.shape = "cloud"
        meta.custom = true
        meta.imageKind = "shape"
        let draft = BotAvatarAppearanceDraft.seeded(from: meta, hasAvatar: false)
        XCTAssertFalse(draft.isDirty, "a seeded, untouched draft requests no writes")
    }

    // MARK: - Post-partial-failure reseed (t_3ce28479)

    /// After a partial failure (metadata applied, asset mutation failed),
    /// the draft must advance its baseline to the applied metadata so a
    /// retry saves ONLY the still-failing asset mutation — never a stale
    /// metadata write that would CAS-conflict.
    func testNoteMetadataAppliedAdvancesBaselineKeepingStagedAsset() {
        var meta = BotModeMetadata()
        meta.title = "Original"
        var draft = BotAvatarAppearanceDraft.seeded(from: meta, hasAvatar: true)
        draft.selectShape("cloud") // stages .remove over the remote image
        XCTAssertTrue(draft.isDirty)

        draft.noteMetadataApplied()

        XCTAssertEqual(draft.metadataAfterSave.title, "Original",
                       "applied metadata is the new baseline")
        XCTAssertEqual(draft.metadataAfterSave.shape, "cloud",
                       "the applied shape stays in the baseline")
        XCTAssertEqual(draft.metadataAfterSave.imageKind, "shape",
                       "imageKind semantics stay in the baseline")
        XCTAssertEqual(draft.image, .remove,
                       "the still-failing staged asset mutation is preserved")
        XCTAssertTrue(draft.hasRemoteImage,
                      "the remote image is still authoritative — the clear failed")
        XCTAssertEqual(draft.metadataAfterSave, draft.baseline,
                       "after reseed the metadata section must NOT be dirty")
        XCTAssertTrue(draft.isDirty,
                      "the draft stays dirty via the staged asset mutation — the retry re-sends it")
    }

    /// The reseed must also cover the replacement path (image upload
    /// failed after metadata applied): the retry re-sends only the
    /// staged replacement bytes.
    func testNoteMetadataAppliedPreservesStagedReplacement() {
        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        let bytes = Data(repeating: 9, count: 32)
        draft.stageReplacement(data: bytes)

        draft.noteMetadataApplied()

        XCTAssertEqual(draft.image, .replacement(bytes),
                       "the staged replacement stays staged for the retry")
        XCTAssertEqual(draft.metadataAfterSave.imageKind, "photo")
        XCTAssertFalse(draft.metadataAfterSave != draft.baseline,
                       "metadata is no longer dirty after the reseed")
    }
}
