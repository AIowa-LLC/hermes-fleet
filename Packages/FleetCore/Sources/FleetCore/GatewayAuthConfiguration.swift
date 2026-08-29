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
