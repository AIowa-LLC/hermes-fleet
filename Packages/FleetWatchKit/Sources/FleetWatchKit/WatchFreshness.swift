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

    public static func approvalsActionable(snapshotBuiltAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(snapshotBuiltAt) <= approvalActionableWindow
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
