import Foundation

/// Bounded auto-recovery cadence for a failed gateway connection (spec §8.6
/// "other codes → reconnect + replay").
///
/// The runtime (AppEnvironment) samples each live connection's state at
/// `watchInterval`; a transient failure (ReconnectPolicy says `.reconnect`)
/// retries with exponential backoff — `baseDelay` doubling per attempt up to
/// `maxDelay` — for at most `maxAttempts` retries after the initial failed
/// attempt. When the budget is spent the gateway stays failed until a
/// foreground restore or a manual retry. Injectable so tests drive the loop
/// at millisecond cadence.
public struct ConnectionRecoveryTiming: Sendable, Equatable {
    /// How often the per-gateway watch samples the transport state.
    public var watchInterval: TimeInterval
    /// First retry delay; doubles per attempt, capped at `maxDelay`.
    public var baseDelay: TimeInterval
    /// Retry delay ceiling.
    public var maxDelay: TimeInterval
    /// Retries AFTER the initial failed attempt.
    public var maxAttempts: Int

    public init(
        watchInterval: TimeInterval = 1,
        baseDelay: TimeInterval = 2,
        maxDelay: TimeInterval = 30,
        maxAttempts: Int = 8
    ) {
        self.watchInterval = watchInterval
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    public static let standard = ConnectionRecoveryTiming()
}