import XCTest
@testable import FleetCore

/// i7-gapfill R2 — unknown/upstream persisted shapes must fail safely:
/// `face()` classifies free-form values (sigil-N, platonic solids, blobatar
/// variants) without crashing, and `parseBlobShape` keeps its compatibility
/// contract (empty seed follows the bot's name; kind is optional). The
/// renderer-side fallback geometry is proven in the hosted FleetUI tests
/// (BotAvatarShapePath is a SwiftUI Shape); this file proves the DOMAIN
/// layer never rewrites or rejects the persisted value.
final class BotAvatarUnknownShapeSafetyTests: XCTestCase {

    // MARK: - face() never crashes on unknown persisted shapes

    func testUnknownPersistedShapesClassifyWithoutCrashingOrRewriting() {
        // Free-form upstream values observed in the wild (issue #7:
        // "sigil-N, platonic solids, free-form strings are preserved
        // verbatim"). face() must classify (never crash) and the persisted
        // value must survive verbatim inside the classification.
        let unknowns = [
            "platonic-tetra", "sigil-7", "dodecahedron-of-doom",
            "emoji-🔮", "shape with spaces", "UPPER-Case", "", " ", ":", "::",
            "blobatar:", "blobatar::", "blobatar:seed-only",
            "blobatar:seed:kind:extra", "unicode-形",
        ]
        for value in unknowns {
            let face = BotAvatarIdentity.face(hasAvatar: false, shape: value, identityName: "sam")
            switch face {
            case .shape(let resolved):
                if value.isEmpty {
                    // Empty shape falls back to the deterministic default —
                    // the documented classification for "no shape persisted".
                    XCTAssertEqual(
                        resolved, BotAvatarIdentity.defaultShape(forName: "sam"),
                        "empty shape must resolve to the deterministic default")
                } else {
                    XCTAssertEqual(
                        resolved, value,
                        "unknown shape must be preserved verbatim (got \(resolved))")
                }
            case .blob(let seed, _):
                XCTAssertTrue(
                    BotAvatarIdentity.isBlobShape(value),
                    "only the blob family may classify as blob (got \(value))")
                _ = seed // seed semantics asserted separately below
            case .image, .initials:
                XCTFail("no avatar + non-empty identity must never classify as \(face) for \(value)")
            }
        }
    }

    func testEmptyShapeWithEmptyIdentityClassifiesAsInitials() {
        XCTAssertEqual(
            BotAvatarIdentity.face(hasAvatar: false, shape: nil, identityName: ""),
            .initials)
    }

    func testUnknownShapeStillYieldsToAuthoritativeImage() {
        // A gateway-owned asset always wins, even over an unknown shape —
        // the renderer precedence contract (image > shape > default).
        XCTAssertEqual(
            BotAvatarIdentity.face(hasAvatar: true, shape: "platonic-tetra", identityName: "x"),
            .image)
    }

    // MARK: - blobatar parsing compatibility (must remain intact)

    func testBlobatarParsingCompatibilityMatrix() {
        let cases: [(String, String, String?, String)] = [
            // (persisted, expectedSeed, expectedKind, fallbackIdentity)
            ("blobatar", "sam", nil, "sam"),
            ("blobatar:", "sam", nil, "sam"),
            ("blobatar:abc", "abc", nil, "sam"),
            ("blobatar:abc:", "abc", nil, "sam"),
            ("blobatar:abc:cloud", "abc", "cloud", "sam"),
            ("blobatar::cloud", "sam", "cloud", "sam"),
        ]
        for (persisted, seed, kind, fallback) in cases {
            let parsed = BotAvatarIdentity.parseBlobShape(persisted, fallbackSeed: fallback)
            XCTAssertEqual(parsed, .blob(seed: seed, kind: kind), "parse(\(persisted))")
            // The classification path agrees with the parser.
            XCTAssertEqual(
                BotAvatarIdentity.face(hasAvatar: false, shape: persisted, identityName: fallback),
                .blob(seed: seed, kind: kind),
                "face(\(persisted)) must agree with parseBlobShape")
        }
    }

    // MARK: - picker vocabulary integrity (feeds the hosted distinctness test)

    func testPickerShapeVocabularyIsTheAdvertisedSet() {
        XCTAssertEqual(
            BotAvatarIdentity.pickerShapes,
            ["circle", "blob", "squircle", "pill", "triangle", "hexagon", "cloud", "drop"],
            "the advertised picker set is the upstream AVATAR_PICKER_SHAPES order")
        // No duplicates — every advertised option must be one distinct choice.
        XCTAssertEqual(Set(BotAvatarIdentity.pickerShapes).count, BotAvatarIdentity.pickerShapes.count)
    }
}
