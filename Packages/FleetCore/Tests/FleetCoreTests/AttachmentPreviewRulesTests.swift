import XCTest
@testable import FleetCore

/// Attachment preview classification: the composer tray decides between a
/// thumbnail, a QuickLook document, and an honest "no preview" from the name
/// alone — before any bytes are read. These are the rules that decision rides
/// on, so they are pinned here.
final class AttachmentPreviewRulesTests: XCTestCase {

    // MARK: - Extension decides first

    func testClassifiesDecodableImagesCaseInsensitively() {
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "cat.png"), .image)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "CAT.PNG"), .image)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "scan.JPEG"), .image)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "shot.webp"), .image)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "frame.tiff"), .image)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "IMG_0001.HEIC"), .image)
    }

    func testClassifiesDocuments() {
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "report.pdf"), .document)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "notes.md"), .document)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "sheet.CSV"), .document)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "contract.docx"), .document)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "deck.pptx"), .document)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "log.txt"), .document)
    }

    func testGatewayImageFormatsTheAppCannotRenderAreUnsupported() {
        // The gateway's vision allowlist accepts these; UIImage does not
        // decode them, so an "image" verdict would render a blank card.
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "mark.svg"), .unsupported)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "favicon.ico"), .unsupported)
    }

    func testUnknownAndBinaryExtensionsAreUnsupported() {
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "bundle.zip"), .unsupported)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "model.bin"), .unsupported)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "noextension"), .unsupported)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: ""), .unsupported)
    }

    // MARK: - MIME is the fallback only when there is no extension

    func testMIMEFallbackClassifiesAnExtensionlessName() {
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "photo", mimeType: "image/png"), .image)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "photo", mimeType: "IMAGE/JPEG"), .image)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "scan", mimeType: "application/pdf"), .document)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "readme", mimeType: "text/markdown"), .document)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "blob", mimeType: "application/octet-stream"), .unsupported)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "blob", mimeType: "   "), .unsupported)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "blob", mimeType: nil), .unsupported)
    }

    func testExtensionWinsOverAContradictingMIME() {
        // A mistaken MIME must not turn an unrenderable file into a preview
        // promise: the extension is what QuickLook will actually open.
        XCTAssertEqual(
            AttachmentPreviewRules.kind(displayName: "archive.zip", mimeType: "image/png"),
            .unsupported)
        XCTAssertEqual(
            AttachmentPreviewRules.kind(displayName: "report.pdf", mimeType: "application/octet-stream"),
            .document)
    }

    // MARK: - Directory components never participate

    func testClassificationUsesOnlyTheBaseName() {
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "dir/sub/cat.png"), .image)
        XCTAssertEqual(AttachmentPreviewRules.kind(displayName: "../../secrets/report.pdf"), .document)
    }

    // MARK: - canPreview + the preview file name

    func testCanPreviewMatchesTheKind() {
        XCTAssertTrue(AttachmentPreviewRules.canPreview(displayName: "cat.jpg"))
        XCTAssertTrue(AttachmentPreviewRules.canPreview(displayName: "report.pdf"))
        XCTAssertFalse(AttachmentPreviewRules.canPreview(displayName: "model.bin"))
    }

    func testPreviewFileNameIsBoundedPathSafeAndKeepsTheExtension() {
        let traversal = AttachmentPreviewRules.previewFileName(displayName: "../../etc/passwd")
        XCTAssertFalse(traversal.contains("/"))
        XCTAssertFalse(traversal.contains(".."))

        let long = AttachmentPreviewRules.previewFileName(
            displayName: String(repeating: "a", count: 400) + ".pdf")
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        XCTAssertTrue(long.hasSuffix(".pdf"), "QuickLook infers the type from the extension")

        XCTAssertEqual(AttachmentPreviewRules.previewFileName(displayName: ""), "attachment")
    }
}
