import SwiftUI
import FleetCore

/// Bot detail (U2 → U5 Gold Fleet re-skin) — identity Route, status, and
/// sessions via `session.list`.
///
/// U5 structure per the hero mock's detail screen: a persistent header card
/// (avatar, display name, canonical route, status pill) above a segmented
/// control with two segments — **Chat** (the `session.list` sessions + the
/// New Session affordance; the default segment, matching the pre-U5
/// information hierarchy where sessions were the primary content) and
/// **Details** (identity + model/provider + activity). Metrics is OMITTED:
/// the fleet exposes no real per-bot metrics today, and the plan forbids
/// stub screens ("Metrics only if data exists, else omit; no stub screens").
///
/// Renders the bot's canonical identity (the exact `Route`, never a display
/// name), its model/provider status, and the sessions list fetched through
/// the read-only `session.list` seam (`AppEnvironment.loadSessions`).
/// Tapping a session drills into the Conversation destination.
///
/// Observation only (spec §5.4): this screen reads `session.list` and issues
/// no mutating RPC itself — the "New Session" affordance (P0-7) is a
/// navigation to the Conversation canvas, where `session.create` runs only on
/// that explicit user action (the mutating seam stays in the conversation
/// screen, never here).
public struct BotDetailView: View {
    private let environment: AppEnvironment
    private let route: Route

    /// U5 segmented control selection. Chat is the default: sessions are the
    /// screen's primary content and every drill-in flow (gateway → bots →
    /// detail → session) lands here to open a conversation.
    @State private var segment: DetailSegment = .chat

    public enum DetailSegment: String, Hashable, Sendable, CaseIterable, Identifiable {
        case chat
        case details
        public var id: String { rawValue }
    }

    public init(environment: AppEnvironment, route: Route) {
        self.environment = environment
        self.route = route
    }

    public var body: some View {
        let bot = environment.bot(for: route)
        Group {
            if let bot {
                detail(bot)
            } else {
                unknownRoute
            }
        }
        .navigationTitle(bot?.displayName ?? route.profileSlug.rawValue)
        .task {
            // P0-7: refresh the bot's sessions on EVERY entry (read-only,
            // concurrency-guarded in the environment) so a newly created
            // session appears when the conversation is popped back to this
            // list. Previously the nil-guard skipped refetch when a stale
            // snapshot existed.
            await environment.loadSessions(for: route)
        }
        .background(FleetTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("fleet.bot-detail")
    }

    private func detail(_ bot: FleetBot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
                headerCard(bot)
                segmentedControl
                switch segment {
                case .chat:
                    sessionsSection(bot)
                case .details:
                    detailsSection(bot)
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingMd)
        }
        .background(FleetTheme.background)
    }

    // MARK: Header (persistent across segments) — avatar + name + route + pill

    private func headerCard(_ bot: FleetBot) -> some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                HStack(spacing: FleetTheme.spacingMd) {
                    BotAvatar(displayName: bot.displayName)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bot.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(FleetTheme.textPrimary)
                            .lineLimit(2)
                        Text(bot.route.id)
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(FleetTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    StatusPill(
                        status: FleetStatus(
                            activity: bot.activity,
                            presence: environment.botPresence(for: bot.route)
                        )
                    )
                }
                if bot.gatewayRunning {
                    GatewayRunningBadge(isRunning: true)
                }
                if let model = bot.model, let provider = bot.provider {
                    Text("\(model) · \(provider)")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(1)
                } else if let model = bot.model {
                    Text(model)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.bot-detail.header")
    }

    // MARK: Segmented control (Chat / Details — Metrics omitted, no real data)

    private var segmentedControl: some View {
        Picker("Bot Detail Section", selection: $segment) {
            Text("Chat").tag(DetailSegment.chat)
            Text("Details").tag(DetailSegment.details)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("fleet.bot-detail.segment")
        .accessibilityValue(segment == .chat ? "Chat" : "Details")
    }

    // MARK: Chat segment — sessions via read-only `session.list` (U2)

    private func sessionsSection(_ bot: FleetBot) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            SectionHeader(title: "Sessions")
            sessionsContent
        }
    }

