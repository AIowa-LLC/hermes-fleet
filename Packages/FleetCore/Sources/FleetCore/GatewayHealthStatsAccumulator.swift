import Foundation

/// The connection-health accumulator (H2 Connection health dashboard).
///
/// A pure-domain actor in FleetCore: consumes the transport's
/// `ConnectionHealthEvent` stream (fed by the app composition root — the only
/// place FleetNetworking is imported), computes per-gateway uptime / reconnect
/// count / last-disconnect-reason / ping RTT, and persists non-secret
/// snapshots through the `HealthStatsStoring` seam so the dashboard survives
/// app restart.
///
/// Timeline semantics:
/// - Settled time is bucketed as connected or disconnected. Connecting
///   intervals are excluded from both buckets (ambiguous by design).
/// - Uptime % = connected / (connected + disconnected) over the accumulated
///   window, since `firstObservedAt`.
/// - On `rehydrate` the timeline is frozen at the persisted `lastTransitionAt`
///   (which becomes now): a killed app never claims uptime for the interval it
///   was not running.
/// - `reconnectCount` counts every `.connected` after the first (first
///   connect = 0; re-establishments = +1). Survives restart.
///
/// A clock is injected (`now`) so the deterministic test suite can advance
/// time without real sleeps.
public actor GatewayHealthStatsAccumulator: ConnectionHealthAccumulating {

    private enum Phase: Sendable {
        case idle
        case connecting
        case connected
        case disconnected
    }

    private struct Entry {
        var stats: GatewayHealthStats
        var phase: Phase = .idle
        var connectedSince: Date?
        var disconnectedSince: Date?
        var pingTotalMilliseconds: Double = 0
        /// Whether this gateway has EVER reached `.connected` (across
        /// restarts, via rehydrate). Drives reconnect counting: the first
        /// `.connected` is 0, every re-establishment afterwards is +1. A
        /// failed initial handshake only ever puts time in the disconnected
        /// bucket — never sets this — so the next (real) first connect is
        /// not promoted to a reconnect.
        var hasConnectedOnce: Bool = false
    }

    private let store: any HealthStatsStoring
    private let now: @Sendable () -> Date
    private var entries: [GatewayID: Entry] = [:]

    public init(
        store: any HealthStatsStoring,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    // MARK: ConnectionHealthAccumulating

    public func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {
        var entry = entries[gatewayID] ?? Entry(stats: GatewayHealthStats())
        let timestamp = now()
        if entry.stats.firstObservedAt == .distantPast {
            entry.stats.firstObservedAt = timestamp
            entry.stats.lastTransitionAt = timestamp
        }

        switch event {
        case .connectStarted:
            applyConnectStarted(&entry, at: timestamp)
        case .connected:
            applyConnected(&entry, at: timestamp)
        case .disconnected(let reason):
            applyDisconnected(&entry, reason: reason, at: timestamp)
        case .pingRTT(let milliseconds):
            applyPingRTT(&entry, milliseconds: milliseconds, at: timestamp)
        }

        entries[gatewayID] = entry
        await persist(entry.stats, for: gatewayID)
    }

    public func snapshot() async -> [GatewayID: GatewayHealthStats] {
        entries.mapValues { $0.stats }
    }

    public func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? {
        entries[gatewayID]?.stats
    }

    public func rehydrate(gatewayIDs: [GatewayID]) async {
        let timestamp = now()
        for id in gatewayIDs {
            // A live entry always wins: rehydrate only restores gateways this
            // session has NOT observed yet (e.g. a re-added gateway after an
            // app restart). Never clobber an accumulating connection.
            guard entries[id] == nil else { continue }
            guard let stored = try? await store.loadHealthStats(for: id) else { continue }
            var restored = stored
            // Freeze the timeline at rehydrate: the app was not observing
            // while dead, so neither bucket grows for that interval.
            restored.lastTransitionAt = timestamp
            entries[id] = Entry(
                stats: restored,
                phase: .disconnected,
                connectedSince: nil,
                disconnectedSince: timestamp,
                // Derive "has ever connected" from the persisted snapshot.
                // `.online` covers a gateway killed mid-connection whose
                // interval was never closed, so connectedMilliseconds is 0
                // but the gateway HAD reached .connected before dying.
                hasConnectedOnce: restored.connectedMilliseconds > 0
                    || restored.reconnectCount > 0
                    || restored.currentState == .online
            )
        }
    }

    public func forget(gatewayID: GatewayID) async {
        entries[gatewayID] = nil
        try? await store.deleteHealthStats(for: gatewayID)
    }

    // MARK: transitions

    private func applyConnectStarted(_ entry: inout Entry, at timestamp: Date) {
        switch entry.phase {
        case .idle:
            entry.phase = .connecting
            entry.stats.lastTransitionAt = timestamp
        case .disconnected:
            closeDisconnectedInterval(&entry, at: timestamp)
            entry.phase = .connecting
            entry.stats.lastTransitionAt = timestamp
        case .connecting, .connected:
            break // already in flight / already connected: no-op
        }
    }

    private func applyConnected(_ entry: inout Entry, at timestamp: Date) {
        switch entry.phase {
        case .idle:
            // Synthetic: a `.connected` with no prior `.connectStarted`.
            beginConnectedInterval(&entry, at: timestamp)
        case .connecting:
            beginConnectedInterval(&entry, at: timestamp)
        case .disconnected:
            closeDisconnectedInterval(&entry, at: timestamp)
            beginConnectedInterval(&entry, at: timestamp)
        case .connected:
            break // idempotent — a repeated .connected is a no-op
        }
    }

    private func beginConnectedInterval(_ entry: inout Entry, at timestamp: Date) {
        // Reconnect counting: the first connected event is the initial
        // connect (0); every re-establishment afterwards is +1. Keyed off
        // "has ever reached .connected", NOT settled time in either bucket:
        // a failed first handshake (gateway unreachable/asleep) puts time in
        // the disconnected bucket without ever establishing a connection, so
        // the subsequent first success must stay 0.
        if entry.hasConnectedOnce {
            entry.stats.reconnectCount += 1
        }
        entry.hasConnectedOnce = true
        entry.phase = .connected
        entry.connectedSince = timestamp
        entry.stats.lastTransitionAt = timestamp
        entry.stats.currentState = .online
    }

    private func applyDisconnected(_ entry: inout Entry, reason: String, at timestamp: Date) {
        switch entry.phase {
        case .connected:
            closeConnectedInterval(&entry, at: timestamp)
            beginDisconnectedInterval(&entry, at: timestamp)
        case .connecting:
            // A connect attempt ended without ever becoming connected.
            beginDisconnectedInterval(&entry, at: timestamp)
        case .idle:
            beginDisconnectedInterval(&entry, at: timestamp)
        case .disconnected:
            break // already down: only refresh the reason (no double counting)
        }
        entry.stats.lastDisconnectReason = reason
        entry.stats.lastDisconnectAt = timestamp
    }

    private func beginDisconnectedInterval(_ entry: inout Entry, at timestamp: Date) {
        entry.phase = .disconnected
        entry.disconnectedSince = timestamp
        entry.stats.lastTransitionAt = timestamp
        entry.stats.currentState = .offline
    }

    private func closeConnectedInterval(_ entry: inout Entry, at timestamp: Date) {
        guard let since = entry.connectedSince else { return }
        entry.stats.connectedMilliseconds += Self.elapsedMilliseconds(since, timestamp)
        entry.connectedSince = nil
    }

    private func closeDisconnectedInterval(_ entry: inout Entry, at timestamp: Date) {
        guard let since = entry.disconnectedSince else { return }
        entry.stats.disconnectedMilliseconds += Self.elapsedMilliseconds(since, timestamp)
        entry.disconnectedSince = nil
    }

    private func applyPingRTT(_ entry: inout Entry, milliseconds: Double, at timestamp: Date) {
        guard milliseconds >= 0 else { return }
        entry.pingTotalMilliseconds += milliseconds
        entry.stats.pingSampleCount += 1
        entry.stats.lastPingRTTMilliseconds = milliseconds
        entry.stats.averagePingRTTMilliseconds =
            entry.pingTotalMilliseconds / Double(entry.stats.pingSampleCount)
        entry.stats.lastTransitionAt = timestamp
    }

    // MARK: persistence

    private func persist(_ stats: GatewayHealthStats, for gatewayID: GatewayID) async {
        try? await store.saveHealthStats(stats, for: gatewayID)
    }

    static func elapsedMilliseconds(_ from: Date, _ to: Date) -> Int64 {
        let delta = max(0, to.timeIntervalSince(from))
        return Int64((delta * 1000).rounded())
    }
}
