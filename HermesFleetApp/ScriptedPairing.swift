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
/// It touches no network. Real wire behaviour is verified against genuine TLS servers in the
/// FleetNetworking tests; this exists only so the SwiftUI flow can be exercised without one.
final class ScriptedPairingService: GatewayPairing, @unchecked Sendable {
    private let lock = NSLock()
    private var offlineServed: Set<String> = []
    private var redeemed: Set<String> = []
    private let instance = String(repeating: "ab12cd34", count: 4)

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
            tlsFingerprint: SPKIFingerprint(sha256Digest: Data(repeating: 3, count: 32))!)
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

    func revoke(origin: URL, credential: PairingDeviceCredential) async -> PairingRevocationOutcome { .revoked }
}
#endif
