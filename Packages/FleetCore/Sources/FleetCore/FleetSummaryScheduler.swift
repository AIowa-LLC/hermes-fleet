import Foundation

/// FOS-4 (SPEC §17 polling/cost contract) — the ONE coordinator that owns
/// foreground roster observation. Lives in the app seam (injected into
/// FleetUI), never inside a row view.
///
/// Bounded settings (initial product values to verify under dogfood):
/// - Home entry triggers at most one due roster refresh per registered
///   gateway, with at most three gateways in flight per wave and a
///   10-second per-gateway observation deadline (enforced in
///   `FleetRosterService`, the seam this scheduler drives).
/// - Foreground automatic observation no more often than every 30 seconds
///   per gateway; explicit refreshes coalesce into the in-flight cycle.
/// - Failed sources retry after 30/60/120 then at most every 300 seconds;
///   backoff resets only after success or an explicit connection repair.
///   Manual Refresh requests one immediate coalesced attempt; navigation
///   alone never resets backoff.
/// - No automatic observation while locked or backgrounded (the caller stops
///   the scheduler; this type never polls on its own — it only ANSWERS
///   "what is due now").
public struct FleetSummaryScheduler: Sendable {
    /// Minimum per-gateway observation cadence while foregrounded.
    public let minInterval: TimeInterval
    /// Failure backoff steps; the last repeats (cap).
    public let backoffSteps: [TimeInterval]
    /// Injected clock (tests pass a fixed sequence).
    public let now: @Sendable () -> Date

    public init(
        minInterval: TimeInterval = 30,
        backoffSteps: [TimeInterval] = [30, 60, 120, 300],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.minInterval = minInterval
        self.backoffSteps = backoffSteps
        self.now = now
    }

    /// One gateway's observation bookkeeping (kept by the app seam).
    public struct SourceState: Equatable, Sendable {
        /// Last successful observation settle time.
        public var lastSuccessAt: Date?
        /// Last failed attempt time (drives backoff).
        public var lastFailureAt: Date?
        /// Consecutive failures (indexes the backoff ladder).
        public var consecutiveFailures: Int

        public init(lastSuccessAt: Date? = nil, lastFailureAt: Date? = nil, consecutiveFailures: Int = 0) {
            self.lastSuccessAt = lastSuccessAt
            self.lastFailureAt = lastFailureAt
            self.consecutiveFailures = consecutiveFailures
        }

        /// The never-observed state (due immediately).
        public static let empty = SourceState()
    }

    /// Whether `gateway` is due for an observation at `now`.
    public func isDue(_ state: SourceState) -> Bool {
        // Never observed → due immediately (Home entry).
        guard state.lastSuccessAt != nil || state.lastFailureAt != nil else {
            return true
        }
        if state.consecutiveFailures > 0 {
            let delay = backoffDelay(failures: state.consecutiveFailures)
            let anchor = state.lastFailureAt ?? state.lastSuccessAt ?? now()
            return now().timeIntervalSince(anchor) >= delay
        }
        let anchor = state.lastSuccessAt ?? now()
        return now().timeIntervalSince(anchor) >= minInterval
    }

    /// The effective delay after `failures` consecutive failures
    /// (30/60/120/300; the cap repeats).
    public func backoffDelay(failures: Int) -> TimeInterval {
        guard !backoffSteps.isEmpty else { return minInterval }
        guard failures > 0 else { return minInterval }
        let idx = min(failures, backoffSteps.count) - 1
        return backoffSteps[idx]
    }

    /// Record a successful observation.
    public func onSuccess(_ state: SourceState) -> SourceState {
        var next = state
        next.lastSuccessAt = now()
        next.lastFailureAt = nil
        next.consecutiveFailures = 0
        return next
    }

    /// Record a failed observation (climb the ladder; reset only via
    /// success or explicit repair).
    public func onFailure(_ state: SourceState) -> SourceState {
        var next = state
        next.lastFailureAt = now()
        next.consecutiveFailures = state.consecutiveFailures + 1
        return next
    }
}
