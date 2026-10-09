import Foundation

// MARK: - Gateway identity & preview

/// Who a pairing invitation says it is for, as asserted by the gateway the
/// phone actually reached (over a validated TLS connection to the link's host).
public struct PairingGatewayIdentity: Sendable, Equatable {
    /// Stable per-installation identifier of the gateway (32 lowercase hex).
    /// Survives address changes; the basis for de-duplicating gateways.
    public let instanceID: String
    /// Name the owner's gateway presents (display only; never used for routing).
    public let displayName: String
    /// `https://host[:port]` the gateway reports for itself. Must equal the link's origin.
    public let origin: URL

    public init(instanceID: String, displayName: String, origin: URL) {
        self.instanceID = instanceID
        self.displayName = displayName
        self.origin = origin
    }
}

/// Access an invitation can request, with the app's OWN wording. Text that arrives from the
/// gateway is never what the person is asked to approve; an unknown scope is refused.
public enum PairingScope: String, Sendable, CaseIterable {
    case fleetOperator = "fleet:operator"

    public var summary: String {
        switch self {
        case .fleetOperator:
            return "Chat with the agents on this gateway, run and review their work, and manage them. This is the same access as signing in."
        }
    }
}

/// One thing the invitation asks the phone to be granted.
public struct PairingAccess: Sendable, Equatable {
    public let scope: String
    public let summary: String
    public init(scope: String, summary: String) {
        self.scope = scope
        self.summary = summary
    }
}

/// What a still-unused invitation offers. Obtaining it consumes and approves nothing.
public struct PairingPreview: Sendable, Equatable {
    public let gateway: PairingGatewayIdentity
    /// Label the owner gave the invitation (display only).
    public let label: String
    public let access: [PairingAccess]
    public let expiresAt: Date
    /// The key (SPKI) the gateway presented when this preview was fetched over a
    /// system-trusted connection. Redemption must see the very same key.
    public let tlsFingerprint: SPKIFingerprint

    public init(
        gateway: PairingGatewayIdentity, label: String, access: [PairingAccess],
        expiresAt: Date, tlsFingerprint: SPKIFingerprint
    ) {
        self.gateway = gateway
        self.label = label
        self.access = access
        self.expiresAt = expiresAt
        self.tlsFingerprint = tlsFingerprint
    }
}

/// The device-specific credential a redeemed invitation yields. Redacted when printed.
public struct PairingDeviceCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { "[REDACTED]" }
    public var debugDescription: String { "PairingDeviceCredential(redacted)" }
}

/// The result of a successful redemption. Held only long enough to be saved in the Keychain.
public struct PairingGrant: Sendable, Equatable, CustomStringConvertible {
    public let gateway: PairingGatewayIdentity
    public let deviceID: String
    public let credential: PairingDeviceCredential
    /// The system-validated key the gateway presented during redemption.
    public let tlsFingerprint: SPKIFingerprint

    public init(
        gateway: PairingGatewayIdentity, deviceID: String,
        credential: PairingDeviceCredential, tlsFingerprint: SPKIFingerprint
    ) {
        self.gateway = gateway
        self.deviceID = deviceID
        self.credential = credential
        self.tlsFingerprint = tlsFingerprint
    }

    public var description: String { "PairingGrant(gateway: \(gateway.origin.host ?? ""), credential: [REDACTED])" }
}

// MARK: - Failures

/// Every way the pairing flow can fail, in the words the person needs. Payload-free
/// on purpose: nothing here can carry a secret, a link, or a server error body.
public enum PairingFailure: Error, Sendable, Equatable {
    /// The pasted/scanned/opened text is not a pairing link.
    case malformedLink
    /// A pairing link from a newer app/gateway format.
    case unsupportedLinkVersion
    /// The link is not https, or its host is not an acceptable public name.
    case insecureDestination
    /// The gateway does not recognise the invitation (never existed, mistyped, or wrong secret).
    case invalidInvitation
    case expired
    /// Already redeemed (a pairing link works once).
    case alreadyUsed
    /// The owner cancelled it (or too many wrong tries locked it).
    case cancelled
    case rateLimited
    /// This gateway has no pairing support (older version, not gated, or not enabled).
    case pairingUnavailable
    /// The phone could not reach the gateway (offline, DNS, timeout). A link does not create connectivity.
    case unreachable
    /// The gateway's certificate is not trusted by this phone.
    case untrustedCertificate
    /// The server identity changed between steps or did not match the link.
    case identityMismatch
    /// The invitation asks for access this app does not understand.
    case unsupportedAccess
    /// The gateway answered with something that is not the pairing protocol.
    case malformedResponse
    /// The exchange may have completed on the gateway but the result was lost.
    case interrupted
    case serverError
    /// The exchange worked but this phone could not save the result, so nothing was added.
    case couldNotSave

    /// Whether trying the very same link again can help.
    public var isRetryable: Bool {
        switch self {
        case .unreachable, .rateLimited, .interrupted, .serverError: return true
        default: return false
        }
    }
}

/// How a best-effort device revocation on the gateway turned out.
public enum PairingRevocationOutcome: Sendable, Equatable {
    /// The gateway confirmed the device credential is revoked.
    case revoked
    /// The gateway no longer knows this credential (already revoked or removed).
    case alreadyRevoked
    /// The gateway could not be reached; the owner must revoke the device from the gateway.
    case unreachable
    /// The gateway refused or answered unexpectedly.
    case failed
}

// MARK: - Seam

/// The pairing exchange with a gateway. The concrete HTTPS client lives in
/// FleetNetworking; the UI depends only on this seam.
public protocol GatewayPairing: Sendable {
    /// Inspect an invitation. MUST NOT consume it or approve anything.
    func preview(_ link: PairingInvitationLink) async throws(PairingFailure) -> PairingPreview
    /// Consume the invitation and receive the device credential. `expecting` is the
    /// preview the person confirmed: the gateway identity and TLS key must match it.
    func redeem(
        _ link: PairingInvitationLink, deviceName: String, expecting: PairingPreview
    ) async throws(PairingFailure) -> PairingGrant
    /// Tell the gateway to revoke this device credential (best effort; never throws).
    func revoke(origin: URL, credential: PairingDeviceCredential) async -> PairingRevocationOutcome
}

// MARK: - Stable identity

public extension GatewayID {
    /// The registry identity of a gateway added through pairing: derived from the
    /// gateway's stable installation id, not its address, so the same gateway
    /// reached at a new address is still the same gateway.
    init?(pairedInstanceID: String) {
        guard pairedInstanceID.count == 32,
              pairedInstanceID.unicodeScalars.allSatisfy({
                  ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x66)
              }) else { return nil }
        self.init(rawValue: "gw-" + pairedInstanceID)
    }
}
