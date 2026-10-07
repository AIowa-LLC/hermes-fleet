import Foundation

public enum WatchFreshness: Equatable, Sendable {
    case fresh
    /// Older than the fresh window but still shown, labelled with its age.
    case aging
    case stale
    /// No snapshot has ever arrived.
    case none
}

public enum WatchFreshnessPolicy {
    public static let freshWindow: TimeInterval = 90
    public static let staleAfter: TimeInterval = 10 * 60
    /// Approvals are only actionable when the snapshot is at most this old.
    public static let approvalActionableWindow: TimeInterval = 120

    public static func freshness(observedAt: Date?, now: Date) -> WatchFreshness {
        guard let observedAt else { return .none }
        let age = now.timeIntervalSince(observedAt)
        if age <= freshWindow { return .fresh }
        if age <= staleAfter { return .aging }
        return .stale
    }

    /// "now", "3m ago", "2h ago" — rounded down, never claims freshness.
    public static func ageLabel(observedAt: Date?, now: Date) -> String {
        guard let observedAt else { return "never observed" }
        let age = max(0, Int(now.timeIntervalSince(observedAt)))
        if age < 15 { return "just now" }
        if age < 60 { return "\(age)s ago" }
        if age < 3600 { return "\(age / 60)m ago" }
        if age < 86_400 { return "\(age / 3600)h ago" }
        return "\(age / 86_400)d ago"
    }

    /// Approvals are actionable only from the approval's OWN observation time.
    /// A newly built snapshot never refreshes it, and never-observed is never
    /// actionable.
    public static func approvalActionable(observedAt: Date?, now: Date) -> Bool {
        guard let observedAt else { return false }
        let age = now.timeIntervalSince(observedAt)
        return age >= -5 && age <= approvalActionableWindow
    }
}

/// How trustworthy one source of fleet data (roster, conversations, running
/// work, approvals) is right now. Tracked per source from the phone's actual
/// observation time, never from when the snapshot was assembled.
public enum WatchSourceState: Equatable, Sendable {
    /// Observed recently while its machine is reachable from the iPhone.
    case current
    /// Observed, but long enough ago that it may have changed.
    case stale
    /// Last observation exists but the machine is unreachable/not reporting
    /// from the iPhone now: cached data only, and it cannot be refreshed.
    case unavailable
    /// The iPhone has never observed this source.
    case neverObserved

    public var label: String {
        switch self {
        case .current: return "Current"
        case .stale: return "Stale"
        case .unavailable: return "Unavailable · cached"
        case .neverObserved: return "Never observed"
        }
    }
}

public enum WatchSourcePolicy {
    public static func state(observedAt: Date?, gatewayStatus: WatchGatewayStatus, now: Date) -> WatchSourceState {
        guard let observedAt else { return .neverObserved }
        switch gatewayStatus {
        case .offline, .notConnected, .authenticationRequired, .unsupported:
            return .unavailable
        case .online, .connecting, .degraded:
            return WatchFreshnessPolicy.freshness(observedAt: observedAt, now: now) == .fresh ? .current : .stale
        }
    }
}

/// What the Watch can honestly claim about its link to the iPhone.
public enum WatchLinkState: Equatable, Sendable {
    case reachable
    /// Paired and companion installed, but the phone app is not currently
    /// reachable (locked/backgrounded/out of range). Cached data only.
    case phoneUnreachable
    case notActivated
    case companionMissing
}
