import Foundation

/// Unified staged avatar appearance draft (#7).
///
/// ONE value describes the appearance the user will get after Save. Every
/// appearance source the editor exposes — built-in Shape, color, Photos /
/// Files upload, generated portrait, Clear — mutates this draft ONLY;
/// remote writes happen exclusively inside the Save transaction
/// (metadata via `profiles.configure` hermes-bots CAS, asset bytes via
/// `profiles.set_asset`), never at picker-tap time. Cancel discards the
/// draft with zero remote writes.
///
/// Seeding is gateway-authoritative: current `BotModeMetadata` (shape,
/// color, custom, imageKind) plus the roster's `hasAvatar` flag and the
/// currently cached avatar bytes. The draft never invents a local avatar
/// authority — after Save the roster refresh is the reconciliation source.
///
/// W1 seam: a new image source (e.g. a Pet thumbnail PNG) plugs in by
/// calling `stageReplacement(data:)` with its bytes — the save lifecycle,
/// preview, and imageKind semantics are source-agnostic.
public struct BotAvatarAppearanceDraft: Hashable, Sendable, Codable {
    /// Staged image asset state relative to the authoritative remote asset.
    public enum ImageState: Hashable, Sendable, Codable {
        /// No image change in this draft (the remote asset, if any, stays).
        case unchanged
        /// The remote asset must be removed on Save (a shape now masks).
        case remove
        /// New image bytes replace the remote asset on Save.
        case replacement(Data)
    }

    /// Baseline metadata the draft was seeded from (retains unknown keys).
    public private(set) var baseline: BotModeMetadata
    /// Staged shape (nil = deterministic default; persisted as upstream does).
    public var shape: String?
    /// Staged color (#RRGGBB or nil).
    public var color: String?
    /// Staged image state.
    public private(set) var image: ImageState
    /// Explicit-customization metadata semantics (Desktop parity): choosing
    /// any appearance source marks the bot customized.
    public private(set) var custom: Bool
    /// Staged imageKind ("shape" / "photo"; nil when never customized).
    public private(set) var imageKind: String?
    /// Whether the bot had an authoritative image asset when seeded.
    public private(set) var hasRemoteImage: Bool
    /// Bytes currently visible for the preview (staged replacement when
    /// present, else the cached remote bytes, else nil).
    public private(set) var previewImageBytes: Data?

    public init(
        baseline: BotModeMetadata,
        shape: String?,
        color: String?,
        image: ImageState = .unchanged,
        custom: Bool,
        imageKind: String?,
        hasRemoteImage: Bool,
        previewImageBytes: Data? = nil
    ) {
        self.baseline = baseline
        self.shape = shape
        self.color = color
        self.image = image
        self.custom = custom
        self.imageKind = imageKind
        self.hasRemoteImage = hasRemoteImage
        self.previewImageBytes = previewImageBytes
    }

    /// Seed a draft from authoritative roster state. `avatarBytes` are the
    /// currently cached display bytes for the remote asset (optional —
    /// the preview falls back to shape rendering when absent).
    public static func seeded(
        from metadata: BotModeMetadata?,
        hasAvatar: Bool,
        avatarBytes: Data? = nil
    ) -> BotAvatarAppearanceDraft {
        let base = metadata ?? BotModeMetadata()
        return BotAvatarAppearanceDraft(
            baseline: base,
            shape: base.shape,
            color: base.color,
            image: .unchanged,
            custom: base.custom ?? false,
            imageKind: base.imageKind,
            hasRemoteImage: hasAvatar,
            previewImageBytes: hasAvatar ? avatarBytes : nil)
    }

    // MARK: - Staging (draft mutation, zero remote writes)

    /// Choosing a built-in shape: image supersession is STAGED (remote
    /// asset removal happens only on Save), explicit customization is set,
    /// imageKind becomes "shape" (upstream Desktop parity:
    /// onImage(null) + onShape(selected)).
    public mutating func selectShape(_ newShape: String?) {
        shape = (newShape?.isEmpty == false) ? newShape : nil
        custom = true
        imageKind = "shape"
        if hasRemoteImage || isReplacementStaged {
            image = .remove
            previewImageBytes = nil
        }
    }

    /// Choosing a color: same customization semantics as a shape choice.
    public mutating func selectColor(_ newColor: String?) {
        color = (newColor?.isEmpty == false) ? newColor : nil
        custom = true
        if imageKind != "photo" { imageKind = "shape" }
    }

    /// Staging an image replacement (upload / generated portrait / any new
    /// image source such as a Pet thumbnail): the staged image becomes the
    /// preview and final visible appearance; imageKind becomes "photo".
    /// ZERO remote writes — the asset uploads only inside Save.
    public mutating func stageReplacement(data: Data) {
        image = .replacement(data)
        custom = true
        imageKind = "photo"
        previewImageBytes = data
    }

    /// Staging image removal (Clear): falls back to the staged shape.
    public mutating func stageRemoval() {
        image = .remove
        custom = true
        if imageKind == "photo" { imageKind = "shape" }
        previewImageBytes = nil
    }

    private var isReplacementStaged: Bool {
        if case .replacement = image { return true }
        return false
    }

    // MARK: - Derived save payload

    /// Whether the draft requests any remote appearance mutation at all.
    public var isDirty: Bool {
        metadataAfterSave != baseline || image != .unchanged
    }

    /// The metadata that should be persisted for this draft (computed, not
    /// stored, so late shape/color edits stay authoritative). The staged
    /// image and imageKind semantics are folded in per upstream rules:
    /// an active image (remote or staged replacement) keeps imageKind
    /// "photo"; a shape edit that supersedes the image flips it to "shape".
    /// `custom` stays nil until the user explicitly chooses an appearance
    /// (upstream renders the friendly fallback until custom is true).
    public var metadataAfterSave: BotModeMetadata {
        var meta = baseline
        meta.shape = shape
        meta.color = color
        meta.custom = custom ? true : baseline.custom
        switch image {
        case .replacement:
            meta.imageKind = "photo"
        case .remove:
            meta.imageKind = imageKind ?? "shape"
        case .unchanged:
            // Keep imageKind consistent with the resulting visible state:
            // an active remote image masks the shape, so "photo" stays.
            meta.imageKind = hasRemoteImage ? "photo" : imageKind
        }
        return meta
    }

    /// Effective image bytes visible after Save (staged replacement, else
    /// the unchanged remote bytes when an asset will still exist).
    public var effectiveImageBytes: Data? {
        switch image {
        case .replacement(let data): return data
        case .unchanged: return hasRemoteImage ? previewImageBytes : nil
        case .remove: return nil
        }
    }
}
