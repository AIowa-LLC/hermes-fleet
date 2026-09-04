import Foundation

/// R10-T1 — attachment staging domain: photos / PDFs / arbitrary files
/// attached from the conversation composer, staged into the session
/// workspace on the gateway and referenced in the submitted prompt.
///
/// Wire shapes verified against hermes-agent 0.21.0 installed source
/// (`~/.hermes/hermes-agent/tui_gateway/methods_prompt.py` + `server.py`):
/// - `file.attach` (methods_prompt.py:1350-1395): params
///   `{session_id, path?, data_url?, name?}` — `data_url` is
///   `data:<mime>;base64,<b64>`, REQUIRED for remote gateways (the path only
///   exists on the client's disk; `_stage_session_file_attachment`
///   server.py:14506-14556 writes the decoded bytes into the session home's
///   `attachments/` dir, which is bind-mounted into container backends).
///   Result `{attached, name, path, ref_path, ref_text: "@file:...",
///   uploaded}` where `ref_text` is the workspace-relative `@file:` ref the
///   prompt cites (`_attachment_ref_path` server.py:14416-14426 +
///   `_format_ref_value` :14394 — values with whitespace/brackets are
///   backtick-quoted).
/// - `image.attach_bytes` (methods_prompt.py:1163-1222): params
///   `{session_id, content_base64|data, filename?, ext?}` — the value may
///   carry a `data:image/...;base64,` prefix (`_decode_attach_base64`
///   server.py:14298, mime_prefix="image/"); without a filename hint the
///   gateway sniffs PNG/JPEG/GIF/WebP/BMP magic and falls back to `.png`
///   (`_sniff_image_ext` server.py:14322). Result mirrors `image.attach`
///   (`{attached, path, count, remainder, text, bytes, ..._image_meta}` —
///   `_image_meta` server.py:3140 emits name/width/height/token_estimate
///   only when PIL can read the image).
/// - `pdf.attach` (methods_prompt.py:1224-1348): params
///   `{session_id, content_base64|data, filename?}` — the gateway renders
///   each page to a 150 DPI PNG via pdftoppm and queues them as attached
///   images (the vision pipeline accepts images, not PDFs). Result
///   `{attached, filename, pages_attached, pages: [{path, page,
///   ..._image_meta}], count, text}`.
/// - `image.detach` (methods_prompt.py:1397-1412): params
///   `{session_id, path}` → `{detached: bool, count}`.
/// - Server caps: image bytes 25 MB (`_ATTACH_BYTES_MAX_BYTES`
///   server.py:14284), PDFs 50 MB + 25 pages per call
///   (server.py:14285-14286). Error codes: 4015 param missing, 4016
///   not-found / unsupported extension, 4017 invalid base64, 4018 over cap,
///   5027 write failed, 5028 pdf pipeline failure.

/// One successfully staged `file.attach` result — the `@file:` ref is what
/// the submitted prompt appends.
public struct StagedFileAttachment: Equatable, Sendable {
    /// The stored filename (post-sanitization + dedupe on the gateway).
    public let name: String
    /// Absolute gateway-side path.
    public let path: String
    /// Workspace-relative ref path.
    public let refPath: String
    /// The ready-to-cite `@file:...` ref (server-formatted, quoting included).
    public let refText: String
    /// True when the gateway materialized uploaded bytes (the remote case);
    /// false when it reused an in-workspace file as-is.
    public let uploaded: Bool

    public init(name: String, path: String, refPath: String, refText: String, uploaded: Bool) {
        self.name = name
        self.path = path
        self.refPath = refPath
        self.refText = refText
        self.uploaded = uploaded
    }
}

/// One successfully staged `image.attach_bytes` result.
public struct StagedImageAttachment: Equatable, Sendable {
    /// Gateway-side stored path — the `image.detach` handle.
    public let path: String
    /// Stored name from `_image_meta` (nil when PIL could not read it).
    public let name: String?
    public let count: Int
    public let byteCount: Int?
    public let width: Int?
    public let height: Int?
    public let tokenEstimate: Int?

    public init(
        path: String,
        name: String? = nil,
        count: Int,
        byteCount: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        tokenEstimate: Int? = nil
    ) {
        self.path = path
        self.name = name
        self.count = count
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.tokenEstimate = tokenEstimate
    }
}

/// One rendered page of a successfully staged `pdf.attach` result.
public struct StagedPDFPage: Equatable, Sendable {
    public let path: String
    public let pageNumber: Int
    public let name: String?
    public let width: Int?
    public let height: Int?

