import Foundation

/// An OAuth token pair (access + refresh) for the native flow, stored in
/// Keychain per gateway (spec §16: "Secrets belong in Keychain"; synthesis
/// §12: WhenUnlockedThisDeviceOnly, no iCloud sync).
///
/// Safety invariants (mirrors `StoredToken`, `GatewayCredential`):
/// - Raw values are never printed: `description` / `debugDescription` are
///   redacted, so tokens cannot leak into logs, UI, or artifacts.
/// - This type is deliberately NOT `Codable` — it cannot be serialized into
///   a SwiftData cache, a file, or a JSON log by accident. Keychain
///   persistence uses a private envelope in `KeychainOAuthTokenStore`.
public struct OAuthTokenPair: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The access token (Bearer).
    public let accessToken: String
    /// The refresh token (used at `POST /auth/native/refresh`).
    public let refreshToken: String
    /// Absolute expiry of the access token (unix epoch seconds).
    public let expiresAt: Int
    /// The provider that issued these tokens (e.g. `"nous"`).
    public let provider: String
    /// The provider-scoped user identifier.
    public let userId: String

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Int,
        provider: String,
        userId: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.provider = provider
        self.userId = userId
    }

    /// Whether the access token is expired, with a 30s clock-skew buffer.
    public func isAccessTokenExpired(asOf now: Date = Date()) -> Bool {
        now.timeIntervalSince1970 > Double(expiresAt) - 30
    }

    public var description: String { "[REDACTED]" }
    public var debugDescription: String { "OAuthTokenPair(redacted)" }
}

/// Keychain-backed OAuth token persistence (spec §16; synthesis §12).
///
/// Tokens live only in Keychain (GenericPassword, per-gateway,
/// `WhenUnlockedThisDeviceOnly`, no iCloud sync). They are never written
/// to files, logs, or user defaults, and never surfaced in `description`
/// or errors.
public protocol OAuthTokenStoring: Sendable {
    func saveTokenPair(_ pair: OAuthTokenPair, for gatewayID: GatewayID) async throws
    func loadTokenPair(for gatewayID: GatewayID) async throws -> OAuthTokenPair?
    /// Missing is a no-op.
    func deleteTokenPair(for gatewayID: GatewayID) async throws
}

/// Errors an `OAuthTokenStoring` implementation surfaces. None carry secret
/// material (spec §29).
public enum OAuthTokenStoreError: Error, Sendable, Equatable, LocalizedError {
    case itemNotFound
    case malformedData
    case unexpectedStatus(Int)
    case storeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound: return "no OAuth tokens stored for this gateway"
        case .malformedData: return "stored OAuth tokens are not valid"
        case .unexpectedStatus(let code): return "OAuth token store error (status \(code))"
        case .storeUnavailable(let detail): return "OAuth token store unavailable: \(detail)"
        }
    }
}

/// A session-capable OAuth provider advertised by `GET /api/auth/providers`.
public struct OAuthProvider: Sendable, Hashable, Codable {
    public let name: String
    public let displayName: String
    public let supportsPassword: Bool

    public init(name: String, displayName: String, supportsPassword: Bool) {
        self.name = name
        self.displayName = displayName
        self.supportsPassword = supportsPassword
    }
}

/// Errors from the native OAuth flow. None carry secret material
/// (spec §29: no secrets in error text).
public enum NativeOAuthError: Error, Sendable, Equatable, LocalizedError {
    case noSessionProviders
    case unknownProvider(String)
    case multipleProviders
    case authorizeFailed(String)
    case cancelled
    case callbackTimeout
    case missingCode
    case stateMismatch
    case tokenExchangeFailed(String)
    case malformedTokenResponse
    case sessionExpired
    case providerUnreachable
    case networkError(String)
    case invalidRedirectURI
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .noSessionProviders:
            return "Gateway advertises no session-capable OAuth providers"
        case .unknownProvider(let name):
            return "Unknown or unsupported provider: \(name)"
        case .multipleProviders:
            return "Multiple OAuth providers available; choose one"
        case .authorizeFailed(let detail):
            return "Authorization failed: \(detail)"
        case .cancelled:
            return "Sign-in cancelled"
        case .callbackTimeout:
            return "Authorization callback timed out"
        case .missingCode:
            return "Authorization code missing from callback"
        case .stateMismatch:
            return "OAuth state mismatch"
        case .tokenExchangeFailed(let detail):
            return "Token exchange failed: \(detail)"
        case .malformedTokenResponse:
            return "Token response was malformed"
        case .sessionExpired:
            return "Session expired; please sign in again"
        case .providerUnreachable:
            return "Auth provider unreachable"
        case .networkError(let detail):
            return "Network error: \(detail)"
        case .invalidRedirectURI:
            return "Invalid redirect URI (must be http://127.0.0.1:<port>/…)"
        case .internalError(let detail):
            return "Internal error: \(detail)"
        }
    }
}

/// Opens the gateway authorize URL in the system browser. The loopback
/// listener captures the redirect; this presenter only has to *open* the
/// URL (and surface cancellation). Implementations live in the app target
/// (`ASWebAuthenticationSession`) so FleetCore stays host-testable.
public protocol NativeOAuthBrowserPresenting: Sendable {
    func presentAuthorizeURL(_ url: URL) async throws
}
