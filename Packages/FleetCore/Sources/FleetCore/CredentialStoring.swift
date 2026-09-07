import Foundation

/// The credential-store seam (spec §16: "Secrets belong in Keychain").
///
/// Lives in FleetCore so the registry service and the UI depend on this
/// protocol — never on the concrete Keychain implementation in FleetSecurity
/// (mirrors the M0 seam pattern used for `HermesTransport`,
/// `RosterProviding`, `GatewayConnectivityProviding`). The concrete store is
/// `KeychainCredentialStore` (FleetSecurity); tests use an in-memory double.
///
/// A store MUST NOT log, echo, or cache the credential. Errors carry no
/// secret material.
public protocol CredentialStoring: Sendable {
    /// Store (upsert) a credential for a gateway.
    func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws
    /// Load the stored credential for a gateway, or `nil` when none is stored.
    func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential?
    /// Delete the stored credential for a gateway. Missing item is a no-op.
    func deleteCredential(for gatewayID: GatewayID) async throws
}

/// Errors a `CredentialStoring` implementation surfaces. None carry secret
/// material (spec §29: no secrets in error text).
public enum CredentialStoreError: Error, Sendable, Equatable, LocalizedError {
    /// No credential is stored for the requested gateway.
    case itemNotFound
    /// The stored data could not be decoded as UTF-8 text.
    case malformedData
    /// The underlying OS/keychain call failed (OSStatus numeric only).
    case unexpectedStatus(Int)
    /// The store is unavailable (e.g. keychain access denied).
    case storeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound: return "no credential stored for this gateway"
        case .malformedData: return "stored credential is not valid UTF-8"
        case .unexpectedStatus(let code): return "credential store error (status \(code))"
        case .storeUnavailable(let detail): return "credential store unavailable: \(detail)"
        }
    }
}
