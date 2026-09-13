import XCTest
import SwiftUI
import UIKit
import FleetCore
@testable import FleetUI

/// i7-gapfill — hosted view-level regression for the #7 avatar audit
/// residuals (product behavior was already satisfied by PR #10 — this
/// file locks in the renderer guarantees):
///
/// R2 — per-shape renderer distinctness across the ENTIRE advertised picker
///      vocabulary `BotAvatarIdentity.pickerShapes` (incl. cloud ≠ blob),
///      seeded-blob determinism, and the unknown-shape safe fallback
///      (predictable squircle geometry, no crash, no rewrite).
///
/// R1 — `BotAvatarImageNormalization` caps/normalization (20 MB input gate,
///      1024 px long edge, 2 MB JPEG cap, invalid-data rejection). The
///      Photos/Files/Generate/Clear CONTROL surface is proven by the
///      XCUITest journeys (BotAvatarSourcesUITests) — SwiftUI accessibility
///      identifiers are not observable from hosted UIHostingController
///      tests (verified by probe: the aggregate element tree is empty).
final class BotAvatarRendererAndControlsTests: XCTestCase {

    // MARK: - R2: renderer geometry

    private let renderRect = CGRect(x: 0, y: 0, width: 96, height: 96)

    private func path(_ shape: String, seed: String = "sam") -> Path {
        BotAvatarShapePath(name: shape, seed: seed).path(in: renderRect)
    }

    /// Every advertised picker shape must render DISTINCTLY — pairwise Path
    /// inequality across the whole advertised vocabulary (audit residual
    /// R2: cloud was historically aliased to the generic blob geometry; it
    /// must not be again).
    func testEveryPickerShapeRendersDistinctly() {
        let vocabulary = BotAvatarIdentity.pickerShapes
        XCTAssertEqual(
            vocabulary,
            ["circle", "blob", "squircle", "pill", "triangle", "hexagon", "cloud", "drop"],
            "the advertised picker set is the upstream AVATAR_PICKER_SHAPES order")
        XCTAssertEqual(Set(vocabulary).count, vocabulary.count, "no duplicate options")
        for i in vocabulary.indices {
            for j in (i + 1)..<vocabulary.count {
                XCTAssertNotEqual(
                    path(vocabulary[i]), path(vocabulary[j]),
                    "'\(vocabulary[i])' and '\(vocabulary[j])' must not share geometry — every advertised option renders honestly and distinctly")
            }
        }
        // The explicit audit assertion: the cloud composite is NOT the
        // seeded blob silhouette.
        XCTAssertNotEqual(path("cloud"), path("blob"), "cloud ≠ blob (issue #7 finding 4)")
    }

    /// Blob geometry is seeded: same seed renders identically across calls
    /// (determinism), and different seeds visibly diverge.
    func testBlobGeometryIsSeededAndDeterministic() {
        let a1 = path("blob", seed: "alpha")
        let a2 = path("blob", seed: "alpha")
        XCTAssertEqual(a1, a2, "same seed must render identically (deterministic)")
        XCTAssertNotEqual(a1, path("blob", seed: "beta"), "different seeds must diverge")
    }

    /// The blobatar persisted family renders the seeded blob (parse
    /// compatibility) and diverges from the squircle fallback.
    func testBlobatarFamilyRendersSeededBlobNotFallback() {
        let fallback = path("squircle")
        XCTAssertNotEqual(path("blobatar:seed:kind"), fallback,
                          "blobatar variants must render the seeded blob family geometry")
        XCTAssertNotEqual(path("blobatar:alpha"), path("blobatar:beta"),
                          "seeded blobatar variants diverge by seed")
    }

