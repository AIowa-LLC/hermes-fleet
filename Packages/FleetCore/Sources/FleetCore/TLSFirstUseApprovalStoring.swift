import Foundation

/// User decision for the first secure connection to a gateway.
///
/// TOFU pinning is only useful when the first key is accepted intentionally.
/// The transport asks this seam synchronously from the URLSession trust
/// callback; the app records the decision only after the user has reviewed
/// the gateway endpoint and confirmed pairing in the UI.
public protocol TLSFirstUseApprovalStoring: Sendable {
    /// Approve first use of ONE specific key: the SPKI the user reviewed. There
    /// is deliberately no "approve whatever appears first" operation — a
    /// different presented key never consumes this approval.
    func approveFirstUse(for gatewayID: GatewayID, boundTo fingerprint: SPKIFingerprint) async throws
    func isFirstUseApproved(for gatewayID: GatewayID) async throws -> Bool
    func resetFirstUseApproval(for gatewayID: GatewayID) async throws
}

/// Synchronous half used by URLSession's server-trust challenge callback.
public protocol SynchronousTLSFirstUseApprovalStoring: Sendable {
    func syncIsFirstUseApproved(for gatewayID: GatewayID) throws -> Bool
    /// Record an approval bound to exactly one reviewed key.
    func syncApproveFirstUse(boundTo fingerprint: SPKIFingerprint, for gatewayID: GatewayID) throws
    func syncClearFirstUseApproval(for gatewayID: GatewayID) throws
    /// Atomically check AND consume the approval for the key presented right
    /// now. Returns true only when an approval exists bound to exactly
    /// `presented`; the approval is single-use and is removed on success. An
    /// approval bound to a different key is left in place.
    func syncConsumeFirstUseApproval(matching presented: SPKIFingerprint, for gatewayID: GatewayID) throws -> Bool
}
