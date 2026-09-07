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
    /// The auth REST surface (`/api/auth/providers`,
    /// `/auth/password-login`, `/api/auth/ws-ticket`) answered with this
    /// HTTP status. 401/403 → the credential was rejected; 404/405/410 →
    /// the endpoint answered but is NOT serving the gateway API (wrong
    /// port/surface — the F1 wrong-endpoint case). Non-secret.
    case httpStatus(Int)
    /// P0-9: the auth REST surface rejected the request for a CAUSE it named
    /// in its JSON body (e.g. the tunnel's 401 `{"reason":"no_cookie"}`).
    /// The reason discriminates a wrong-STRATEGY attempt (this gateway wants
    /// username & password sign-in, not a token) from a bad credential, so
    /// the UI can say what to actually do instead of a generic
    /// "re-authenticate". Non-secret (a server-echoed classification word).
    case rejected(reason: AuthRejectionReason)
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
        case .httpStatus(let code):
            return "auth endpoint returned HTTP \(code)"
        case .rejected(let reason):
            return "auth rejected: \(reason.rawValue)"
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

/// P0-9 — the cause the auth surface NAMED for its rejection, parsed from
/// the JSON body it returned (`{"reason": "..."}`). These are the
/// classification words the Hermes gateway actually emits (verified against
/// the live tunnel: ws-ticket 401 → `no_cookie` when no session cookie
/// accompanies a token-header mint; 403 for a `?token=` loopback attempt).
/// A reason the client does not know decodes to `.unknown` — vocabulary is
/// additive and never a hard failure.
public enum AuthRejectionReason: String, Sendable, Hashable, Codable {
    /// 401 from ws-ticket: no session cookie on the mint request — the
    /// gateway authenticates ONLY via the username/password cookie flow.
    /// A session-token-header attempt gets exactly this (live-wire
    /// verified): the stored strategy is wrong for this gateway.
    case noCookie = "no_cookie"
    /// The rejection named a reason the client has no vocabulary for.
    case unknown
}