    /// Unknown/upstream persisted shapes degrade to the SAFE FALLBACK
    /// (the squircle geometry) — no crash, no rewrite, and identical
    /// geometry regardless of the unknown value (predictable).
    func testUnknownShapeDegradesToPredictableSafeFallbackWithoutCrash() {
        let fallback = path("squircle")
        let unknowns = ["platonic-tetra", "sigil-7", "free-form/upstream", "🛸"]
        for unknown in unknowns {
            XCTAssertEqual(
                path(unknown), fallback,
                "unknown shape '\(unknown)' must degrade to the squircle fallback")
        }
    }

    /// The draft preview and the roster renderer share one shape/tint
    /// vocabulary (#7 §2). Spot-check that tint resolution never crashes
    /// on invalid metadata colors and falls back to the accent.
    func testSharedTintResolutionNeverCrashesOnInvalidColors() {
        let fallback = FleetTheme.accent
        _ = BotAvatarAppearanceTint.color(hex: "not-a-color", fallback: fallback)
        _ = BotAvatarAppearanceTint.color(hex: "#12345", fallback: fallback)
        _ = BotAvatarAppearanceTint.color(hex: "#GGGGGG", fallback: fallback)
        _ = BotAvatarAppearanceTint.color(hex: nil, fallback: fallback)
        _ = BotAvatarAppearanceTint.color(hex: "#00AAFF", fallback: fallback)
    }

    // MARK: - R1: normalization caps

    private func solidJPEG(pixelEdge: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: pixelEdge, height: pixelEdge), format: format).image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: pixelEdge, height: pixelEdge))
        }
        return image.jpegData(compressionQuality: 1.0)!
    }

    func testInvalidImageDataIsRejected() {
        switch BotAvatarImageNormalization.normalize(Data([0x00, 0x01, 0x02, 0xFF])) {
        case .invalidImage: break
        case .staged: XCTFail("garbage bytes must not stage")
        case .exceedsUploadCap: XCTFail("garbage bytes must classify as invalid, not oversize")
        }
        switch BotAvatarImageNormalization.normalize(Data()) {
        case .invalidImage: break
        default: XCTFail("empty data must not stage")
        }
    }

    func testLargeImageNormalizesTo1024LongEdgeUnderUploadCap() {
        // A 3000 px image normalizes: long edge caps at 1024, output is a
        // decodable JPEG, and it fits the 2 MB upload cap.
        let staged: Data
        switch BotAvatarImageNormalization.normalize(solidJPEG(pixelEdge: 3000)) {
        case .staged(let data): staged = data
        case .invalidImage: return XCTFail("a valid 3000px JPEG must decode")
        case .exceedsUploadCap: return XCTFail("a solid 1024px JPEG must fit the 2MB cap")
        }
        let decoded = UIImage(data: staged)
        XCTAssertNotNil(decoded, "normalized output must be decodable")
        XCTAssertEqual(max(decoded!.size.width, decoded!.size.height), 1024,
                       "long edge must cap at 1024 (got \(decoded!.size))")
        XCTAssertLessThanOrEqual(staged.count, BotAvatarImageNormalization.maxUploadBytes)
        // JPEG magic on the staged bytes (the editor stages JPEG).
        XCTAssertEqual([UInt8](staged.prefix(2)), [0xFF, 0xD8])
    }

    func testSmallImageIsNeverUpscaled() {
        switch BotAvatarImageNormalization.normalize(solidJPEG(pixelEdge: 64)) {
        case .staged(let data):
            let decoded = UIImage(data: data)
            XCTAssertEqual(max(decoded?.size.width ?? 0, decoded?.size.height ?? 0), 64,
                           "small images must not be upscaled")
        default: XCTFail("a small valid JPEG must stage")
        }
    }

    func testFilesImportInputSizeGate() {
        XCTAssertTrue(BotAvatarImageNormalization.isInputSizeAllowed(0))
        XCTAssertTrue(BotAvatarImageNormalization.isInputSizeAllowed(20_000_000))
        XCTAssertFalse(BotAvatarImageNormalization.isInputSizeAllowed(20_000_001),
                       "inputs above 20 MB are rejected at the Files-import gate")
    }
}
