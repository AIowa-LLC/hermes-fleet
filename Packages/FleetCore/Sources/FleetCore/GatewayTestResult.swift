import Foundation

/// Outcome of a `test connection` operation (spec §15.2 "test connection").
///
/// Reachable/unreachable is the spec §31 Gateway acceptance ("app can
/// determine reachable/unreachable state"): the status is the classified
/// result of the probe, and the capability surface is what the gateway
/// advertised on a successful handshake. `serverIdentity` is the gateway's
/// stable identity string when it reports one.
public struct GatewayTestResult: Hashable, Sendable {
    /// Classified reachable/unreachable state of the probe (spec §13).
    public let status: GatewayStatus
    /// Capability surface advertised by the gateway on success (spec §12).
    public let capabilities: GatewayCapabilities
    /// Stable server identity reported by the gateway, if any.
    public let serverIdentity: String?

    public init(
        status: GatewayStatus,
        capabilities: GatewayCapabilities = GatewayCapabilities(),
        serverIdentity: String? = nil
    ) {
        self.status = status
        self.capabilities = capabilities
        self.serverIdentity = serverIdentity
    }
}
