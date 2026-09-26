import Foundation

/// Card C — secure artifact transport: the provenance-bound handle for a
/// gateway-hosted artifact (generated image, screenshot, cache media) plus the
/// retrieval seam that pulls its REAL bytes through the gateway's
/// authenticated media API.
///
/// Wire ground truth (hermes-agent `hermes_cli/web_routers/files.py`, verified
/// live against the dev dashboard):
/// - `GET /api/media?path=<gateway-local path>` → `{"data_url":
///   "data:image/<mime>;base64,<b64>"}` (`get_media`, files.py:243-264). The
///   route is auth-gated by the dashboard session middleware (401 without a
///   credential — verified), confined to the resolved media roots
///   (`_media_serve_roots`, files.py:229-240: `HERMES_HOME/images`,
///   `HERMES_HOME/screenshots`, `HERMES_HOME/cache` — symlink-safe
///   `Path.resolve()`), extension-allowlisted to the image table
///   (`_MEDIA_CONTENT_TYPES`, files.py:44-47 — 415 otherwise), and capped at
///   `_MEDIA_MAX_BYTES` = 25 MB (files.py:48 — 413 above).
/// - A path outside the roots is 403, a path whose cache entry has aged out
///   is 404 `File not found` (cache retention is host-side; the client must
///   surface that honestly rather than retry forever).
/// - The host path NEVER becomes a public URL: it rides ONLY as a
///   percent-encoded query parameter of the authenticated `/api/media` call,
///   and it is never rendered in UI copy or logs (`description` is redacted;
///   the display label is the basename).

// MARK: - Reference

/// One artifact hosted by one gateway, bound to the conversation/profile it
/// originated from.
///
/// `path` is the GATEWAY-LOCAL filesystem path (tool results / image-gen cache
/// paths are absolute gateway paths). It is transport material, not display
/// material: render `displayName`, never the path. `Codable` so an artifact
/// reference can be persisted with the message that cites it (the reference is
/// provenance, not a credential — the bytes still require the gateway's own
/// authenticated retrieval).
public struct ArtifactReference: Sendable, Equatable, Hashable, Codable {
    /// The gateway that hosts the bytes. Retrieval is refused unless the
    /// client is bound to this same gateway.
    public let gatewayID: GatewayID
    /// The originating conversation on that gateway (nil when the artifact did
    /// not come from a conversation — e.g. a workspace screenshot).
    public let sessionID: String?
    /// The gateway profile scope the artifact belongs to (nil = the gateway's
    /// default profile). Provenance/display metadata: `/api/media` serves the
    /// gateway's own home, so the AUTHORITY is always the gateway credential.
    public let profile: String?
    /// Gateway-local filesystem path. Never rendered, never logged, never a
    /// URL — it is sent only as the `path` query item of this gateway's
    /// authenticated `/api/media` request.
    public let path: String
    /// Basename for display.
    public let name: String
    /// Declared MIME when known (nil = derived from the extension). A response
    /// whose type contradicts this declaration is rejected.
    public let mimeType: String?
    /// Size on the gateway when the origin reported it — the pre-flight
    /// oversize guard input (nil = unknown; the transfer cap still applies).
    public let byteCount: Int?

    public init(
        gatewayID: GatewayID,
        sessionID: String? = nil,
        profile: String? = nil,
        path: String,
        name: String? = nil,
        mimeType: String? = nil,
        byteCount: Int? = nil
    ) {
        self.gatewayID = gatewayID
        self.sessionID = sessionID
        self.profile = profile
        self.path = path
        self.name = name ?? ArtifactTransportRules.defaultName(forPath: path)
        self.mimeType = mimeType
        self.byteCount = byteCount
    }

    /// Display label — the basename only. The host path must never render as
    /// UI copy (AGENTS.md working rule 3; spec §29).
    public var displayName: String { name }

    /// The extension-derived MIME the reference implies (falls back to the
    /// declared value).
    public var resolvedMIMEType: String {
        mimeType ?? ArtifactTransportRules.mimeType(forExtension: (path as NSString).pathExtension)
    }

    /// Redacted printouts: gateway + name + session, never the host path.
    public var description: String {
        var parts = ["gateway: \(gatewayID.rawValue)", "name: \(name)"]
        if let sessionID { parts.append("session: \(sessionID)") }
        if let profile { parts.append("profile: \(profile)") }
        return "ArtifactReference(\(parts.joined(separator: ", ")))"
    }

    public var debugDescription: String { description }
}

// MARK: - Retrieved payload

/// Real artifact bytes, decoded from the gateway's base64 envelope, with the
/// reference they were retrieved for (provenance travels WITH the bytes so
/// callers can attribute/dedupe on replay).
public struct RetrievedArtifact: Sendable, Equatable {
    public let reference: ArtifactReference
    public let data: Data
    /// The MIME the gateway declared for the payload.
    public let mimeType: String

    public init(reference: ArtifactReference, data: Data, mimeType: String) {
        self.reference = reference
        self.data = data
        self.mimeType = mimeType
    }

