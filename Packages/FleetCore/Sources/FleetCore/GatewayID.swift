/// Globally unique identifier of a Hermes gateway (a fleet node / machine).
///
/// Canonical fleet identity is `GatewayID + ProfileSlug` — a display name is
/// never an identity. Two machines exposing similarly named profiles are two
/// distinct resources.
public struct GatewayID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}
