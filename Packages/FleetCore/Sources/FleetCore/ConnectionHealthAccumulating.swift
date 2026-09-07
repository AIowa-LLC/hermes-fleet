import Foundation

/// The connection-health accumulator seam (H2 Connection health dashboard).
///
/// Lives in FleetCore so the app composition root and FleetUI depend on the
/// protocol — never on the concrete SwiftData-backed implementation — keeping
/// the M0 boundary intact (FleetUI must not import FleetNetworking or
/// FleetPersistence to render health).
public protocol ConnectionHealthAccumulating: Sendable {
    /// Record one transport health observation for a gateway.
    func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async
    /// The current health snapshot for every observed gateway.
    func snapshot() async -> [GatewayID: GatewayHealthStats]
    /// The current health snapshot for one gateway (nil when never observed).
    func stats(for gatewayID: GatewayID) async -> GatewayHealthStats?
    /// Restore persisted stats for the registered gateways (survives app
    /// restart) and resume accumulation from the persisted timeline. Never
    /// back-fills time the app did not observe (a killed app cannot claim
    /// uptime for the dead interval).
    func rehydrate(gatewayIDs: [GatewayID]) async
    /// Drop a gateway's accumulated + persisted stats (gateway removal).
    func forget(gatewayID: GatewayID) async
}
