import Foundation

/// Per-bot Bot Mode metadata decoded from the profile's `ui_meta` under key
/// `hermes-bots`, plus the CAS revision bookkeeping the gateway maintains.
///
/// Ground truth: apps/desktop/src/plugins/hermes-bots/types.ts:54-78 and
/// data.ts:327-360 (image rides `profiles.set_asset`, never ui_meta);
/// tui_gateway/methods_profiles.py:225-235 (`ui_meta_revisions` always
/// present in profiles.list, `{}` for new profiles).
///
/// Decode is tolerant: unknown keys are RETAINED (checkpoint 5: "retain
/// unknown metadata") so Fleet never drops fields another client wrote.
/// An entirely absent `hermes-bots` key decodes as `nil` metadata — an
/// externally created profile with no Bot Mode state is valid.
public struct BotModeMetadata: Hashable, Sendable, Codable {
    public var title: String?
    public var descriptionText: String?
    public var hidden: Bool?
    public var pinned: Bool?
    public var sectionID: String?
    public var color: String?
    public var shape: String?
    public var custom: Bool?
    public var imageKind: String?
    /// Group (room) membership names, as maintained by Desktop.
    public var groups: [String]?
    /// Legacy single-group field (superseded by `groups`).
    public var legacyGroup: String?
    public var created: Double?
    /// Every unknown key present in the wire object, verbatim, so writes
    /// round-trip fields this client does not understand.
    public var unknownKeys: [String: MetadataValue]

    public init(
        title: String? = nil,
        descriptionText: String? = nil,
        hidden: Bool? = nil,
        pinned: Bool? = nil,
        sectionID: String? = nil,
        color: String? = nil,
        shape: String? = nil,
        custom: Bool? = nil,
        imageKind: String? = nil,
        groups: [String]? = nil,
        legacyGroup: String? = nil,
        created: Double? = nil,
        unknownKeys: [String: MetadataValue] = [:]
    ) {
        self.title = title
        self.descriptionText = descriptionText
        self.hidden = hidden
        self.pinned = pinned
        self.sectionID = sectionID
        self.color = color
        self.shape = shape
        self.custom = custom
        self.imageKind = imageKind
        self.groups = groups
        self.legacyGroup = legacyGroup
        self.created = created
        self.unknownKeys = unknownKeys
    }

    /// Decode from the wire `ui_meta["hermes-bots"]` object value. An absent
    /// key, a non-object, or an EMPTY object all decode as nil — "no Bot Mode
    /// state" — matching Desktop's absent-metadata handling.
    public init?(metadataValue: MetadataValue?) {
        guard let object = metadataValue?.objectValue, !object.isEmpty else { return nil }
        self.init(object: object)
    }

    /// Decode from an object mapping, retaining unknown keys.
    public init(object: [String: MetadataValue]) {
        self.init(
            title: object["title"]?.stringValue,
            descriptionText: object["description"]?.stringValue,
            hidden: object["hidden"]?.boolValue,
            pinned: object["pinned"]?.boolValue,
            sectionID: object["sectionId"]?.stringValue,
            color: object["color"]?.stringValue,
            shape: object["shape"]?.stringValue,
            custom: object["custom"]?.boolValue,
            imageKind: object["imageKind"]?.stringValue,
            groups: object["groups"]?.arrayValue?.compactMap(\.stringValue),
            legacyGroup: object["group"]?.stringValue,
            created: object["created"]?.numberValue
        )
        var unknown: [String: MetadataValue] = [:]
        for (key, value) in object where !Self.knownKeys.contains(key) {
            unknown[key] = value
        }
        self.unknownKeys = unknown
    }

    static let knownKeys: Set<String> = [
        "title", "description", "hidden", "pinned", "sectionId",
        "color", "shape", "custom", "imageKind", "groups", "group", "created",
    ]

    /// Encode back to a wire object including retained unknown keys.
    public func toWire() -> [String: MetadataValue] {
        var out: [String: MetadataValue] = unknownKeys
        out["title"] = title.map { .string($0) }
        out["description"] = descriptionText.map { .string($0) }
        out["hidden"] = hidden.map { .bool($0) }
        out["pinned"] = pinned.map { .bool($0) }
        out["sectionId"] = sectionID.map { .string($0) }
        out["color"] = color.map { .string($0) }
        out["shape"] = shape.map { .string($0) }
        out["custom"] = custom.map { .bool($0) }
        out["imageKind"] = imageKind.map { .string($0) }
        out["groups"] = groups.map { .array($0.map { .string($0) }) }
        out["group"] = legacyGroup.map { .string($0) }
        out["created"] = created.map { .number($0) }
        return out
    }
}

/// Per-profile ui_meta revision bookkeeping used for CAS writes.
///
/// `profiles.configure` with `ui_meta_expected_revisions` rejects the WHOLE
/// write on any per-key mismatch, returning current revisions and a
/// `ui_meta_conflicts` map (methods_profiles.py:436-479). Fleet never
/// blind-writes when CAS is supported (checkpoint 5).
public struct MetadataRevisions: Hashable, Sendable, Codable {
    /// Current revision per ui_meta key, as reported by the gateway.
    public var revisions: [String: Int]

    public init(revisions: [String: Int] = [:]) {
        self.revisions = revisions
    }

    public subscript(key: String) -> Int? { revisions[key] }

    /// Whether the gateway advertises revisions for the given key — the
    /// CAS-support detection rule (Desktop group-chat.ts:844 keys off the
    /// presence of `ui_meta_revisions` on the row).
    public func supportsCAS(key: String) -> Bool {
        revisions[key] != nil
    }
}
