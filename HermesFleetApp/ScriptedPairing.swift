import Foundation
import FleetCore

#if DEBUG && targetEnvironment(simulator)
/// Simulator-only stand-in for a gateway's pairing endpoints, so UI tests can drive the real
/// Add to Fleet screens deterministically. The behaviour is chosen by the first letters of the
/// invitation id in the link (a synthetic id, never a real one):
///
///     ok…        a valid invitation
///     expired…   the gateway reports it expired
///     used…      already redeemed
///     cancelled… cancelled by the owner
///     invalid…   not recognised
///     offline…   unreachable on the first attempt, fine on retry
///     slow…      the preview takes a few seconds (cancel/lock timing)
///
/// Version 2 links (`v=2…&k=…`) go through the approval path: confirming creates a request with
/// the fixed match code `482913`, and polling reports it approved after
/// `HERMES_FLEET_PAIRING_APPROVE_AFTER` seconds (default 4; `never` leaves it pending). The id
/// prefix picks the owner's decision:
///
///     denied…    the owner denies the request
///     lapsed…    the request expires unapproved
///     pending…   never decided (cancel / background timing)
///     (other)    approved after the delay
///
/// It touches no network. Real wire behaviour is verified against genuine TLS servers in the
/// FleetNetworking tests; this exists only so the SwiftUI flow can be exercised without one.
final class ScriptedPairingService: GatewayPairing, @unchecked Sendable {
    private let lock = NSLock()
    private var offlineServed: Set<String> = []
    private var redeemed: Set<String> = []
    private var requestedAt: [String: Date] = [:]
    private var requestSecrets: [String: String] = [:]
    private let instance = String(repeating: "ab12cd34", count: 4)
    static let matchCode = "482913"

    /// Seconds until the scripted owner approves; nil means never.
    private var approveAfter: TimeInterval? {
        let raw = ProcessInfo.processInfo.environment["HERMES_FLEET_PAIRING_APPROVE_AFTER"] ?? ""
        if raw == "never" { return nil }
        return TimeInterval(raw) ?? 4
    }

    func preview(_ link: PairingInvitationLink) async throws(PairingFailure) -> PairingPreview {
        let id = link.invitationID
        if id.hasPrefix("slow") { try? await Task.sleep(for: .seconds(4)) }
        if id.hasPrefix("expired") { throw .expired }
        if id.hasPrefix("used") { throw .alreadyUsed }
        if id.hasPrefix("cancelled") { throw .cancelled }
        if id.hasPrefix("invalid") { throw .invalidInvitation }
        if id.hasPrefix("offline") {
            let first: Bool = lock.withLock { offlineServed.insert(id).inserted }
            if first { throw .unreachable }
        }
        if lock.withLock({ redeemed.contains(id) }) { throw .alreadyUsed }
        return PairingPreview(
            gateway: PairingGatewayIdentity(
                instanceID: instance, displayName: "Scripted Pairing Gateway", origin: link.origin),
            label: "UI test link",
            access: [PairingAccess(scope: PairingScope.fleetOperator.rawValue,
                                   summary: PairingScope.fleetOperator.summary)],
            expiresAt: Date().addingTimeInterval(600),
            tlsFingerprint: link.pin ?? SPKIFingerprint(sha256Digest: Data(repeating: 3, count: 32))!,
            approvalRequired: link.requiresApproval,
            protocols: link.requiresApproval ? [1, 2] : [])
    }

    func requestApproval(
        _ link: PairingInvitationLink, deviceName: String, deviceModel: String,
        clientSecret: PairingClientSecret, expecting: PairingPreview
    ) async throws(PairingFailure) -> PairingApprovalRequest {
        guard link.requiresApproval else { throw .approvalNotSupported }
        try? await Task.sleep(for: .milliseconds(300))
        let conflict: Bool = lock.withLock {
            if let existing = requestSecrets[link.invitationID], existing != clientSecret.rawValue { return true }
            requestSecrets[link.invitationID] = clientSecret.rawValue
            if requestedAt[link.invitationID] == nil { requestedAt[link.invitationID] = Date() }
            return false
        }
        if conflict { throw .alreadyUsed }
        return PairingApprovalRequest(
            id: "req" + link.invitationID, matchCode: Self.matchCode,
            expiresAt: Date().addingTimeInterval(600), pollInterval: 1,
            gateway: expecting.gateway, scopes: expecting.access.map(\.scope),
            tlsFingerprint: expecting.tlsFingerprint)
    }

    func pollApproval(
        _ request: PairingApprovalRequest, clientSecret: PairingClientSecret
    ) async throws(PairingFailure) -> PairingApprovalStatus {
        let invitation = String(request.id.dropFirst(3))
        let (secret, started) = lock.withLock { (requestSecrets[invitation], requestedAt[invitation]) }
        guard secret == clientSecret.rawValue, let started else { throw .invalidRequest }
        if invitation.hasPrefix("pending") { return .pending }
        guard let approveAfter, Date().timeIntervalSince(started) >= approveAfter else { return .pending }
        if invitation.hasPrefix("denied") { return .denied }
        if invitation.hasPrefix("lapsed") { return .expired }
        return .approved(PairingGrant(
            gateway: request.gateway, deviceID: String(repeating: "0123abcd", count: 4),
            credential: PairingDeviceCredential("hfd1." + String(repeating: "0123abcd", count: 4) + "." + String(repeating: "S", count: 43)),
            tlsFingerprint: request.tlsFingerprint))
    }

    func redeem(
        _ link: PairingInvitationLink, deviceName: String, expecting: PairingPreview
    ) async throws(PairingFailure) -> PairingGrant {
        let inserted: Bool = lock.withLock { redeemed.insert(link.invitationID).inserted }
        guard inserted else { throw .alreadyUsed }
        return PairingGrant(
            gateway: expecting.gateway, deviceID: String(repeating: "0123abcd", count: 4),
            credential: PairingDeviceCredential("hfd1." + String(repeating: "0123abcd", count: 4) + "." + String(repeating: "S", count: 43)),
            tlsFingerprint: expecting.tlsFingerprint)
    }

    func revoke(origin: URL, credential: PairingDeviceCredential, expecting: SPKIFingerprint?) async -> PairingRevocationOutcome { .revoked }
}
#endif
