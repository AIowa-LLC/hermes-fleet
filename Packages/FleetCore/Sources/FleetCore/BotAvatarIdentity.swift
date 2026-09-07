import Foundation

/// Deterministic backend-authoritative avatar identity.
///
/// Upstream ground truth (hermes-agent @ 08b140d,
/// apps/desktop/src/plugins/hermes-bots/avatar.tsx):
/// - Shape vocabulary: `circle, blob, squircle, pill, triangle, hexagon,
///   cloud, drop` (AVATAR_PICKER_SHAPES); free-form strings are preserved
///   verbatim (sigil-N, platonic solids, `blobatar:<seed>:<kind>`).
/// - `defaultShapeFor(name)`: hash = Σ charCode·31^i mod 7 over the legacy
///   shape set (NO 'blob') — the fallback face when a bot has no shape.
/// - Uploaded images ride `profiles.set_asset` ONLY (never ui_meta);
///   `has_avatar` from profiles.list is the sync flag (D08: same bot
///   recognizable across clients; no iPhone-only avatar authority).
///
/// Fleet renders the deterministic shape family with system geometry and
/// the single accent — no bespoke hues, no local avatar cache authority.
public enum BotAvatarIdentity {

    /// The picker shape set, in upstream order.
    public static let pickerShapes: [String] = [
        "circle", "blob", "squircle", "pill", "triangle", "hexagon", "cloud", "drop",
    ]

    /// Legacy default-face set (no 'blob') — the `defaultShapeFor` domain.
    static let defaultShapes: [String] = [
        "circle", "squircle", "pill", "triangle", "hexagon", "cloud", "drop",
    ]

    /// Deterministic default shape for a name (upstream `defaultShapeFor`:
    /// hash = (hash * 31 + charCode) >>> 0 over the legacy 7-shape set).
    public static func defaultShape(forName name: String) -> String {
        var hash: UInt32 = 0
        for scalar in name.unicodeScalars {
            hash = (hash &* 31 &+ UInt32(truncatingIfNeeded: scalar.value))
        }
        return defaultShapes[Int(hash % UInt32(defaultShapes.count))]
    }

    /// Whether a shape string is the deterministic blobatar family
    /// (`blobatar`, `blobatar:<seed>`, `blobatar:<seed>:<kind>`).
    public static func isBlobShape(_ shape: String) -> Bool {
        shape == "blobatar" || shape.hasPrefix("blobatar:")
    }

    /// Classification for rendering: uploaded image (when has_avatar and
    /// image data is available), named shape, blob family, or the
    /// deterministic default derived from the identity name.
    public enum Face: Hashable, Sendable {
        case image
        case shape(String)
        case blob(seed: String, kind: String?)
        case initials
    }

    /// Resolve the render face for one bot.
    public static func face(
        hasAvatar: Bool,
        shape: String?,
        identityName: String
    ) -> Face {
        if hasAvatar { return .image }
        guard let shape, !shape.isEmpty else {
            return .initials
        }
        if isBlobShape(shape) {
            return parseBlobShape(shape, fallbackSeed: identityName)
        }
        return .shape(shape)
    }

    /// Parse `blobatar[:seed[:kind]]` — an empty/omitted seed follows the
    /// bot's name (upstream parseBlobShape).
    public static func parseBlobShape(_ shape: String, fallbackSeed: String) -> Face {
        let parts = shape.split(separator: ":", omittingEmptySubsequences: false)
        let seed = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : fallbackSeed
        let kind = parts.count > 2 && !parts[2].isEmpty ? String(parts[2]) : nil
        return .blob(seed: seed, kind: kind)
    }
}

/// Avatar appearance edit: shape + color ride ui_meta (`hermes-bots`
/// `shape`/`color`, synced with CAS); an uploaded image rides
/// `profiles.set_asset` (data URL ≤2MB PNG/JPEG/WebP) and NEVER ui_meta.
public struct BotAvatarEdit: Hashable, Sendable {
    public var shape: String?
    public var color: String?

    public init(shape: String? = nil, color: String? = nil) {
        self.shape = shape
        self.color = color
    }
}
