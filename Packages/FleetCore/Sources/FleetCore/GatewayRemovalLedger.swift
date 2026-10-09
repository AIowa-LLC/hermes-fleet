import Foundation

/// Durable record of an explicit gateway removal that has started but may not
/// have finished (a "tombstone").
///
/// Removing a gateway touches several independent stores (the Keychain
/// credential, the TLS pin, the saved record). Without a durable marker, a
/// force-quit between those steps leaves the saved record behind and the
/// gateway reappears on the next launch with its credential already gone. The
/// ledger is written BEFORE any destructive step, consulted by launch restore
/// so a half-removed gateway is never revived, and cleared only when the
/// removal fully completed (or was rolled back after a reported failure) or
/// when the user deliberately adds the gateway again.
///
/// Holds gateway identifiers only; never a credential, endpoint or name.
public protocol GatewayRemovalLedgering: Sendable {
    /// Durably record that `id` is being removed. Must not return until the
    /// marker survives a process kill; throws when it cannot be persisted.
    func markRemoving(_ id: GatewayID) async throws
    /// Gateways with an unfinished or uncleared removal marker.
    func pendingRemovals() async throws -> Set<GatewayID>
    /// Forget the marker for `id`. A missing marker is a no-op.
    func clear(_ id: GatewayID) async throws
}

/// Process-lifetime ledger for tests and scripted graphs. Shared across
/// service instances in a test it models state that survives a "relaunch".
public actor InMemoryGatewayRemovalLedger: GatewayRemovalLedgering {
    private var pending: Set<GatewayID> = []
    private var failMarking = false

    public init() {}

    public func markRemoving(_ id: GatewayID) async throws {
        if failMarking { throw GatewayRemovalLedgerError.unavailable }
        pending.insert(id)
    }

    public func pendingRemovals() async throws -> Set<GatewayID> { pending }

    public func clear(_ id: GatewayID) async throws { pending.remove(id) }

    /// Test seam: make the next marks fail, as a full disk would.
    public func setFailMarking(_ fail: Bool) { failMarking = fail }
}

public enum GatewayRemovalLedgerError: Error, Sendable, Equatable {
    /// The ledger could not be read or written. Carries no payload: error
    /// text must never include paths or identifiers.
    case unavailable
}
