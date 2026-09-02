import Foundation

/// Tiered heartbeat-freshness liveness windows (mirrors the Hermex #227
/// `ChatStreamCoordinatorTiming` pattern). The server heartbeat cadence is
/// ~5s, so a transport that received ANY valid frame (heartbeat pong or
/// payload) within `transportFreshInterval` is PROVABLY alive — status polls
/// are skipped and no reconnect may fire. Silence past `reconnectInterval`
/// means the transport is dead and the tiered escalation ends in a reconnect,
/// extended to `runningToolReconnectInterval` while a tool call is mid-flight
/// (long thinking/tool turns must not trigger spurious reconnects).
///
/// Single source of truth for these knobs so they stay tunable and
/// self-documenting; the transport's heartbeat loop and the view model's
/// status watcher both derive their behavior from one instance.
public struct ConnectionLivenessTiming: Sendable, Equatable {
    /// Cadence of the active liveness check while a connection is open: the
    /// transport evaluates time-since-last-frame at least this often (5s).
    public let checkingInterval: TimeInterval
    /// Transport quieter than this is treated as provably alive; must sit
    /// above the server's ~5s heartbeat cadence and below
    /// `reconnectInterval` (Hermex #227: 12s).
    public let transportFreshInterval: TimeInterval
    /// Silence at/after this reconnects (18s).
    public let reconnectInterval: TimeInterval
    /// Reconnect window extended while a tool call is mid-flight (25s).
    public let runningToolReconnectInterval: TimeInterval

    public init(
        checkingInterval: TimeInterval = 5,
        transportFreshInterval: TimeInterval = 12,
        reconnectInterval: TimeInterval = 18,
        runningToolReconnectInterval: TimeInterval = 25
    ) {
        self.checkingInterval = checkingInterval
        self.transportFreshInterval = transportFreshInterval
        self.reconnectInterval = reconnectInterval
        self.runningToolReconnectInterval = runningToolReconnectInterval
    }

    public static let standard = ConnectionLivenessTiming()
}

/// One liveness verdict derived from time-since-last-frame, folding
/// heartbeat freshness and the (unchanged, P1-4) malformed-frame detection
/// into a single evaluation instead of competing mechanisms.
public enum ConnectionLivenessTier: Sendable, Hashable {
    /// Last valid frame < `transportFreshInterval` ago — provably alive.
    /// Status polls are skipped; no reconnect may fire.
    case fresh
    /// Silence past the fresh window but under the reconnect window — the
    /// escalation path is active (status polling / active liveness check).
    case checkDue
    /// Silence at/ past the (tool-extended) reconnect window — the transport
    /// is dead; teardown + reconnect within the tiered window.
    case stale
}

/// Heartbeat-freshness snapshot for one streaming connection: when the last
/// VALID protocol frame (heartbeat pong or payload event — junk never
/// refreshes this, P1-4) was received. Consumers derive the tier at read
/// time, so the snapshot never goes stale itself.
public struct ConnectionLivenessSnapshot: Sendable, Equatable {
    /// Instant the last valid inbound frame arrived (nil-bearing carriers
    /// use Optional; the snapshot itself is only non-nil while connected).
    public let lastFrameReceivedAt: ContinuousClock.Instant

    public init(lastFrameReceivedAt: ContinuousClock.Instant) {
        self.lastFrameReceivedAt = lastFrameReceivedAt
    }

    /// Seconds between `lastFrameReceivedAt` and `now`.
    public func secondsSinceLastFrame(now: ContinuousClock.Instant = .now) -> TimeInterval {
        let elapsed = now - lastFrameReceivedAt
        return max(0, TimeInterval(elapsed.components.seconds)
            + TimeInterval(elapsed.components.attoseconds) / 1_000_000_000_000_000_000)
    }

    /// The tiered liveness verdict for this snapshot.
    public func tier(
        now: ContinuousClock.Instant = .now,
        toolInFlight: Bool = false,
        timing: ConnectionLivenessTiming = .standard
    ) -> ConnectionLivenessTier {
        let silence = secondsSinceLastFrame(now: now)
        if silence < timing.transportFreshInterval {
            return .fresh
        }
        let reconnectAfter = toolInFlight
            ? timing.runningToolReconnectInterval
            : timing.reconnectInterval
        return silence >= reconnectAfter ? .stale : .checkDue
    }
}
