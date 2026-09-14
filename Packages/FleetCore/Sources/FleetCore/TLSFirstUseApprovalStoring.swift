import Foundation

/// User decision for the first secure connection to a gateway.
///
/// TOFU pinning is only useful when the first key is accepted intentionally.
/// The transport asks this seam synchronously from the URLSession trust
/// callback; the app records the decision only after the user has reviewed
/// the gateway endpoint and confirmed pairing in the UI.
public protocol TLSFirstUseApprovalStoring: Sendable {
    func approveFirstUse(for gatewayID: GatewayID) async throws
    func isFirstUseApproved(for gatewayID: GatewayID) async throws -> Bool
    func resetFirstUseApproval(for gatewayID: GatewayID) async throws
}

/// Synchronous half used by URLSession's server-trust challenge callback.
public protocol SynchronousTLSFirstUseApprovalStoring: Sendable {
    func syncIsFirstUseApproved(for gatewayID: GatewayID) throws -> Bool
    func syncSetFirstUseApproved(_ approved: Bool, for gatewayID: GatewayID) throws
}
