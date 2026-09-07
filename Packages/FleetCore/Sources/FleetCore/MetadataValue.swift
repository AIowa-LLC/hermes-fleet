import Foundation

/// A self-contained JSON-ish value for profile `ui_meta` metadata.
///
/// Bot Mode metadata is backend-authoritative and open-ended: the gateway
/// stores arbitrary JSON under keys like `hermes-bots` and
/// `hermes-bots-groups`, and Fleet must round-trip fields it does not know
/// about without dropping them (checkpoint 5: "retain unknown metadata").
/// FleetCore has no JSON-RPC dependency, so metadata travels through this
/// minimal value enum instead.
public enum MetadataValue: Hashable, Sendable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([MetadataValue])
    case object([String: MetadataValue])

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var objectValue: [String: MetadataValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [MetadataValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Subscript into object values (nil for non-objects / missing keys).
    public subscript(key: String) -> MetadataValue? {
        objectValue?[key]
    }
}
