import Foundation

/// A single secret credential for a gateway, held only in transit between
/// the Keychain store and the transport's ticket minter.
///
/// Shapes (per gateway auth strategy):
/// - token strategies (`sessionToken` / `bearerToken` / `loopbackToken`):
///   `rawValue` is the token; `username` is nil.
/// - `.usernamePassword` strategy: `rawValue` is the password and `username`
///   is set. The two halves are stored together as one Keychain item
///   (composite encoding in the store), so the login flow can present both.
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
    /// Username half for the `.usernamePassword` strategy (nil for token
    /// strategies). The username is not itself a secret, but it rides inside
    /// the same redacted value so the login flow can authenticate with both
    /// halves without exposing the password separately.
    public let username: String?

    public init(rawValue: String, username: String? = nil) {
        self.rawValue = rawValue
        self.username = username
    }

    public var description: String { "[REDACTED]" }
    public var debugDescription: String { "GatewayCredential(redacted)" }
}