    public init(path: String, pageNumber: Int, name: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.path = path
        self.pageNumber = pageNumber
        self.name = name
        self.width = width
        self.height = height
    }
}

/// One successfully staged `pdf.attach` result.
public struct StagedPDFAttachment: Equatable, Sendable {
    public let filename: String
    public let pagesAttached: Int
    public let pages: [StagedPDFPage]
    /// Total attached images on the session after this call.
    public let count: Int

    public init(filename: String, pagesAttached: Int, pages: [StagedPDFPage], count: Int) {
        self.filename = filename
        self.pagesAttached = pagesAttached
        self.pages = pages
        self.count = count
    }
}

/// Post-`image.detach` session attachment state.
public struct DetachedImageState: Equatable, Sendable {
    public let detached: Bool
    public let count: Int

    public init(detached: Bool, count: Int) {
        self.detached = detached
        self.count = count
    }
}

/// Typed attachment-staging failures (gateway codes mapped, client-side
/// guards included).
public enum AttachmentStagingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file exceeds the client-side pre-upload cap — never sent.
    case fileTooLarge(name: String, sizeBytes: Int, capBytes: Int)
    /// The extension is not one the gateway's image pipeline accepts
    /// (cli.py `_IMAGE_EXTENSIONS`: png/jpg/jpeg/gif/webp/bmp/tiff/tif/
    /// svg/ico) — fail before upload rather than a 4016 round trip.
    case unsupportedImageFormat(name: String)
    /// Gateway error 4018 / oversized PDF page range 4019.
    case tooLarge(detail: String)
    /// Gateway error 4016 — not found / unsupported extension.
    case notFound(detail: String)
    /// Gateway error 4015 / 4017 / 5027 / 5028 and unmapped codes.
    case rpcFailed(String)
    /// Result envelope did not match the verified wire shape.
    case malformedResponse(detail: String)

    public var description: String {
        switch self {
        case .fileTooLarge(let name, let size, let cap):
            let capMB = cap / (1024 * 1024)
            return "\(name) is too large (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) — the cap is \(capMB) MB"
        case .unsupportedImageFormat(let name):
            return "unsupported image format: \(name)"
        case .tooLarge(let detail):
            return detail
        case .notFound(let detail):
            return detail
        case .rpcFailed(let detail):
            return detail
        case .malformedResponse(let detail):
            return "malformed gateway response (\(detail))"
        }
    }
}

/// R10-T1 seam: attachment staging over a gateway's transport. Lives in
/// FleetCore so FleetUI never imports FleetNetworking (M0 guard); the
/// concrete `GatewayAttachmentClient` is injected at the composition root.
public protocol AttachmentStagingProviding: Sendable {
    /// `file.attach` — stage arbitrary file bytes; returns the `@file:` ref.
    func attachFile(sessionID: String, name: String, dataURL: String) async throws -> StagedFileAttachment
    /// `image.attach_bytes` — stage image bytes for the vision pipeline.
    func attachImageBytes(sessionID: String, filename: String, dataURL: String) async throws -> StagedImageAttachment
    /// `pdf.attach` — stage PDF bytes; the gateway renders pages to images.
    func attachPDF(sessionID: String, filename: String, dataURL: String) async throws -> StagedPDFAttachment
    /// `image.detach` — remove a previously attached image by gateway path.
    func detachImage(sessionID: String, path: String) async throws -> DetachedImageState
}

/// Fail-closed default (no transport): every call throws instead of
/// silently pretending the gateway answered (the `UnsupportedGatewayLearning`
/// discipline).
public struct UnsupportedAttachmentStaging: AttachmentStagingProviding {
    public init() {}

    public func attachFile(sessionID: String, name: String, dataURL: String) async throws -> StagedFileAttachment {
        throw AttachmentStagingError.rpcFailed("gateway not configured")
    }

    public func attachImageBytes(sessionID: String, filename: String, dataURL: String) async throws -> StagedImageAttachment {
        throw AttachmentStagingError.rpcFailed("gateway not configured")
    }

    public func attachPDF(sessionID: String, filename: String, dataURL: String) async throws -> StagedPDFAttachment {
        throw AttachmentStagingError.rpcFailed("gateway not configured")
    }

    public func detachImage(sessionID: String, path: String) async throws -> DetachedImageState {
        throw AttachmentStagingError.rpcFailed("gateway not configured")
    }
}

