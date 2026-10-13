import Foundation

/// Per-gateway reconnect backoff that survives short-lived connections.
///
/// A connection only counts as recovered after it has stayed online for
/// `healthyDuration` without a failure in between. Merely being sampled
/// `.online` once does not reset the budget: a peer that accepts a connection
/// and then sends a rejected (e.g. oversized) frame every second would
/// otherwise regain the base reconnect delay forever. Failures restart the
/// stability clock. The attempt budget is bounded (`maxAttempts`); once spent
/// the gateway stays failed until an explicit reset (foreground restore,
/// manual reconnect, a deliberate endpoint change).
///
/// Pure value type: time is passed in, so tests are exact.
public struct ReconnectBackoff: Sendable, Equatable {
    public struct Policy: Sendable, Equatable {
        public var baseDelay: TimeInterval
        public var maxDelay: TimeInterval
        public var maxAttempts: Int
        /// Continuous online time that proves the gateway healthy again.
        public var healthyDuration: TimeInterval

        public init(baseDelay: TimeInterval = 2, maxDelay: TimeInterval = 30,
                    maxAttempts: Int = 8, healthyDuration: TimeInterval = 60) {
            self.baseDelay = baseDelay
            self.maxDelay = maxDelay
            self.maxAttempts = maxAttempts
            self.healthyDuration = healthyDuration
        }
    }

    public let policy: Policy
    public private(set) var attempts = 0
    private var onlineSince: TimeInterval?

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// A sample saw the connection online. Starts the stability clock on the
    /// first sample; clears the budget only once it has run `healthyDuration`.
    public mutating func observeOnline(at now: TimeInterval) {
        let since = onlineSince ?? now
        onlineSince = since
        if now - since >= policy.healthyDuration { attempts = 0 }
    }

    /// The connection failed or dropped: the stability clock restarts, the
    /// attempt count is kept.
    public mutating func observeFailure() {
        onlineSince = nil
    }

    /// Spend one attempt. `nil` when the budget is exhausted.
    public mutating func nextDelay() -> TimeInterval? {
        guard attempts < policy.maxAttempts else { return nil }
        attempts += 1
        return min(policy.maxDelay, policy.baseDelay * pow(2, Double(attempts - 1)))
    }

    /// Explicit reset: foreground restore, manual reconnect, endpoint change,
    /// removal, cancellation.
    public mutating func reset() {
        attempts = 0
        onlineSince = nil
    }
}