    public var byteCount: Int { data.count }
}

// MARK: - Transfer limits

/// Client-side transfer policy. Defaults mirror the gateway's own bounds with
/// headroom for the base64 envelope; tests inject small limits to exercise the
/// caps without multi-megabyte fixtures.
public struct ArtifactTransferLimits: Sendable, Equatable {
    /// Decoded artifact cap (server `_MEDIA_MAX_BYTES` = 25 MB).
    public var maxArtifactBytes: Int
    /// Raw response-body cap: base64 inflates by 4/3 and the JSON envelope adds
    /// overhead, so 36 MB bounds the 25 MB worst case.
    public var maxEncodedResponseBytes: Int
    /// Whole-transfer timeout (a media body is not a control-plane document;
    /// the F1 8 s bound does not apply).
    public var transferTimeoutSeconds: TimeInterval

    public init(
        maxArtifactBytes: Int = 25 * 1024 * 1024,
        maxEncodedResponseBytes: Int = 36 * 1024 * 1024,
        transferTimeoutSeconds: TimeInterval = 30
    ) {
        self.maxArtifactBytes = maxArtifactBytes
        self.maxEncodedResponseBytes = maxEncodedResponseBytes
        self.transferTimeoutSeconds = transferTimeoutSeconds
    }

    public static let standard = ArtifactTransferLimits()
}

// MARK: - Errors

/// Typed artifact-transport failures. Every case carries only classification
/// copy — never the host path, never a credential.
public enum ArtifactTransportError: Error, Equatable, Sendable {
    /// The reference belongs to a different gateway than this client. Fail
    /// closed BEFORE any request: one gateway's path must never be presented
    /// to another gateway's credential.
    case gatewayMismatch(expected: GatewayID, actual: GatewayID)
    /// Client-side guard failure (traversal / relative / URL-form / unknown
    /// extension) — the request was never sent.
    case invalidReference(detail: String)
    /// No gateway transport configured (fail-closed default).
    case notConfigured
    /// HTTP 401 — the gateway requires a credential the client could not
    /// supply (missing/expired session token or cookie).
    case authenticationRequired(detail: String)
    /// HTTP 403 — the gateway refused the path (outside the media roots, or a
    /// sensitive location). An artifact reference should never hit this; when
    /// it does, the reference is stale or was never valid.
    case notPermitted(detail: String)
    /// HTTP 415, or a response type outside the image allowlist.
    case unsupportedType(detail: String)
    /// HTTP 413, the known byte count, or the decoded/encoded transfer caps.
    case tooLarge(detail: String)
    /// HTTP 404 — the gateway no longer serves this path. Cache retention is
    /// host-side: an evicted generation cache entry lands here, and the UI
    /// must say so instead of pretending the artifact still exists.
    case expired(detail: String)
    /// The envelope/type contract was violated (missing `data_url`, invalid
    /// base64, declared type ≠ payload type).
    case malformedResponse(detail: String)
    /// Network-level failure that is not a timeout (connection refused,
    /// TLS/pin rejection, protocol error).
    case transferFailed(detail: String)
    /// The transfer exceeded the client timeout.
    case timedOut(detail: String)

    public var description: String {
        switch self {
        case .gatewayMismatch(let expected, let actual):
            return "artifact belongs to gateway \(actual.rawValue), not \(expected.rawValue)"
        case .invalidReference(let detail):
            return "invalid artifact reference: \(detail)"
        case .notConfigured:
            return "gateway not configured"
        case .authenticationRequired(let detail):
            return "gateway authentication required: \(detail)"
        case .notPermitted(let detail):
            return "gateway refused the artifact: \(detail)"
        case .unsupportedType(let detail):
            return "unsupported artifact type: \(detail)"
        case .tooLarge(let detail):
            return "artifact too large: \(detail)"
        case .expired(let detail):
            return "artifact no longer available on the gateway: \(detail)"
        case .malformedResponse(let detail):
            return "malformed gateway media response (\(detail))"
        case .transferFailed(let detail):
            return "artifact transfer failed: \(detail)"
        case .timedOut(let detail):
            return "artifact transfer timed out: \(detail)"
        }
    }

    /// True for the "the artifact existed but the gateway no longer serves it"
    /// class — the honest expiration signal callers must handle (not retry).
    public var isExpiration: Bool {
        if case .expired = self { return true }
        return false
    }
}

extension ArtifactTransportError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - Seam

/// Retrieval seam: FleetUI depends on this (FleetCore), the concrete
/// `GatewayArtifactClient` is injected at the composition root — the module
/// boundary guard keeps FleetUI free of FleetNetworking.
public protocol ArtifactRetrieving: Sendable {
    /// The gateway this retriever is bound to; references for any other
    /// gateway are refused.
    var gatewayID: GatewayID { get }
    /// Retrieve the REAL bytes for `reference` through the gateway's
    /// authenticated media API. Never returns a placeholder.
    func retrieve(_ reference: ArtifactReference) async throws -> RetrievedArtifact
}

