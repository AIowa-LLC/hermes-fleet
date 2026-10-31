import Foundation
import FleetCore

/// Bounded auto-recovery cadence for a failed gateway connection (spec §8.6
/// "other codes → reconnect + replay").
///
/// The runtime (AppEnvironment) samples each live connection's state at
/// `watchInterval`; a transient failure (ReconnectPolicy says `.reconnect`)
/// retries with exponential backoff — `baseDelay` doubling per attempt up to
/// `maxDelay` — for at most `maxAttempts` retries after the initial failed
/// attempt. When that fast budget is spent, a transient failure keeps being
/// probed every `steadyProbeInterval` while the app is foregrounded, so a
/// gateway that comes back reconnects unaided (#214). Injectable so tests
/// drive the loop at millisecond cadence.
public struct ConnectionRecoveryTiming: Sendable, Equatable {
    /// How often the per-gateway watch samples the transport state.
    public var watchInterval: TimeInterval
    /// First retry delay; doubles per attempt, capped at `maxDelay`.
    public var baseDelay: TimeInterval
    /// Retry delay ceiling.
    public var maxDelay: TimeInterval
    /// Retries AFTER the initial failed attempt.
    public var maxAttempts: Int
    /// Continuous online time after which the retry budget is restored. A
    /// connection that drops sooner keeps its backoff (see `ReconnectBackoff`).
    public var healthyDuration: TimeInterval
    /// Probe cadence for a transient failure after the fast budget is spent.
    public var steadyProbeInterval: TimeInterval

    public init(
        watchInterval: TimeInterval = 1,
        baseDelay: TimeInterval = 2,
        maxDelay: TimeInterval = 30,
        maxAttempts: Int = 8,
        healthyDuration: TimeInterval = 60,
        steadyProbeInterval: TimeInterval = 30
    ) {
        self.watchInterval = watchInterval
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
        self.healthyDuration = healthyDuration
        self.steadyProbeInterval = steadyProbeInterval
    }

    public var backoffPolicy: ReconnectBackoff.Policy {
        .init(baseDelay: baseDelay, maxDelay: maxDelay, maxAttempts: maxAttempts, healthyDuration: healthyDuration)
    }

    public static let standard = ConnectionRecoveryTiming()
}