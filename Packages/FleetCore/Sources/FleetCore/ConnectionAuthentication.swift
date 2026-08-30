import Foundation

/// The authentication material for one gateway connection (spec §16
/// "Authentication must be abstracted from transport"; synthesis §11).
///
/// v0 concretes:
/// - `.ticket(StoredToken)` — a single-use WS ticket (30s TTL) minted from
///   `POST /api/auth/ws-ticket` and passed as `?ticket=` on the socket.
/// - `.loopbackToken(StoredToken)` — a loopback token passed as `?token=`.
/// - `.none` — no authentication configured.
///
/// Safety invariants (spec §16/§27/§29, synthesis §11/§12):
/// - The raw secret value is never printed: `description` / `debugDescription`
///   are redacted, so auth material can never leak into logs or UI.
/// - The associated values are `StoredToken` (deliberately NOT `Codable`), so
///   this value can never be serialized into a SwiftData cache, a file, or a
///   JSON log by accident ("no credentials in cache", synthesis §12).
public enum ConnectionAuthentication: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible {
    /// No authentication configured.
    case none
    /// A single-use WebSocket ticket (`?ticket=`), 30s TTL.
    case ticket(StoredToken)
    /// A loopback token (`?token=`), for loopback/LAN connections.
    case loopbackToken(StoredToken)

    public var description: String { "[REDACTED]" }
    public var debugDescription: String { "ConnectionAuthentication(redacted)" }
}

/// The authentication-provider seam (spec §16 "conceptual interface:
/// AuthenticationProvider"; synthesis §11 "AuthenticationProvider
/// abstraction"). Mirrors the M7 `CredentialStoring` / M10 `TokenStoring`
/// pattern: the transport and service layer depend on this protocol — never on
/// a concrete ticket minter or Keychain implementation.
///
/// A provider is bound to one gateway at construction (it holds the gateway
/// identity, auth strategy, ticket minter, and/or token store), so `authenticate`
/// needs no gateway parameter — the transport stays gateway-agnostic.
public protocol AuthenticationProviding: Sendable {
    /// Produce the auth material for this provider's gateway connection.
    func authenticate() async throws -> ConnectionAuthentication
}

/// Errors an `AuthenticationProviding` implementation surfaces. None carry
/// secret material (spec §29: no secrets in error text).
public enum AuthenticationError: Error, Sendable, Equatable, LocalizedError {
    /// The gateway has no auth strategy / the required dependency is missing.
    case notConfigured
    /// Ticket mint failed (detail is non-secret, e.g. an HTTP status).
    case ticketMintFailed(String)
    /// The minted ticket's TTL has already elapsed — never connect with a
    /// stale ticket (synthesis §11: single-use, 30s TTL).
    case ticketExpired
    /// A loopback token was requested but none is stored.
    case missingLoopbackToken
    /// The username/password strategy needs the username half of the stored
    /// credential, but the stored item is a token-only credential.
    case missingUsername
    /// The underlying store/keychain call failed (detail non-secret).
    case storeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "no authentication strategy configured"
        case .ticketMintFailed(let detail):
            return "ticket mint failed: \(detail)"
        case .ticketExpired:
            return "WebSocket ticket expired before connect"
        case .missingLoopbackToken:
            return "no loopback token stored for this gateway"
        case .missingUsername:
            return "no username stored for this gateway"
        case .storeUnavailable(let detail):
            return "authentication store unavailable: \(detail)"
        }
    }
}
