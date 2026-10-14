import Foundation
import FleetCore

/// U4 (Gold Fleet) — pure presentation formatting for the Home dashboard.
///
/// Presentation-layer only: derived strings/initials over FleetCore models.
/// Unit-testable without a UI host (see `FleetDashboardFormattingTests`).
/// Nothing here fabricates data: absent inputs render honest placeholders
/// ("—", "—d —h", empty initials), never invented values.
public enum FleetDashboardFormatting {

    // MARK: Avatars

    /// Initials for a bot avatar square (e.g. "Researcher" → "R",
    /// "MacBook Bot" → "MB"). Only LETTERS count as initials — a name with
    /// no letters falls back to "?" (never an empty string; the square
    /// stays a stable size).
    public static func avatarInitials(from displayName: String) -> String {
        let words = displayName
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        let initials = words.prefix(2).compactMap { word in
            word.first(where: \.isLetter)
        }
        guard !initials.isEmpty else { return "?" }
        return initials.map(String.init).joined().uppercased()
    }

    // MARK: Continue rows (DEV14)

    /// Display labels for a Continue (resume) row. `title` is the
    /// conversation's own title; `subtitle` is "<bot> · <gateway>" (the view
    /// appends the relative time).
    public struct ContinueLabels: Equatable, Sendable {
        public let title: String
        public let subtitle: String
        /// False when `title` is the "Conversation with <bot>" fallback.
        public let hasRealTitle: Bool
    }

    /// Resolve a conversation's labels from real data only. Priority: the
    /// live listed session title, a title stored at record time, the listed
    /// session's sanitized preview, then "Conversation with <bot>". Never the
    /// profile slug, so two conversations with one bot are distinguishable by
    /// whatever the gateway actually called them.
    public static func continueLabels(
        session: SessionSummary?,
        storedSessionTitle: String?,
        botName: String,
        gatewayName: String
    ) -> ContinueLabels {
        let subtitle = "\(botName) · \(gatewayName)"
        let candidates: [String?] = [
            session?.title,
            storedSessionTitle,
            session.map { SessionPreviewText.humanReadable($0.preview) },
        ]
        for candidate in candidates {
            if let title = cleanedConversationTitle(candidate) {
                return ContinueLabels(title: title, subtitle: subtitle, hasRealTitle: true)
            }
        }
        return ContinueLabels(
            title: "Conversation with \(botName)", subtitle: subtitle, hasRealTitle: false)
    }

    /// One trimmed line, capped at 80 characters, or nil when blank.
    private static func cleanedConversationTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let firstLine = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard !firstLine.isEmpty else { return nil }
        return firstLine.count > 80 ? String(firstLine.prefix(79)) + "…" : firstLine
    }

    // MARK: Relative time

    /// Compact relative time for "last active" / activity timestamps
    /// (e.g. "3m ago", "2d ago"). `since`-injected for deterministic tests.
    /// A non-positive interval renders "now" (clock skew guard).
    public static func relativeTime(from date: Date, since now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date).rounded()))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    /// Last-active label for a bot from its latest known session.
    /// Real data only: a bot with no session knowledge renders "No sessions
    /// yet" — never a fabricated uptime.
    public static func lastActiveLabel(bot: FleetBot, now: Date = Date()) -> String {
        guard let startedAt = bot.latestSession?.startedAt, startedAt > 0 else {
            return "No sessions yet"
        }
        return relativeTime(from: Date(timeIntervalSince1970: startedAt), since: now)
    }

    // MARK: Connected fraction

    /// Connected-gateway fraction over the registered fleet as "c/t"
    /// (e.g. "2/3"). An empty fleet renders "—" (0/0 is not a fraction).
    public static func connectedFraction(gateways: [FleetGateway], connected: (FleetGateway) -> Bool) -> String {
        guard !gateways.isEmpty else { return "—" }
        let count = gateways.filter(connected).count
        return "\(count)/\(gateways.count)"
    }

    // MARK: Fleet health

    /// Real fleet connectivity state for tint/stat derivation. An empty or
    /// never-connected fleet is `.none` — the UI renders an honest gray
    /// offline stat, never a fabricated "100%".
    public enum FleetConnectivity: Equatable {
        case empty
        case offline
        case connecting
        case online(connected: Int, total: Int)
    }

    /// Classify the fleet from per-gateway observable connection states.
    public static func connectivity(
        gateways: [FleetGateway],
        state: (FleetGateway) -> GatewayConnectionState?
    ) -> FleetConnectivity {
        guard !gateways.isEmpty else { return .empty }
        let states = gateways.map { state($0) ?? .idle }
        let connected = states.filter { $0 == .connected }.count
        if connected > 0 { return .online(connected: connected, total: gateways.count) }
        if states.contains(.connecting) { return .connecting }
        return .offline
    }

    // MARK: Recent activity timeline

    /// One real, timestamped activity event for the dashboard timeline,
    /// derived from the H2 accumulated connection-health stats. Nothing
    /// fabricated: every case maps to a genuinely observed signal.
    public struct ActivityEntry: Identifiable, Equatable, Sendable {
        public let id: String
        public let gatewayName: String
        public let icon: String
        public let text: String
        public let at: Date?

        init(id: String, gatewayName: String, icon: String, text: String, at: Date?) {
            self.id = id
            self.gatewayName = gatewayName
            self.icon = icon
            self.text = text
            self.at = at
        }
    }

    /// Build the recent-activity timeline entries for the registered fleet,
    /// newest first. Reads only the accumulated `GatewayHealthStats` (real
    /// observed reconnects / disconnects / connection time). A gateway with
    /// no observed stats contributes nothing (no zeroed-stat noise), and an
    /// unobserved fleet yields an empty array — the honest empty state.
    public static func activityEntries(
        gateways: [FleetGateway],
        stats: [GatewayID: GatewayHealthStats]
    ) -> [ActivityEntry] {
        var entries: [ActivityEntry] = []
        for gateway in gateways {
            guard let s = stats[gateway.id] else { continue }
            if s.reconnectCount > 0 {
                entries.append(
                    ActivityEntry(
                        id: "\(gateway.id.rawValue)#reconnects",
                        gatewayName: gateway.displayName,
                        icon: "arrow.triangle.2.circlepath",
                        text: "\(gateway.displayName) reconnected \(s.reconnectCount)×",
                        at: nil
                    )
                )
            }
            if let at = s.lastDisconnectAt {
                entries.append(
                    ActivityEntry(
                        id: "\(gateway.id.rawValue)#last-disconnect",
                        gatewayName: gateway.displayName,
                        icon: "wifi.slash",
                        text: "\(gateway.displayName) disconnected — \(s.lastDisconnectReason ?? "reason unknown")",
                        at: at
                    )
                )
            }
            if s.connectedMilliseconds > 0 {
                entries.append(
                    ActivityEntry(
                        id: "\(gateway.id.rawValue)#connected-time",
                        gatewayName: gateway.displayName,
                        icon: "bolt.horizontal",
                        text: "\(gateway.displayName) connected \(durationLabel(milliseconds: s.connectedMilliseconds))",
                        at: nil
                    )
                )
            }
        }
        // Newest first where a timestamp exists; untimed entries after.
        return entries.sorted { a, b in
            switch (a.at, b.at) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.id < b.id
            }
        }
    }

    /// Compact duration from accumulated milliseconds ("3h 12m" / "45m").
    public static func durationLabel(milliseconds: Int64) -> String {
        let totalMinutes = Int(milliseconds / 60_000)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
