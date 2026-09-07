import Foundation

/// Non-secret description of how a gateway authenticates (spec §12 model
/// "authentication configuration"; spec §16 Authentication Architecture).
///
/// The credential itself never lives here — only the strategy and whether a
/// credential is currently stored (in Keychain). Storing a secret in this
/// value, or anywhere in the registry model, is a bug.
public struct GatewayAuthConfiguration: Hashable, Sendable, Codable {
    /// Authentication strategy for the gateway (spec §16 "potential
    /// strategies"; tolerant — unknown strategies are a future addition).
    public enum Strategy: String, Hashable, Sendable, Codable, CaseIterable {
        /// No authentication configured.
        case none
        /// Dashboard-compatible session token (`X-Hermes-Session-Token`
        /// header → `POST /api/auth/ws-ticket`). This is the v0 concrete
        /// strategy (synthesis §11).
        case sessionToken
        /// Future bearer-token strategy (accepted vocabulary; not v0).
        case bearerToken
        /// Loopback token passed as `?token=` on the socket (synthesis §11
        /// "optional loopback `?token=`"; spec §16 trusted-network strategy).
        case loopbackToken
        /// Username/password against the gateway's password provider:
        /// `POST /auth/password-login` → session cookie → `POST
        /// /api/auth/ws-ticket` → `?ticket=` (P3 LAN-gateway fix). The
        /// credential is the username + password pair (stored as one Keychain
        /// item).
        case usernamePassword
    }

    public var strategy: Strategy
    /// Whether a credential is currently stored for this gateway (Keychain).
    public var credentialStored: Bool

    public init(strategy: Strategy = .none, credentialStored: Bool = false) {
        self.strategy = strategy
        self.credentialStored = credentialStored
    }

    /// A gateway with no authentication configured.
    public static let none = GatewayAuthConfiguration()
}
