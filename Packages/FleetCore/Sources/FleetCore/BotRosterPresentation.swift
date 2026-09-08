import Foundation

/// Presentation-layer roster ordering, search, hidden reveal, duplicate-name
/// disambiguation, and activity derivation for the native Bots roster.
///
/// Pure value logic over `[FleetBot]` + per-gateway presence — no SwiftUI,
/// no networking (design §1.1: provenance/presentation branching lives in
/// FleetCore, views consume normalized models).
///
/// Upstream ground truth (hermes-agent @ originally derived from 08b140d; re-verified against upstream main 966637323e, 2026-09-08):
/// - Activity recency = the FRESHER of canonical_session vs last_session
///   (`botActivitySession`, apps/desktop data.ts) — otherwise an all-day
///   Bot Chat bot reads "6d ago".
/// - Search matches title, slug, handle, gateway label, description, preview
///   (`filterBots`, data.ts) — case-insensitive substring.
/// - Hidden bots vanish by default and are revealed by explicit user toggle
///   (rendered dimmed); they remain mentionable/groupable — hiding is
///   presentation, never identity.
/// - Duplicate names are NEVER deduped: two visible bots sharing a display
///   title each get a "· <gateway>" disambiguation label.
public enum BotRosterPresentation {

    // MARK: - activity

    /// The fresher of the canonical "Bot Chat" session and the latest
    /// human-facing session, as a single activity anchor for ordering and
    /// "time ago" copy (upstream botActivitySession rule).
    public static func activityAnchor(for bot: FleetBot) -> ActivityAnchor {
        let canonical = bot.canonicalSession.map {
            ActivityAnchor(source: .canonicalBotChat, lastActive: $0.lastActive ?? $0.startedAt ?? 0,
                           preview: $0.preview, messageCount: $0.messageCount)
        }
        let latest = bot.latestSession.map {
            ActivityAnchor(source: .latestSession, lastActive: $0.startedAt, preview: $0.preview,
                           messageCount: $0.messageCount)
        }
        switch (canonical, latest) {
        case (nil, nil):
            return ActivityAnchor(source: .none, lastActive: 0, preview: nil, messageCount: nil)
        case (let c, nil):
            return c!
        case (nil, let l):
            return l!
        case (let c?, let l?):
            return c.lastActive >= l.lastActive ? c : l
        }
    }

    /// One bot's activity summary for ordering + preview rendering.
    public struct ActivityAnchor: Hashable, Sendable {
        public enum Source: String, Hashable, Sendable {
            /// The canonical "Bot Chat" registry row.
            case canonicalBotChat
            /// The newest human-facing session.
            case latestSession
            /// No session signal at all.
            case none
        }

        public let source: Source
        /// Epoch seconds; 0 when unknown.
        public let lastActive: Double
        public let preview: String?
        public let messageCount: Int?

        public init(source: Source, lastActive: Double, preview: String? = nil, messageCount: Int? = nil) {
            self.source = source
            self.lastActive = lastActive
            self.preview = preview
            self.messageCount = messageCount
        }
    }

    // MARK: - ordering

    /// Sort for one gateway's visible rows: pinned first, then activity
    /// recency (freshest first), then route id for determinism.
    public static func order(_ bots: [FleetBot]) -> [FleetBot] {
        bots.sorted { a, b in
            let pinnedA = a.botModeMetadata?.pinned == true
            let pinnedB = b.botModeMetadata?.pinned == true
            if pinnedA != pinnedB { return pinnedA }
            let ta = activityAnchor(for: a).lastActive
            let tb = activityAnchor(for: b).lastActive
            if ta != tb { return ta > tb }
            return a.route.id < b.route.id
        }
    }

    /// Whether a bot belongs in the "Active Now" strip: an authoritative
    /// live activity signal (never fabricated — `unknown`/`idle`/`offline`
    /// do not qualify) and not hidden.
    public static func isActiveNow(_ bot: FleetBot) -> Bool {
        guard bot.botModeMetadata?.hidden != true else { return false }
        switch bot.activity {
        case .working, .thinking, .usingTool, .waiting, .needsAttention:
            return true
        case .idle, .offline, .unknown:
            return false
        }
    }

    // MARK: - hidden

    /// Default roster rows: hidden bots excluded unless `revealingHidden`.
    /// When revealing, hidden bots are included (the view renders them
    /// dimmed) — never removed from identity.
    public static func visible(_ bots: [FleetBot], revealingHidden: Bool = false) -> [FleetBot] {
        bots.filter { bot in
            revealingHidden || bot.botModeMetadata?.hidden != true
        }
    }

    // MARK: - duplicate-name disambiguation

    /// Routes that need a "· <gateway>" disambiguation label: any display
    /// title (BotMeta.title → display_name → slug) shared by 2+ VISIBLE
    /// bots. Names are never deduped (design §3.2).
    public static func duplicateNameRoutes(
        _ bots: [FleetBot], gatewayLabel: (GatewayID) -> String
    ) -> [Route: String] {
        var byTitle: [String: [FleetBot]] = [:]
        for bot in bots {
            byTitle[displayTitle(for: bot), default: []].append(bot)
        }
        var labels: [Route: String] = [:]
        for group in byTitle.values where group.count > 1 {
            for bot in group {
                labels[bot.route] = gatewayLabel(bot.route.gatewayID)
            }
        }
        return labels
    }

    /// Display title: BotMeta.title → display_name → slug (never routes).
    public static func displayTitle(for bot: FleetBot) -> String {
        if let title = bot.botModeMetadata?.title, !title.isEmpty { return title }
        return bot.displayName
    }

    // MARK: - search

    /// RosterKindFilter parity (upstream 'all' | 'bots' | 'groups').
    public enum Scope: String, Hashable, Sendable, CaseIterable {
        case all
        case bots
        case groups
    }

    /// Case-insensitive substring search across title, slug, route id,
    /// description, and preview (filterBots parity; the caller adds gateway
    /// label via `extraText`).
    public static func matches(
        _ bot: FleetBot, query: String, gatewayLabel: String
    ) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let haystack = [
            displayTitle(for: bot),
            bot.profileSlug.rawValue,
            bot.route.id,
            "@" + bot.profileSlug.rawValue,
            bot.profileDescription ?? "",
            bot.botModeMetadata?.descriptionText ?? "",
            activityAnchor(for: bot).preview ?? "",
            gatewayLabel,
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(q)
    }

    /// Apply search + hidden rules in one pass (the view's row provider).
    public static func filter(
        _ bots: [FleetBot],
        query: String,
        gatewayLabel: (GatewayID) -> String,
        revealingHidden: Bool = false
    ) -> [FleetBot] {
        visible(bots, revealingHidden: revealingHidden)
            .filter { matches($0, query: query, gatewayLabel: gatewayLabel($0.route.gatewayID)) }
    }

    // MARK: - ghosts

    /// Owner status for a bot from the snapshot's gateway outcome: online
    /// when the owning gateway answered, offlineGhost when it failed
    /// (identity retained — cached rows stay visible, dimmed, writes gated),
    /// unknown before the first refresh.
    public static func ownerStatus(presence: BotPresence) -> BotOwnerStatus {
        switch presence {
        case .reachable: return .online
        case .unreachable: return .offlineGhost
        case .unknown: return .unknown
        }
    }
}
