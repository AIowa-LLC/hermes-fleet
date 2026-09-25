import XCTest
@testable import FleetCore

/// Build 46 — `AttachmentStagingRules.pathSafeBasename` contract: the
/// returned basename is the wire name hint, so it must ALWAYS fit its byte
/// budget (that cap is the reason the helper exists) and must only ever be
/// cut on a scalar boundary (a split multibyte scalar injects U+FFFD into a
/// name that crosses the wire).
final class AttachmentStagingRulesTests: XCTestCase {

    // MARK: - The byte cap holds for every input

    func testKeepsTheWireByteCapWhenTheExtensionAloneExceedsIt() {
        // The extension alone is longer than the whole budget: the old code
        // clamped the stem to one byte and still returned 302 bytes.
        let longExtension = "report." + String(repeating: "x", count: 300)
        XCTAssertLessThanOrEqual(
            AttachmentStagingRules.pathSafeBasename(longExtension).utf8.count, 255)

        let tinyBudget = AttachmentStagingRules.pathSafeBasename("a.verylongextension", maxBytes: 8)
        XCTAssertLessThanOrEqual(tinyBudget.utf8.count, 8)
        XCTAssertFalse(tinyBudget.isEmpty)
    }

    func testEveryPathStaysWithinTheByteBudgetOnAScalarBoundary() {
        let names = [
            "cat.png",
            "photo." + String(repeating: "y", count: 300),
            String(repeating: "a", count: 400) + ".png",
            String(repeating: "文", count: 120) + ".pdf",
            String(repeating: "é", count: 200) + ".heic",
            "..",
            "",
            "   ",
            "a",
            "a.b",
            ".hidden",
            "résumé.pdf",
        ]
        for name in names {
            for budget in [1, 2, 3, 4, 5, 8, 16, 64, 255] {
                let bounded = AttachmentStagingRules.pathSafeBasename(name, maxBytes: budget)
                let context = "\"\(name)\" @ \(budget)"
                XCTAssertLessThanOrEqual(bounded.utf8.count, budget, context)
                XCTAssertFalse(bounded.isEmpty, context)
                XCTAssertFalse(bounded.contains("\u{FFFD}"), context)
                XCTAssertFalse(bounded.contains("/"), context)
            }
        }
    }

    func testTruncatesOnScalarBoundariesNeverInjectingReplacementCharacters() {
        // "字" is three UTF-8 bytes: a four-byte stem budget cuts the second
        // scalar in half and injects U+FFFD.
        let scalars = AttachmentStagingRules.pathSafeBasename("字字字.png", maxBytes: 8)
        XCTAssertEqual(scalars, "字.png")
        XCTAssertFalse(scalars.contains("\u{FFFD}"))

        let long = AttachmentStagingRules.pathSafeBasename(String(repeating: "文字", count: 120) + ".png")
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        XCTAssertFalse(long.contains("\u{FFFD}"))
        XCTAssertTrue(long.hasSuffix(".png"))
    }

    func testKeepsTheExtensionWhenALongNameMustBeTruncated() {
        let ascii = AttachmentStagingRules.pathSafeBasename(String(repeating: "a", count: 400) + ".png")
        XCTAssertLessThanOrEqual(ascii.utf8.count, 255)
        XCTAssertTrue(ascii.hasSuffix(".png"), "the gateway routes by the extension")

        let accented = AttachmentStagingRules.pathSafeBasename(
            "résumé" + String(repeating: "é", count: 200) + ".pdf")
        XCTAssertLessThanOrEqual(accented.utf8.count, 255)
        XCTAssertTrue(accented.hasSuffix(".pdf"))
        XCTAssertFalse(accented.contains("\u{FFFD}"))
    }

    // MARK: - The traversal contract is unchanged

    func testTraversalSeparatorsAndControlsBecomeUnderscores() {
        XCTAssertEqual(
            AttachmentStagingRules.pathSafeBasename("../private\\notes\u{0000}.md"),
            "private_notes_.md")
        XCTAssertEqual(
            AttachmentStagingRules.pathSafeBasename("/tmp/../../etc/passwd"),
            "tmp_etc_passwd")
    }
}