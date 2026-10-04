import Foundation

/// User decision for the first secure connection to a gateway.
///
/// TOFU pinning is only useful when the first key is accepted intentionally.
/// The transport asks this seam synchronously from the URLSession trust
/// callback; the app records the decision only after the user has reviewed
/// the gateway endpoint and confirmed pairing in the UI.
public protocol TLSFirstUseApprovalStoring: Sendable {
    func approveFirstUse(for gatewayID: GatewayID) async throws
    /// Approve first use of ONE specific key (the SPKI the user actually
    /// reviewed). A different presented key never consumes this approval.
    func approveFirstUse(for gatewayID: GatewayID, boundTo fingerprint: SPKIFingerprint) async throws
    func isFirstUseApproved(for gatewayID: GatewayID) async throws -> Bool
    func resetFirstUseApproval(for gatewayID: GatewayID) async throws
}

/// Synchronous half used by URLSession's server-trust challenge callback.
public protocol SynchronousTLSFirstUseApprovalStoring: Sendable {
    func syncIsFirstUseApproved(for gatewayID: GatewayID) throws -> Bool
    func syncSetFirstUseApproved(_ approved: Bool, for gatewayID: GatewayID) throws
    /// Record an approval bound to one reviewed key (`nil` = unbound intent).
    func syncSetFirstUseApproval(boundTo fingerprint: SPKIFingerprint?, for gatewayID: GatewayID) throws
    /// Atomically check AND consume the approval for the key presented right
    /// now. Returns true only when an approval exists and is unbound or bound
    /// to exactly `presented`; the approval is single-use and is removed on
    /// success. A key-bound approval for a different key is left in place.
    func syncConsumeFirstUseApproval(matching presented: SPKIFingerprint, for gatewayID: GatewayID) throws -> Bool
}
