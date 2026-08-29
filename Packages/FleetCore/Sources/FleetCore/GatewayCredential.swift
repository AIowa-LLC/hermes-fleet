import Foundation

/// A single secret credential (e.g. a session token) for a gateway, held only
/// in transit between the Keychain store and the transport's ticket minter.
///
/// Safety invariants (spec §16, §27, §29):
/// - The raw value is never printed: `description` / `debugDescription` are
///   redacted, so a credential can never leak into logs, UI, or artifacts.
/// - This type is deliberately NOT `Codable` — it cannot be serialized into a
///   cache, a file, or a JSON log by accident.
public struct GatewayCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The secret value. `internal`-facing on purpose: callers that need it
    /// (the Keychain store, the ticket minter) read it explicitly.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { "[REDACTED]" }
    public var debugDescription: String { "GatewayCredential(redacted)" }
}
