/// Hermes profile slug (e.g. "default", "researcher", "apple-dev").
///
/// A profile slug alone is NOT a unique resource — the same slug exists on
/// many gateways. Combine with `GatewayID` for canonical identity, and fail
/// closed rather than guessing when ownership is ambiguous.
public struct ProfileSlug: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}
