import Foundation

/// The owner identity provider used by the native sign-in flow. Provider
/// identity is presentation metadata; authentication remains an opaque,
/// short-lived authorization value.
public struct OwnerIdentityProvider: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let supportsPassword: Bool

    public init(id: String, displayName: String, supportsPassword: Bool) {
        self.id = id
        self.displayName = displayName
        self.supportsPassword = supportsPassword
    }
}

/// An ephemeral owner authorization. Never persist or print this value.
public struct OwnerAuthorization: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: Sendable, Equatable { case bearer, sessionCookie }

    public let kind: Kind
    /// The value is consumed only by the authenticated networking client.
    /// The redacted printable representation protects accidental diagnostics.
    public let secret: String
    public let cookieName: String?

    private init(kind: Kind, secret: String, cookieName: String? = nil) {
        self.kind = kind
        self.secret = secret
        self.cookieName = cookieName
    }

    public static func bearer(_ accessToken: String) -> Self {
        Self(kind: .bearer, secret: accessToken)
    }

    public static func sessionCookie(name: String, value: String) -> Self {
        Self(kind: .sessionCookie, secret: value, cookieName: name)
    }

    public var description: String { "[REDACTED]" }
    public var debugDescription: String { "OwnerAuthorization(redacted)" }
}

public struct OwnerConnectionMetadata: Sendable, Equatable {
    public let gatewayID: GatewayID
    public let displayName: String
    public let origin: URL
    public let scopes: [String]
    public let enrollmentVersion: Int

    public init(gatewayID: GatewayID, displayName: String, origin: URL, scopes: [String], enrollmentVersion: Int) {
        self.gatewayID = gatewayID
        self.displayName = displayName
        self.origin = origin
        self.scopes = scopes
        self.enrollmentVersion = enrollmentVersion
    }
}

/// A phone-generated identity persisted securely before the first enrollment
/// request. Keeping the same ID and secret allows an interrupted request to
/// be retried idempotently after relaunch.
public struct PendingOwnerDeviceIdentity: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let deviceID: String
    public let secret: String

    public init(deviceID: String, secret: String) {
        self.deviceID = deviceID
        self.secret = secret
    }

    public var description: String { "[REDACTED]" }
    public var debugDescription: String { "PendingOwnerDeviceIdentity(redacted)" }
}

public protocol OwnerEnrollmentIdentityStoring: Sendable {
    func loadIdentity(for endpointID: GatewayID) async throws -> PendingOwnerDeviceIdentity?
    func saveIdentity(_ identity: PendingOwnerDeviceIdentity, for endpointID: GatewayID) async throws
    func deleteIdentity(for endpointID: GatewayID) async throws
}

/// Local enrollment material keyed by an endpoint must be retired before a
/// registered gateway is removed. Implementations clear any interrupted
/// enrollment secret and temporary endpoint TLS trust alias.
public protocol GatewayEnrollmentCleanupProviding: Sendable {
    func removeEnrollmentMaterial(for gateway: FleetGateway) async throws
}

public struct OwnerEnrolledDevice: Sendable, Equatable {
    public let gatewayID: GatewayID
    public let displayName: String
    public let deviceID: String
    public let scopes: [String]

    public init(gatewayID: GatewayID, displayName: String, deviceID: String, scopes: [String]) {
        self.gatewayID = gatewayID
        self.displayName = displayName
        self.deviceID = deviceID
        self.scopes = scopes
    }
}

/// UI-visible flow state; transport implementation details remain in
/// FleetNetworking and the view never depends on that module.
public enum OwnerEnrollmentState: Sendable, Equatable {
    case addressEntry
    case detectingProvider
    case signingIn
    case ready
    case connecting
    case connected(OwnerEnrolledDevice)
    case failed(OwnerEnrollmentError)
}

public enum OwnerEnrollmentError: Error, Sendable, Equatable, LocalizedError {
    case invalidAddress
    case insecureTransport
    case unauthorized
    case ownerRequired
    case forbidden
    case gatewayAlreadyRegistered
    case rateLimited(retryAfterSeconds: Int?)
    case unreachable
    case tlsPinMismatch
    case tlsFirstUse(SPKIFingerprint)
    case tlsApprovalUnavailable
    case redirectedToUntrustedOrigin
    case malformedResponse
    case credentialStorageFailed
    case rollbackFailed
    case previousEnrollmentRevoked
    case identityStorageFailed
    case serverRejected(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter a valid gateway address."
        case .insecureTransport: return "Connect using a secure HTTPS address."
        case .unauthorized: return "Sign in to the gateway owner account and try again."
        case .ownerRequired: return "This account cannot enroll phones on this gateway."
        case .forbidden: return "The gateway denied phone enrollment."
        case .gatewayAlreadyRegistered: return "This gateway is already registered on this phone."
        case .rateLimited: return "Too many enrollment attempts. Try again later."
        case .unreachable: return "The gateway could not be reached. Check the address and try again."
        case .tlsPinMismatch: return "The gateway’s security identity changed. Verify the gateway before connecting."
        case .tlsFirstUse(let fingerprint): return "Review and trust this gateway key: \(fingerprint.base64String)"
        case .tlsApprovalUnavailable: return "The gateway security review could not be saved securely."
        case .redirectedToUntrustedOrigin: return "The gateway redirected the request to an untrusted address."
        case .malformedResponse: return "The gateway returned an invalid enrollment response."
        case .credentialStorageFailed: return "The phone credential could not be saved securely."
        case .rollbackFailed: return "The phone credential could not be saved, and the gateway could not confirm rollback. Retry safely before continuing."
        case .previousEnrollmentRevoked: return "A previous enrollment was revoked. Retry setup to create a fresh phone identity."
        case .identityStorageFailed: return "Secure enrollment could not be prepared on this phone."
        case .serverRejected(let status): return "The gateway could not enroll this phone (HTTP \(status))."
        }
    }
}

public protocol OwnerEnrollmentProviding: Sendable {
    func discoverProviders(at address: URL) async throws -> [OwnerIdentityProvider]
    func signIn(
        at address: URL,
        providerID: String,
        username: String,
        password: String
    ) async throws -> OwnerAuthorization
    func approveTLSFirstUse(at address: URL, fingerprint: SPKIFingerprint) async throws
    func inspectConnection(at address: URL, authorization: OwnerAuthorization) async throws -> OwnerConnectionMetadata
    func enrollDevice(
        at address: URL,
        authorization: OwnerAuthorization,
        deviceName: String?,
        deviceModel: String?
    ) async throws -> OwnerEnrolledDevice
    func cancelEnrollment(
        at address: URL,
        authorization: OwnerAuthorization,
        deviceID: String,
        gatewayID: GatewayID
    ) async throws
}
