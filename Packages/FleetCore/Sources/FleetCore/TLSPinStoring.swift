import Foundation

/// T3 TLS TOFU pinning — the expected SPKI (Subject Public Key Info) SHA-256
/// fingerprint for a gateway's TLS certificate, pinned on first use and
/// stored per-gateway in the Keychain (`TLSPinStoring`).
///
/// The pin is PUBLIC key material (a hash of the certificate's public key),
/// not a secret: it identifies the gateway's key, it may safely appear in
/// logs and UI (the pin-change warning shows both old and new pins), and it
/// is NOT `Codable` — mirroring `StoredToken`'s accidental-serialization
/// guard while remaining printable for identification.
public struct SPKIFingerprint: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The raw 32-byte SHA-256 digest of the DER-encoded SPKI.
    public let sha256Digest: Data

    /// Initialize from a raw SHA-256 digest (exactly 32 bytes required).
    public init?(sha256Digest: Data) {
        guard sha256Digest.count == 32 else { return nil }
        self.sha256Digest = sha256Digest
    }

    /// Initialize from an arbitrary byte sequence (hashed if needed) —
    /// convenience for tests computing pins from fixture keys.
    public init(rawBytes: [UInt8]) {
        self.sha256Digest = Data(rawBytes)
    }

    /// Initialize from the canonical base64 form (44 chars, trailing '=').
    /// Returns nil for invalid/short input — never a partial pin.
    public init?(base64: String) {
        guard let data = Data(base64Encoded: base64), data.count == 32 else {
            return nil
        }
        self.sha256Digest = data
    }

    /// Canonical base64 representation (the form shown in the pin-change UI
    /// and stored in the Keychain).
    public var base64String: String {
        sha256Digest.base64EncodedString()
    }

    /// Identifying but stable — the pin is public key material, so printing
    /// it is safe; the prefix is enough to correlate with the Keychain entry
    /// or another device's pin without dumping all 44 chars.
    public var description: String {
        let b64 = base64String
        return String(b64.prefix(12)) + "…"
    }
}

/// Errors a `TLSPinStoring` implementation surfaces. None carry secret
/// material (the pin is public key material, but store failures stay
/// numeric/typed like `TokenStoreError`).
public enum PinStoreError: Error, Sendable, Equatable, LocalizedError {
    /// No pin is stored for the requested peer (TOFU first use).
    case itemNotFound
    /// The stored pin data is malformed (not 32 bytes / bad base64).
    case malformedData
    /// The underlying OS/keychain call failed (OSStatus numeric only).
    case unexpectedStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound: return "no TLS pin stored for this gateway"
        case .malformedData: return "stored TLS pin is malformed"
        case .unexpectedStatus(let code): return "TLS pin store error (status \(code))"
        }
    }
}

/// The per-gateway TLS pin store seam (T3: trust-on-first-use SPKI pinning).
///
/// The app pins the SHA-256 of the gateway certificate's DER SPKI on FIRST
/// successful TLS connection and rejects any later certificate whose SPKI
/// hash differs (MITM / replaced-cert protection for self-signed gateways).
///
/// Lives in FleetCore so the transport layer depends on this protocol —
/// never on the concrete Keychain implementation in FleetSecurity (mirrors
/// the `TokenStoring` seam pattern). The concrete store is
/// `KeychainPinStore` (FleetSecurity); tests use `InMemoryPinStore`.
///
/// A store MUST NOT log the pin. The pin itself is public key material, but
/// store errors carry no diagnostic payloads.
public protocol TLSPinStoring: Sendable {
    /// Store (upsert) the expected SPKI pin for a peer gateway.
    func savePin(_ pin: SPKIFingerprint, for gatewayID: GatewayID) async throws
    /// Load the stored pin for a peer gateway, or `nil` when none (TOFU
    /// first use).
    func loadPin(for gatewayID: GatewayID) async throws -> SPKIFingerprint?
    /// Delete the stored pin for a peer gateway (gateway removal). Missing
    /// is a no-op.
    func deletePin(for gatewayID: GatewayID) async throws
}

/// Synchronous variants used inside the URLSession challenge callback (it
/// cannot await). Implementations bridge to the async seam; SecItem calls
/// are synchronous anyway.
public protocol SynchronousPinStoring: Sendable {
    func syncSavePin(_ pin: SPKIFingerprint, for gatewayID: GatewayID) throws
    func syncLoadPin(for gatewayID: GatewayID) throws -> SPKIFingerprint?
    func syncDeletePin(for gatewayID: GatewayID) throws
}