/// R10-T1 capability marker mirroring `ApprovalsCapable` /
/// `ConversationToolingCapable`: concrete sessions expose their attachment
/// staging surface with ONE cast at build time (`session as?
/// AttachmentStagingCapable`) — deliberately NOT a same-named extension
/// property on `ConversationSessionProviding` (that form recurses through
/// swift_dynamicCast; see the ApprovalsCapable note). The view model keeps an
/// `UnsupportedAttachmentStaging` fail-closed default when the cast fails, so
/// the composer's attach affordances surface an honest error instead of
/// pretending.
public protocol AttachmentStagingCapable: ConversationSessionProviding {
    var attachments: any AttachmentStagingProviding { get }
}

// MARK: - Client-side staging rules (shared by the VM + preview fixtures)

/// R10-T1 client-side staging rules: the pre-upload guards + data-URL
/// builder shared by the composer flow. Pure functions — testable without a
/// transport.
public enum AttachmentStagingRules {

    /// Client-side pre-upload cap (10 MB), below every server cap (25 MB
    /// images / 50 MB PDFs) so an oversized file NEVER makes a wasteful
    /// multi-megabyte base64 round trip just to learn it was rejected — the
    /// honest error fires before any upload.
    public static let clientCapBytes = 10 * 1024 * 1024

    /// Extensions the gateway image pipeline accepts — `cli.py`
    /// `_IMAGE_EXTENSIONS` (3954-3958): png/jpg/jpeg/gif/webp/bmp/tiff/tif/
    /// svg/ico. (svg/ico are local `image.attach` paths; keep the set
    /// aligned with the wire truth.)
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg", "ico",
    ]

    /// MIME for an image extension (default image/png — the gateway's own
    /// sniff fallback, server.py:14322-14340).
    public static func imageMIME(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "tiff", "tif": return "image/tiff"
        case "svg": return "image/svg+xml"
        case "ico": return "image/vnd.microsoft.icon"
        default: return "image/png"
        }
    }

    /// Guard + build: returns the `data:<mime>;base64,<b64>` upload for image
    /// bytes, or the honest pre-upload failure.
    public static func imageDataURL(filename: String, bytes: Data) -> Result<String, AttachmentStagingError> {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext) else {
            return .failure(.unsupportedImageFormat(name: filename))
        }
        guard bytes.count <= clientCapBytes else {
            return .failure(.fileTooLarge(name: filename, sizeBytes: bytes.count, capBytes: clientCapBytes))
        }
        return .success("data:\(imageMIME(forExtension: ext));base64,\(bytes.base64EncodedString())")
    }

    /// Guard + build for PDFs (the gateway pins the decoder regex to
    /// mime_prefix="application/pdf", methods_prompt.py:1263).
    public static func pdfDataURL(filename: String, bytes: Data) -> Result<String, AttachmentStagingError> {
        guard bytes.count <= clientCapBytes else {
            return .failure(.fileTooLarge(name: filename, sizeBytes: bytes.count, capBytes: clientCapBytes))
        }
        return .success("data:application/pdf;base64,\(bytes.base64EncodedString())")
    }

    /// Guard + build for arbitrary files — the mime rides the upload so the
    /// gateway preserves the content type in the staged artifact.
    public static func fileDataURL(filename: String, mime: String, bytes: Data) -> Result<String, AttachmentStagingError> {
        guard bytes.count <= clientCapBytes else {
            return .failure(.fileTooLarge(name: filename, sizeBytes: bytes.count, capBytes: clientCapBytes))
        }
        return .success("data:\(mime);base64,\(bytes.base64EncodedString())")
    }

    /// Sniff an image extension from magic bytes when the picker carries no
    /// filename — mirrors the gateway's `_sniff_image_ext` (server.py:14322-
    /// 14340: WebP RIFF container, then PNG/JPEG/GIF/BMP table, .png
    /// fallback). Returns nil for formats the gateway's allowlist rejects
    /// (e.g. HEIC) so the client fails honestly BEFORE upload instead of a
    /// 4016 round trip.
    public static func sniffedImageExtension(bytes: Data) -> String? {
        let head = bytes.prefix(16)
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8)) { return "gif" }
        if head.starts(with: Array("BM".utf8)) { return "bmp" }
        if head.count >= 12, head.starts(with: Array("RIFF".utf8)),
           head.dropFirst(8).starts(with: Array("WEBP".utf8)) { return "webp" }
        return nil
    }

    /// Append `@file:` refs to a prompt: refs go on their own trailing lines
    /// (never inline mid-sentence) so the agent's `agent.context_references`
    /// parse stays clean. Empty text → refs alone (a valid attach-only send).
    public static func promptAppending(refs: [String], to text: String) -> String {
        guard !refs.isEmpty else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let refBlock = refs.joined(separator: " ")
        return trimmed.isEmpty ? refBlock : trimmed + "\n" + refBlock
    }
}
