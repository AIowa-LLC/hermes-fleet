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

    /// The receiver as an `Int`, or `nil` when it is not a JSON number or the
    /// number is not representable in `Int` (see `boundedInt`). Every integer
    /// read of metadata JSON goes through here instead of `Int(_:)`.
    public var intValue: Int? {
        guard case .number(let n) = self else { return nil }
        return Self.boundedInt(n)
    }

    /// The one bounded `Double → Int` conversion for metadata-supplied JSON
    /// numbers: `nil` when the value is not finite or not representable in
    /// `Int`, never a trap.
    ///
    /// `Int(_:)` / `Int.init` on a `Double` TRAPS outside `Int`'s range, and
    /// the top of that range is a trap door: `Double(Int.max)` rounds UP to
    /// exactly 2^63, so an inclusive `n <= Double(Int.max)` upper bound ADMITS
    /// 2^63 and `Int(9_223_372_036_854_775_808.0)` dies with "Double value
    /// cannot be converted to Int because the result would be greater than
    /// Int.max". The bound here is therefore 2^63-EXCLUSIVE, so no
    /// representable JSON number can kill the process through an integer read.
    ///
    /// In-range values keep `Int(_:)` semantics exactly: a fractional value
    /// truncates toward zero. Out-of-range values are the CALLER's decision —
    /// callers degrade to their own missing-value default (`?? 0`, an optional,
    /// or a dropped map entry); they must not clamp to an invented revision a
    /// caller would then act on.
    ///
    /// Twin of `FleetNetworking.JSONValue.boundedInt` (identical bounds).
    /// FleetCore owns this copy because the module dependency is one-way
    /// (`FleetNetworking` → `FleetCore`), so FleetCore cannot import the
    /// networking helper.
    public static func boundedInt(_ n: Double) -> Int? {
        guard n.isFinite,
              n >= -9_223_372_036_854_775_808.0, // -2^63 (exactly representable)
              n < 9_223_372_036_854_775_808.0 // 2^63-EXCLUSIVE
        else { return nil }
        return Int(n)
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