    @ViewBuilder
    private var sessionsContent: some View {
        // P0-7: New session affordance — the only create path into the
        // conversation canvas (session.create over the mutating
        // ConversationProviding seam; sessionID nil = create).
        NavigationLink(value: FleetScreen.conversation(route, sessionID: nil)) {
            Label("New Session", systemImage: "plus.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(FleetTheme.accentMagenta)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, FleetTheme.spacingSm)
        }
        .accessibilityIdentifier("fleet.bot-detail.sessions.new")

        let sessions = environment.sessions(for: route)
        let isLoading = environment.loadingRoutes.contains(route)
        let readError = environment.sessionReadErrors[route]

        if isLoading {
            HStack(spacing: FleetTheme.spacingSm) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading sessions…")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("fleet.bot-detail.sessions.loading")
        } else if let readError {
            FleetCard {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                    Label("Could not load sessions", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                    Text(readError)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                    Button("Retry") {
                        Task { await environment.loadSessions(for: route) }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FleetTheme.accent)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("fleet.bot-detail.sessions.error")
        } else if let sessions, sessions.isEmpty {
            Text("No sessions yet.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.textSecondary)
                .accessibilityIdentifier("fleet.bot-detail.sessions.empty")
        } else {
            VStack(spacing: FleetTheme.spacingSm) {
                ForEach(sessions ?? []) { session in
                    NavigationLink(value: FleetScreen.conversation(route, sessionID: session.id)) {
                        SessionRowView(session: session)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("fleet.bot-detail.sessions.row.\(session.id)")
                }
            }
        }
    }

    // MARK: Details segment — the canonical Route (spec §7) + status

    private func detailsSection(_ bot: FleetBot) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            SectionHeader(title: "Identity")
                .accessibilityIdentifier("fleet.bot-detail.identity.header")
            FleetCard {
                VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    detailRow(label: "Route", value: bot.route.id, monospaced: true)
                    detailRow(label: "Gateway", value: gatewayName)
                    detailRow(label: "Profile", value: bot.profileSlug.rawValue, monospaced: true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("fleet.bot-detail.route")

            SectionHeader(title: "Status")
                .accessibilityIdentifier("fleet.bot-detail.status.header")
            FleetCard {
                VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    if bot.model != nil {
                        detailRow(label: "Model", value: modelText(bot))
                    }
                    detailRow(label: "Activity", value: activityText(bot.activity))
                    detailRow(label: "Presence", value: presenceText(environment.botPresence(for: bot.route)))
                    detailRow(label: "Own gateway process", value: bot.gatewayRunning ? "Running" : "No")
                    if let latest = bot.latestSession {
                        detailRow(label: "Latest session", value: latest.title)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("fleet.bot-detail.status")

            Text("Sessions refresh from session.list each time this screen appears. New Session starts a conversation via session.create.")
                .font(.caption2)
                .foregroundStyle(FleetTheme.textSecondary)
                .padding(.top, FleetTheme.spacingXs)
        }
    }

    private var gatewayName: String {
        environment.gateway(for: route.gatewayID)?.displayName ?? route.gatewayID.rawValue
    }

    private func modelText(_ bot: FleetBot) -> String {
        if let model = bot.model, let provider = bot.provider {
            return "\(model) · \(provider)"
        }
        return bot.model ?? "—"
    }

    private func detailRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(FleetTheme.textSecondary)
            Spacer()
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(FleetTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    private var unknownRoute: some View {
        ContentUnavailableView {
            Label {
                Text("Bot Unavailable")
            } icon: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(FleetTheme.accentMagenta)
            }
        } description: {
            Text("This bot is not in the current roster. Refresh the fleet.")
        }
        .accessibilityIdentifier("fleet.bot-detail.unknown")
    }

    private func activityText(_ activity: BotActivity) -> String {
        switch activity {
        case .working: return "Working"
        case .thinking: return "Thinking"
        case .usingTool: return "Using a tool"
        case .waiting: return "Waiting"
        case .idle: return "Idle"
        case .offline: return "Offline"
        case .needsAttention: return "Needs attention"
        case .unknown: return "Unknown"
        }
    }

    /// P0-7 presence labels — multiplexer model: reachable = online through
    /// the owning gateway's connection.
    private func presenceText(_ presence: BotPresence) -> String {
        switch presence {
        case .reachable: return "Online (gateway reachable)"
        case .unreachable: return "Offline (gateway unreachable)"
        case .unknown: return "Unknown (no roster yet)"
        }
    }
}

/// A `session.list` row: title + preview + message count + start time.
private struct SessionRowView: View {
    let session: SessionSummary

    var body: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? "Untitled session" : session.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                    .lineLimit(2)
                if !session.preview.isEmpty {
                    Text(session.preview)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: FleetTheme.spacingSm) {
                    if session.messageCount > 0 {
                        Text("\(session.messageCount) messages")
                    }
                    if let source = session.source, !source.isEmpty {
                        Text("· \(source)")
                    }
                    if session.startedAt > 0 {
                        Text("· \(Self.dateText(session.startedAt))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(FleetTheme.textSecondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func dateText(_ epoch: Double) -> String {
        FleetSessionDateText.text(epoch)
    }
}

/// P3-1: cached short-date/time formatter shared across every session row.
///
/// `DateFormatter` construction is expensive (locale + calendar + template
/// setup); creating one per evaluated row (session lists can fetch 200 rows)
/// churns objects on every observable update. This singleton caches a single
/// `.short`/`.short` formatter — it is immutable after init and only ever read
/// on the main actor (SwiftUI view evaluation), so sharing it is safe.
public enum FleetSessionDateText {
    @MainActor
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// Format an epoch as a short date + short time, e.g. "8/30/26, 10:05 PM".
    @MainActor
    public static func text(_ epoch: Double) -> String {
        formatter.string(from: Date(timeIntervalSince1970: epoch))
    }
}
