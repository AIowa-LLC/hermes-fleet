import Foundation

/// The non-secret persistence seam for connection-health stats (H2).
///
/// Mirrors the `CacheStoring` seam pattern: FleetCore owns the protocol, the
/// concrete SwiftData-backed implementation lives in FleetPersistence
/// (`SwiftDataCacheStore`), and the app composition root injects it — so the
/// accumulator depends on the seam, never on SwiftData.
///
/// Structural no-secret invariant: `GatewayHealthStats` holds only counts,
/// timestamps, and classified reasons — never credentials or tokens.
public protocol HealthStatsStoring: Sendable {
    /// Store (replace) the health snapshot for a gateway.
    func saveHealthStats(_ stats: GatewayHealthStats, for gatewayID: GatewayID) async throws
    /// Load the stored health snapshot for a gateway, or `nil` when none.
    func loadHealthStats(for gatewayID: GatewayID) async throws -> GatewayHealthStats?
    /// Delete the stored health snapshot for a gateway (gateway removal).
    func deleteHealthStats(for gatewayID: GatewayID) async throws
}
