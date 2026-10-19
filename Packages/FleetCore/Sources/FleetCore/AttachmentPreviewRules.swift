import Foundation

/// Attachment previews — classification rules for files staged from the
/// composer.
///
/// The composer stages photos, PDFs, and arbitrary files on the gateway
/// (`AttachmentStagingProviding`, R10-T1) before the next `prompt.submit`.
/// The tray then rendered a text chip only, so a picked photo was never shown
/// and an attached document could not be read back in the app.
///
/// Classification here is a PURE function of the staged file's own name and
/// MIME: no bytes are read, no decode is attempted, no network is touched.
/// That keeps the tray's decision ("thumbnail / document / no preview")
/// deterministic, keeps the rules testable on the host without UIKit, and
/// keeps the honest answer available for formats the app cannot render.
public enum AttachmentPreviewKind: String, Sendable, Equatable {
    /// iOS can decode this inline (ImageIO), so a thumbnail is worth building
    /// and a full-size preview is truthful.
    case image
    /// QuickLook can present this from a local file URL.
    case document
    /// Staged and citable, but there is no honest in-app preview (SVG/ICO
    /// among the gateway's vision formats, archives, binaries). The chip says
    /// so instead of rendering an empty card.
    case unsupported
}

/// Pure preview-classification rules shared by the composer chip and the
/// preview sheet.
public enum AttachmentPreviewRules {

    /// Image extensions iOS can decode through ImageIO.
    ///
    /// A deliberate SUBSET of `AttachmentStagingRules.imageExtensions`: the
    /// gateway's vision pipeline also accepts SVG and ICO, but `UIImage`
    /// cannot render either, so claiming an image preview for them would be a
    /// blank card. Heic/heif are included because the composer converts them
    /// to JPEG before staging — a name that still carries the picked
    /// extension must not lose its preview.
    public static let decodableImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif",
    ]

    /// Document types QuickLook presents from a file URL. The plain-text
    /// family is included on purpose: QuickLook renders those as text rather
    /// than an empty page, which is the honest preview for them.
    public static let documentExtensions: Set<String> = [
        "pdf", "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml",
        "yaml", "yml", "log", "rtf", "rtfd", "html", "htm", "plist", "epub",
        "doc", "docx", "pages", "ppt", "pptx", "key", "xls", "xlsx", "numbers",
    ]

    /// Classify a staged attachment.
    ///
    /// The extension decides when there is one — it is what the picker
    /// preserves and what the gateway routes on. MIME is consulted only for a
    /// name with no extension at all (a picker can hand over a bare
    /// `photo`), and the answer stays `unsupported` when neither source
    /// identifies a renderable type.
    public static func kind(displayName: String, mimeType: String? = nil) -> AttachmentPreviewKind {
        let ext = (displayName as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            if decodableImageExtensions.contains(ext) { return .image }
            if documentExtensions.contains(ext) { return .document }
            return .unsupported
        }
        guard let mime = mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !mime.isEmpty
        else { return .unsupported }
        if mime.hasPrefix("image/") { return .image }
        if mime == "application/pdf" || mime.hasPrefix("text/") { return .document }
        return .unsupported
    }

    /// True when the app has a preview for this attachment.
    public static func canPreview(displayName: String, mimeType: String? = nil) -> Bool {
        kind(displayName: displayName, mimeType: mimeType) != .unsupported
    }

    /// The file name a staged preview copy is written under: a bounded,
    /// path-safe basename (the extension must survive — QuickLook infers the
    /// type from it) and never a directory component.
    public static func previewFileName(displayName: String) -> String {
        AttachmentStagingRules.pathSafeBasename(displayName)
    }
}
