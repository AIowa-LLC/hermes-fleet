import Foundation

/// Per-gateway connection-health snapshot (H2 Connection health dashboard).
///
/// Accumulated by `GatewayHealthStatsAccumulator` from the transport's
/// `ConnectionHealthEvent` stream, and persisted via the `HealthStatsStoring`
/// seam (concrete: `SwiftDataCacheStore` in FleetPersistence) so the dashboard
/// survives app restart. **Non-secret by construction**: every field is a
/// count, timestamp, or classified reason — no credentials, tokens, or raw
/// ticket material ever appears here (spec §29 / synthesis §12).
public struct GatewayHealthStats: Codable, Sendable, Equatable {
    /// Last known connection status, derived from the event stream
    /// (`.connecting` on connectStarted, `.online` on connected,
    /// `.offline` on disconnected). The live dashboard prefers the runtime's
    /// observable connection state; this is the persisted "last known".
    public var currentState: GatewayStatus

    /// When the accumulator first observed this gateway (stats window start).
    public var firstObservedAt: Date
    /// Wall-clock timestamp of the most recent state transition. Frozen at
    /// rehydrate time — the app never back-fills time it did not observe.
    public var lastTransitionAt: Date

    /// Accumulated settled time in the connected bucket (milliseconds).
    public var connectedMilliseconds: Int64
    /// Accumulated settled time in the disconnected bucket (milliseconds).
    /// Connecting intervals are excluded from both — they are ambiguous.
    public var disconnectedMilliseconds: Int64

    /// Number of times the connection was re-established after the first
    /// (first connect = 0; every subsequent `.connected` = +1). Survives
    /// restart.
    public var reconnectCount: Int

    /// Human-readable reason the connection last ended (non-secret
    /// `DisconnectReason.debugDescription`), nil until the first disconnect.
    public var lastDisconnectReason: String?
    /// When that disconnect happened (nil until the first disconnect).
    public var lastDisconnectAt: Date?

    /// Most recent heartbeat ping RTT (milliseconds); nil before the first
    /// pong is observed.
    public var lastPingRTTMilliseconds: Double?
    /// Running average heartbeat ping RTT (milliseconds).
    public var averagePingRTTMilliseconds: Double?
    /// Number of ping RTT samples observed (0 before the first pong).
    public var pingSampleCount: Int

    public init(
        currentState: GatewayStatus = .offline,
        firstObservedAt: Date = .distantPast,
        lastTransitionAt: Date = .distantPast,
        connectedMilliseconds: Int64 = 0,
        disconnectedMilliseconds: Int64 = 0,
        reconnectCount: Int = 0,
        lastDisconnectReason: String? = nil,
        lastDisconnectAt: Date? = nil,
        lastPingRTTMilliseconds: Double? = nil,
        averagePingRTTMilliseconds: Double? = nil,
        pingSampleCount: Int = 0
    ) {
        self.currentState = currentState
        self.firstObservedAt = firstObservedAt
        self.lastTransitionAt = lastTransitionAt
        self.connectedMilliseconds = connectedMilliseconds
        self.disconnectedMilliseconds = disconnectedMilliseconds
        self.reconnectCount = reconnectCount
        self.lastDisconnectReason = lastDisconnectReason
        self.lastDisconnectAt = lastDisconnectAt
        self.lastPingRTTMilliseconds = lastPingRTTMilliseconds
        self.averagePingRTTMilliseconds = averagePingRTTMilliseconds
        self.pingSampleCount = pingSampleCount
    }

    /// Uptime percentage over the accumulated settled-time window:
    /// `connected / (connected + disconnected) * 100`. 0 when no time has been
    /// observed (fresh gateway, or a probe-only connection).
    public var uptimePercentage: Double {
        let total = connectedMilliseconds + disconnectedMilliseconds
        guard total > 0 else { return 0 }
        return Double(connectedMilliseconds) / Double(total) * 100
    }

    /// Whether any settled time (connected or disconnected) has been observed.
    /// The dashboard renders "no data yet" until this is true.
    public var hasObservations: Bool {
        connectedMilliseconds > 0 || disconnectedMilliseconds > 0
    }
}
