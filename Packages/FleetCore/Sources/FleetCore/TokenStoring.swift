import Foundation

/// A single short-lived secret (a WS ticket token or a session token) held
/// only in transit between the Keychain store and the code that uses it to
/// authenticate (spec §16 / synthesis §11: "Tokens/tickets in Keychain
/// (WhenUnlockedThisDeviceOnly, no iCloud sync)").
///
/// Safety invariants (mirrors `GatewayCredential`, M7):
/// - The raw value is never printed: `description` / `debugDescription` are
///   redacted, so a token can never leak into logs, UI, or artifacts.
/// - This type is deliberately NOT `Codable` — it cannot be serialized into a
///   SwiftData cache, a file, or a JSON log by accident ("no tokens in
///   cache", synthesis §12).
public struct StoredToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The secret value. `internal`-facing on purpose: callers that need it
    /// (the Keychain store, the ticket minter) read it explicitly.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { "[REDACTED]" }
    public var debugDescription: String { "StoredToken(redacted)" }
}

/// The Keychain token/ticket store seam (spec §16: "Secrets belong in
/// Keychain"; synthesis §12: GenericPassword, per-peer, accessibility
/// `WhenUnlockedThisDeviceOnly`, no iCloud sync).
///
/// Lives in FleetCore so the transport/service layer depends on this protocol
/// — never on the concrete Keychain implementation in FleetSecurity (mirrors
/// the M7 `CredentialStoring` seam pattern). The concrete store is
/// `KeychainTokenStore` (FleetSecurity); tests use an in-memory double.
///
/// A store MUST NOT log, echo, or cache the token. Errors carry no secret
/// material.
public protocol TokenStoring: Sendable {
    /// Store (upsert) a token/ticket for a peer gateway.
    func saveToken(_ token: StoredToken, for gatewayID: GatewayID) async throws
    /// Load the stored token/ticket for a peer gateway, or `nil` when none.
    func loadToken(for gatewayID: GatewayID) async throws -> StoredToken?
    /// Delete the stored token/ticket for a peer gateway. Missing is a no-op.
    func deleteToken(for gatewayID: GatewayID) async throws
}

/// Errors a `TokenStoring` implementation surfaces. None carry secret
/// material (spec §29: no secrets in error text).
public enum TokenStoreError: Error, Sendable, Equatable, LocalizedError {
    /// No token/ticket is stored for the requested peer.
    case itemNotFound
    /// The stored data could not be decoded as UTF-8 text.
    case malformedData
    /// The underlying OS/keychain call failed (OSStatus numeric only).
    case unexpectedStatus(Int)
    /// The store is unavailable (e.g. keychain access denied).
    case storeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound: return "no token stored for this gateway"
        case .malformedData: return "stored token is not valid UTF-8"
        case .unexpectedStatus(let code): return "token store error (status \(code))"
        case .storeUnavailable(let detail): return "token store unavailable: \(detail)"
        }
    }
}
