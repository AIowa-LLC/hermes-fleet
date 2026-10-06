import Foundation

/// Rate-limits automatic history recovery after an `EventGap`.
///
/// A hostile or broken gateway can overflow buffers again and again. Without a
/// governor each overflow would trigger a history refetch: a retry storm. The
/// governor allows a bounded number of recoveries per rolling window, spaces
/// them with exponential backoff, and past the budget reports `.suppressed`
/// so the UI shows a persistent "history may be incomplete" state instead of
/// retrying forever. Pure value type: time is passed in, so tests are exact.
public struct GapRecoveryGovernor: Sendable, Equatable {
    public struct Policy: Sendable, Equatable {
        /// Delay after the first recovery before another may start.
        public var baseInterval: TimeInterval
        /// Backoff ceiling.
        public var maxInterval: TimeInterval
        /// Recoveries allowed within `window`.
        public var maxRecoveriesPerWindow: Int
        public var window: TimeInterval

        public init(baseInterval: TimeInterval = 2, maxInterval: TimeInterval = 60,
                    maxRecoveriesPerWindow: Int = 4, window: TimeInterval = 120) {
            self.baseInterval = baseInterval
            self.maxInterval = maxInterval
            self.maxRecoveriesPerWindow = maxRecoveriesPerWindow
            self.window = window
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Start a recovery now (it has been counted).
        case recoverNow
        /// Too soon: run ONE coalesced recovery at this time.
        case deferUntil(TimeInterval)
        /// Budget exhausted for this window; surface "incomplete" and stop.
        /// A later request may succeed once old attempts age out of the window.
        case suppressed(retryAfter: TimeInterval)
    }

    public let policy: Policy
    private var attempts: [TimeInterval] = []

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// Number of recoveries currently counted in the window.
    public func attemptsInWindow(at now: TimeInterval) -> Int {
        attempts.filter { now - $0 < policy.window }.count
    }

    public mutating func request(at now: TimeInterval) -> Decision {
        attempts.removeAll { now - $0 >= policy.window }
        guard attempts.count < policy.maxRecoveriesPerWindow else {
            let oldest = attempts.first ?? now
            return .suppressed(retryAfter: max(0, oldest + policy.window - now))
        }
        if let last = attempts.last {
            let exponent = Double(max(0, attempts.count - 1))
            let backoff = min(policy.maxInterval, policy.baseInterval * pow(2, exponent))
            if now - last < backoff { return .deferUntil(last + backoff) }
        }
        attempts.append(now)
        return .recoverNow
    }

    /// Forget history after a long quiet period (a healthy stream).
    public mutating func reset() {
        attempts.removeAll()
    }
}
