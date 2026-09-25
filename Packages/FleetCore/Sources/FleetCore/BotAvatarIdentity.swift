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
        for scalar in name.utf16 {
            hash = (hash &* 31 &+ UInt32(truncatingIfNeeded: scalar))
        }
        return defaultShapes[Int(hash % UInt32(defaultShapes.count))]
    }

    // MARK: - Identity-derived fallback color

    /// Curated, accessible avatar identity palette. These are BOT IDENTITY
    /// colors, not interface chrome: they are deliberately independent of
    /// `FleetTheme` and of any user highlight choice, so changing the theme
    /// can never recolor a Bot that has no explicit color metadata.
    ///
    /// Curated bands (pinned by `BotAvatarIdentityColorTests`): every entry
    /// keeps the renderer's near-black eye ink at ≥ 3:1, stays visible on
    /// both the dark and light elevated avatar surfaces, and lands in the
    /// 0.18–0.60 relative-luminance band so the face reads in either
    /// appearance without a per-color foreground override.
    public static let fallbackColors: [UInt32] = [
        0x0A84FF, 0x40C8E0, 0x30B561, 0xFF9F0A,
        0xFF6482, 0xBF7AF6, 0xFF453A, 0x6E7BFF,
    ]

    /// FNV-1a 32 over UTF-8 — deterministic across processes, launches,
    /// devices, and OS versions. Never Swift's `Hasher` (per-process random
    /// seed), which would recolor the same Bot on every relaunch.
    public static func stableHash(_ identity: String) -> UInt32 {
        var hash: UInt32 = 0x811C9DC5
        for byte in identity.utf8 {
            hash = (hash ^ UInt32(byte)) &* 0x01000193
        }
        return hash
    }

    /// Stable fallback avatar color for an identity string. The identity is
    /// the CANONICAL route id (`gateway#slug`), never the display name — a
    /// rename must not recolor a Bot. The value is derived, not persisted:
    /// no new storage exists for colors that can be computed deterministically.
    public static func fallbackColorHex(identity: String) -> UInt32 {
        let key = identity.isEmpty ? "fleet" : identity
        return fallbackColors[Int(stableHash(key) % UInt32(fallbackColors.count))]
    }

    /// Canonical-route convenience (preferred entry point when a `Route` is
    /// available): same gateway, same slug → same color, forever; same slug
    /// on a different gateway is a distinct Bot and derives independently.
    public static func fallbackColorHex(route: Route) -> UInt32 {
        fallbackColorHex(identity: route.id)
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
            return identityName.isEmpty ? .initials : .shape(defaultShape(forName: identityName))
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
