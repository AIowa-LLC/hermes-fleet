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
            return "This phone can control the gateway: chat with agents, run work, manage files, agents and settings. This grants the same broad operator access as signing in."
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
    /// Whether the gateway says the owner must approve this phone's request (a v2 invitation).
    /// False for a legacy invitation and for gateways that predate the field.
    public let approvalRequired: Bool
    /// Pairing protocol versions the gateway announced (`[1, 2]`); empty when it did not say.
    public let protocols: [Int]

    public init(
        gateway: PairingGatewayIdentity, label: String, access: [PairingAccess],
        expiresAt: Date, tlsFingerprint: SPKIFingerprint,
        approvalRequired: Bool = false, protocols: [Int] = []
    ) {
        self.gateway = gateway
        self.label = label
        self.access = access
        self.expiresAt = expiresAt
        self.tlsFingerprint = tlsFingerprint
        self.approvalRequired = approvalRequired
        self.protocols = protocols
    }
}

// MARK: - Approval (v2)

/// The random secret that binds a pending approval request to the phone that made it. The
/// gateway returns the credential only to a poll that presents it. Memory-only: never
/// persisted, logged or placed in an error; losing it (app killed) just lets the request expire.
public struct PairingClientSecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String

    /// Exactly 32 random bytes, base64url without padding (43 characters).
    public static func generate() -> PairingClientSecret {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return PairingClientSecret(rawValue: PairingInvitationLink.base64URLEncode(Data(bytes)))
    }

    /// For tests and transports that rebuild a secret; rejects anything that is not 43 base64url characters.
    public init?(validating text: String) {
        guard text.utf8.count == 43, PairingInvitationLink.base64URLDecode(text) != nil else { return nil }
        self.rawValue = text
    }

    private init(rawValue: String) { self.rawValue = rawValue }

    public var description: String { "[REDACTED]" }
    public var debugDescription: String { "PairingClientSecret(redacted)" }
}

/// A pending request the owner has to approve by its match code.
public struct PairingApprovalRequest: Sendable, Equatable {
    public let id: String
    /// Six decimal digits the owner compares with what they approve.
    public let matchCode: String
    public let expiresAt: Date
    /// Seconds between polls the gateway asks for (already clamped by the client).
    public let pollInterval: TimeInterval
    /// Identity the gateway reported, already checked against the preview.
    public let gateway: PairingGatewayIdentity
    /// The access the person confirmed in the preview; the approved credential must match it.
    public let scopes: [String]
    /// The key the gateway presented (it equals the link's pin). Every later poll must see it.
    public let tlsFingerprint: SPKIFingerprint

    public init(
        id: String, matchCode: String, expiresAt: Date, pollInterval: TimeInterval,
        gateway: PairingGatewayIdentity, scopes: [String], tlsFingerprint: SPKIFingerprint
    ) {
        self.id = id
        self.matchCode = matchCode
        self.expiresAt = expiresAt
        self.pollInterval = pollInterval
        self.gateway = gateway
        self.scopes = scopes
        self.tlsFingerprint = tlsFingerprint
    }

    /// `482913` -> `482 913`.
    public var spacedMatchCode: String { PairingMatchCode.spaced(matchCode) }
}

/// What a poll of a pending request reports.
public enum PairingApprovalStatus: Sendable, Equatable {
    case pending
    /// Approved by the owner: the credential, to be saved exactly like a redeemed grant.
    case approved(PairingGrant)
    /// Approved and already collected (or the collection window closed). No credential.
    case delivered
    case denied
    case expired
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
    /// The host name did not resolve (DNS failure).
    case hostNotFound
    /// The gateway did not answer in time.
    case timedOut
    /// The gateway's address refused the connection.
    case connectionRefused
    /// This phone has no network connection.
    case offline
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
    /// Saving failed and remote revocation or local cleanup was not confirmed.
    case rollbackUnconfirmed
    /// The gateway answered `approval_not_supported`: it only supports direct redemption.
    case approvalNotSupported
    /// The gateway answered `approval_required`: this invitation must be approved by its owner.
    case approvalRequired
    /// The gateway does not know this request, or the client secret did not match.
    case invalidRequest

    /// Whether trying the very same link again can help.
    public var isRetryable: Bool {
        switch self {
        case .unreachable, .hostNotFound, .timedOut, .connectionRefused, .offline,
             .rateLimited, .interrupted, .serverError: return true
        default: return false
        }
    }

    /// Whether the phone could not get a response from the gateway at all (as opposed to the
    /// gateway answering with a refusal).
    public var isNetworkFailure: Bool {
        switch self {
        case .unreachable, .hostNotFound, .timedOut, .connectionRefused, .offline: return true
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
    func revoke(origin: URL, credential: PairingDeviceCredential, expecting: SPKIFingerprint?) async -> PairingRevocationOutcome

    // v2 (owner approval). Defaults answer "not supported" so a seam that only knows direct
    // redemption keeps working.

    /// Create (or, for the same `clientSecret`, re-read) the pending request for a v2 link.
    /// `expecting` is the preview the person confirmed; the key and identity must match it.
    func requestApproval(
        _ link: PairingInvitationLink, deviceName: String, deviceModel: String,
        clientSecret: PairingClientSecret, expecting: PairingPreview
    ) async throws(PairingFailure) -> PairingApprovalRequest
    /// Ask whether the owner decided. Safe to repeat: the credential is returned on every
    /// poll until it is first used or its collection window closes.
    func pollApproval(
        _ request: PairingApprovalRequest, clientSecret: PairingClientSecret
    ) async throws(PairingFailure) -> PairingApprovalStatus
}

public extension GatewayPairing {
    func revoke(origin: URL, credential: PairingDeviceCredential) async -> PairingRevocationOutcome {
        await revoke(origin: origin, credential: credential, expecting: nil)
    }

    func requestApproval(
        _ link: PairingInvitationLink, deviceName: String, deviceModel: String,
        clientSecret: PairingClientSecret, expecting: PairingPreview
    ) async throws(PairingFailure) -> PairingApprovalRequest {
        throw .approvalNotSupported
    }

    func pollApproval(
        _ request: PairingApprovalRequest, clientSecret: PairingClientSecret
    ) async throws(PairingFailure) -> PairingApprovalStatus {
        throw .approvalNotSupported
    }
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

/// Register an invitation grant only after its credential and TLS pin are securely saved.
/// The durable gateway record is the commit marker; incomplete grants must never be
/// exposed as registered gateways. Separate from legacy/manual registration.
public protocol GatewayPairingRegistering: Sendable {
    func registerPairedGateway(_ grant: PairingGrant) async throws -> FleetGateway
    /// Cleanup only an uncommitted transaction owned by this service; never a saved gateway.
    func discardUncommittedPairing(_ grant: PairingGrant) async throws
}

/// Presentation helpers for the six-digit match code, pure so they are unit-testable on the host.
public enum PairingMatchCode {
    /// `482913` -> `482 913` (anything that is not exactly six digits is returned as is).
    public static func spaced(_ code: String) -> String {
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    /// What VoiceOver reads: each digit on its own ("4, 8, 2, 9, 1, 3"), never "four hundred...".
    public static func spoken(_ code: String) -> String {
        code.map(String.init).joined(separator: ", ")
    }

    /// What the owner sends to Hermes to approve exactly this code.
    public static func approveCommand(_ code: String) -> String { "/fleet approve \(code)" }

    /// Normalises owner input: spaces are ignored (`482 913` == `482913`).
    public static func normalized(_ input: String) -> String {
        input.filter { !$0.isWhitespace }
    }
}