/// Fail-closed default (no transport): every call throws instead of silently
/// pretending an artifact exists (`UnsupportedGatewayLearning` discipline).
public struct UnsupportedArtifactRetrieval: ArtifactRetrieving {
    public let gatewayID: GatewayID

    public init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
    }

    public func retrieve(_ reference: ArtifactReference) async throws -> RetrievedArtifact {
        throw ArtifactTransportError.notConfigured
    }
}

// MARK: - Pure rules (client-side guards)

/// Client-side guard rules for artifact transport. Pure functions so the
/// guards are testable without a transport, and so the SAME rules can drive
/// composer/attachment validation.
public enum ArtifactTransportRules {

    /// Extensions `GET /api/media` serves — `_MEDIA_CONTENT_TYPES`
    /// (files.py:44-47), the exact server allowlist. An unknown extension
    /// fails client-side instead of a 415 round trip.
    public static let allowedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico",
    ]

    /// The MIME the server would declare for an extension
    /// (`_MEDIA_CONTENT_TYPES` values; `.ico` is `image/x-icon` there).
    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }

    /// Normalize a MIME for comparison (`image/jpg` is a common alias of
    /// `image/jpeg`; case is insignificant).
    public static func normalizedMIME(_ mime: String) -> String {
        let lowered = mime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered == "image/jpg" ? "image/jpeg" : lowered
    }

    /// MIME types a decoded payload may declare.
    public static let allowedMIMETypes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml",
        "image/bmp", "image/x-icon", "image/vnd.microsoft.icon",
    ]

    /// Maximum accepted reference path length (a gateway path is far shorter;
    /// an unbounded string is a malformed reference, not a path).
    public static let maxPathLength = 1024

    /// The basename for a path, bounded and cleaned for display.
    public static func defaultName(forPath path: String) -> String {
        let basename = (path as NSString).lastPathComponent
        let cleaned = basename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != "/", cleaned != ".", cleaned != ".." else {
            return "artifact"
        }
        return String(cleaned.prefix(120))
    }

    /// Validate a reference path BEFORE any request. Fail-closed: anything the
    /// gateway would resolve outside its media roots — or that cannot be
    /// root-confined at all — is refused locally.
    ///
    /// Rules:
    /// - non-empty, bounded length, no control characters (NUL truncation);
    /// - not a URL (`file:`/`scheme://`) — a host path is not a public URL and
    ///   the transport only ever emits it as an authenticated query item;
    /// - absolute or home-relative (`/…`, `~/…`): a relative path resolves
    ///   against the gateway process CWD, which can never be root-confined
    ///   deterministically, so it is refused;
    /// - no `..` traversal component (symlink-free path arithmetic is the
    ///   server's job, but the client never even asks);
    /// - extension in the server's image allowlist.
    public static func validatedPath(_ raw: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw ArtifactTransportError.invalidReference(detail: "empty path")
        }
        guard path.count <= maxPathLength else {
            throw ArtifactTransportError.invalidReference(detail: "path longer than \(maxPathLength) characters")
        }
        for scalar in path.unicodeScalars where CharacterSet.controlCharacters.contains(scalar) {
            throw ArtifactTransportError.invalidReference(detail: "path contains control characters")
        }
        let lowered = path.lowercased()
        guard !lowered.hasPrefix("file:"), !path.contains("://") else {
            throw ArtifactTransportError.invalidReference(detail: "path is a URL, not a gateway filesystem path")
        }
        guard path.hasPrefix("/") || path.hasPrefix("~") else {
            throw ArtifactTransportError.invalidReference(detail: "path must be absolute or home-relative")
        }
        guard !path.hasSuffix("/") else {
            throw ArtifactTransportError.invalidReference(detail: "path names a directory, not a file")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else {
            throw ArtifactTransportError.invalidReference(detail: "path contains a traversal component")
        }
        guard !components.contains(".") else {
            throw ArtifactTransportError.invalidReference(detail: "path contains a relative component")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            throw ArtifactTransportError.invalidReference(detail: "extension not in the gateway image allowlist")
        }
        return path
    }

    /// The extension the payload's magic bytes imply, when they imply one.
    /// SVG/ICO carry no magic — nil means "not contradicted".
    public static func sniffedExtension(for bytes: Data) -> String? {
        AttachmentStagingRules.sniffedImageExtension(bytes: bytes)
    }

    /// True when the decoded payload's magic bytes agree with the declared
    /// MIME (a mislabeled payload — e.g. HTML served as image/png — is a type
    /// guard failure, not a renderable artifact).
    public static func payloadMatches(declaredMIME: String, bytes: Data) -> Bool {
        guard let sniffed = sniffedExtension(for: bytes) else { return true }
        switch normalizedMIME(declaredMIME) {
        case "image/png": return sniffed == "png"
        case "image/jpeg": return sniffed == "jpg"
        case "image/gif": return sniffed == "gif"
        case "image/webp": return sniffed == "webp"
        case "image/bmp": return sniffed == "bmp"
        default: return true
        }
    }
}
