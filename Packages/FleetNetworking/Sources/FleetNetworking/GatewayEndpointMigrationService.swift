import Foundation
import FleetCore

/// F2 (t_b678fb38) — one-time persisted-endpoint convergence runner.
///
/// Wraps `EndpointMigration` (the pure mapping) with the store round-trip:
/// loads all persisted gateway records, re-points every dead private-network
/// spelling onto the configured default endpoint, and writes back ONLY the
/// changed rows (upsert semantics). Runs inside `restorePersistedGateways()`
/// BEFORE the registry is rebuilt, so the app (and the UI) only ever sees the
/// converged endpoint.
///
/// The replacement endpoint arrives as DATA — the caller reads it from
/// configuration (launch environment / managed settings), never compiled
/// topology. A missing/invalid default endpoint means "no migration configured"
/// and is a no-op, not an error.
///
/// Idempotent: a second run finds every row already on the default endpoint
/// and writes nothing.
public struct GatewayEndpointMigrationService: Sendable {

    private let recordStore: any GatewayRecordStoring

    public init(recordStore: any GatewayRecordStoring) {
        self.recordStore = recordStore
    }

    /// Migrate persisted records onto `defaultEndpoint`. Returns the number
    /// of rows re-pointed (0 when nothing needed changing or no valid default
    /// was supplied). Non-migratable store failures propagate to the caller
    /// (restore already tolerates a broken store without bricking launch).
    public func migrateAll(defaultEndpoint: String) async throws -> Int {
        let records = try await recordStore.loadGatewayRecords()
        let migrated = EndpointMigration.migrateEndpoints(
            in: records,
            defaultEndpoint: defaultEndpoint
        )
        var changed = 0
        for (original, updated) in zip(records, migrated) where original != updated {
            try await recordStore.saveGatewayRecord(updated)
            changed += 1
        }
        return changed
    }
}
