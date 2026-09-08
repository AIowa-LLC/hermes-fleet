import SwiftUI
import FleetCore

/// Bot Detail — FOS-5 (SPEC §9 Bot Detail) reorganization of the U5 screen.
///
/// Structure: a compact identity header (portrait, preferred title, gateway
/// disclosure, presence/activity, model/provider) with ONE primary **Bot
/// Chat** action; below it a segmented **Conversations / Routines /
/// Configuration** switch that reorganizes the existing content — the
/// conversation engine, routines surface, and configuration surfaces are
/// unchanged (no engine rewrite).
///
/// Ghost handling (FOS-5 §9): when the exact Route resolves only through
/// the offline-ghost cache (owning gateway failed its refresh), the screen
/// becomes a snapshot inspector — identity and CACHED sessions remain
/// readable, writes are disabled with an honest offline explanation, and
/// the primary Bot Chat action is disabled (a ghost cannot authorize a
/// canonical open). Identity resolution never falls back by name.
///
/// Observation contract unchanged (spec §5.4): Conversations reads
/// `session.list` and issues no mutating RPC; `session.create` runs only on
/// the explicit New Conversation action inside the conversation canvas.
public struct BotDetailView: View {
    private let environment: AppEnvironment
    private let route: Route

    /// FOS-5: Conversations / Routines / Configuration. Conversations stays
    /// the default (every drill-in flow lands here to open a session).
    @State private var segment: DetailSegment = .conversations

    public enum DetailSegment: String, Hashable, Sendable, CaseIterable, Identifiable {
        case conversations
        case routines
        case configuration
        public var id: String { rawValue }
    }

    public init(environment: AppEnvironment, route: Route) {
        self.environment = environment
        self.route = route
    }

    /// FOS-5: identity resolves through the ghost cache too — a ghost row
    /// never dead-ends at "Bot Unavailable".
    private var resolvedBot: FleetBot? {
        environment.botIncludingGhost(for: route)
    }

    private var isGhost: Bool {
        environment.isGhostRoute(route)
    }

    public var body: some View {
        let bot = resolvedBot
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
            // list. For a ghost the read fails and records its classified
            // error — the CACHED sessions remain readable below it.
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
                case .conversations:
                    sessionsSection(bot)
                case .routines:
                    routinesSection(bot)
                case .configuration:
                    configurationSection(bot)
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingMd)
        }
        .background(FleetTheme.background)
    }

    // MARK: Compact identity header (FOS-5) — portrait, title, gateway,
    // presence + activity, model/provider; ONE primary Bot Chat action.

    private func headerCard(_ bot: FleetBot) -> some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                HStack(spacing: FleetTheme.spacingMd) {
                    BotAvatar(bot: bot, management: environment.botManagement)
                        // Ghost dims the portrait, not the text (§9).
                        .opacity(isGhost ? 0.4 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bot.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(FleetTheme.textPrimary)
                            .lineLimit(2)
                        // Gateway disclosure: friendly name; the full route
                        // stays in Configuration (§9: avoid routine
                        // gatewayID#profileSlug strings in headers).
                        Text(gatewayName)
                            .font(.footnote)
                            .foregroundStyle(FleetTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    StatusPill(
                        status: FleetStatus(
                            activity: bot.activity,
                            presence: isGhost ? .unreachable : environment.botPresence(for: bot.route)
                        )
                    )
                }
                HStack(spacing: FleetTheme.spacingSm) {
                    Text(presenceText(isGhost ? .unreachable : environment.botPresence(for: bot.route)))
                    Text("·")
                    Text(activityText(bot.activity))
                }
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(FleetTheme.textSecondary)
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
                if bot.gatewayRunning {
                    GatewayRunningBadge(isRunning: true)
                }
                if isGhost {
                    // §9: "Last known" time + offline symbol; identity stays
                    // readable. Writes need the owning gateway online.
                    Label("Last known — offline from this phone", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .accessibilityIdentifier("fleet.bot-detail.ghost")
                }

                // One primary action: Bot Chat (canonical, fail-closed).
                // NOTE: no container identifier here — a container id would
                // override the inner button's own `fleet.bot-chat.open`.
                BotChatOpenButton(environment: environment, bot: bot, disabled: isGhost)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.bot-detail.header")
        .sheet(isPresented: $showingEdit) {
            EditBotSheet(environment: environment, bot: bot)
        }
    }

    @State private var showingEdit = false

    // MARK: Segmented control (FOS-5: Conversations / Routines / Configuration)

    private var segmentedControl: some View {
        Picker("Bot Detail Section", selection: $segment) {
            Text("Conversations").tag(DetailSegment.conversations)
            Text("Routines").tag(DetailSegment.routines)
            Text("Configuration").tag(DetailSegment.configuration)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("fleet.bot-detail.segment")
        .accessibilityValue(segmentTitle)
    }

    private var segmentTitle: String {
        switch segment {
        case .conversations: return "Conversations"
        case .routines: return "Routines"
        case .configuration: return "Configuration"
        }
    }

    // MARK: Conversations — sessions via read-only `session.list` (U2)

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
        // FOS-5: disabled for a ghost (offline owner cannot take writes).
        NavigationLink(value: FleetScreen.conversation(route, sessionID: nil)) {
            Label("New Session", systemImage: "plus.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(FleetTheme.accent)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, FleetTheme.spacingSm)
        }
        .buttonStyle(.fleetPressable)
        .accessibilityIdentifier("fleet.bot-detail.sessions.new")

        let sessions = environment.sessions(for: route)
        let isLoading = environment.loadingRoutes.contains(route)
        let readError = environment.sessionReadErrors[route]

        if isGhost {
            // Cached sessions remain readable during the outage (§9 ghost:
            // snapshot inspector + cached sessions).
            if let sessions, !sessions.isEmpty {
                ForEach(sessions) { session in
                    SessionRowView(session: session)
                }
            } else {
                Text("No cached sessions on this phone.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .accessibilityIdentifier("fleet.bot-detail.sessions.empty")
            }
        } else if isLoading {
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
                    .buttonStyle(.fleetPressable)
                    .accessibilityIdentifier("fleet.bot-detail.sessions.row.\(session.id)")
                }
            }
        }
    }

    // MARK: Routines (FOS-5 §9 Bot Detail: Conversations/Routines/Configuration)

    @ViewBuilder
    private func routinesSection(_ bot: FleetBot) -> some View {
        if isGhost || presence == .unreachable {
            FleetCard {
                Label(
                    "Routines need the owning gateway online",
                    systemImage: "wifi.slash"
                )
                .font(.caption)
                .foregroundStyle(FleetTheme.textSecondary)
            }
            .accessibilityIdentifier("fleet.bot-detail.routines.offline")
        } else {
            // Existing routines surface, embedded (namespaced jobs on the
            // owning profile's cron store — no engine change).
            BotRoutinesView(environment: environment, route: route, embedded: true)
                .accessibilityIdentifier("fleet.bot-detail.routines")
        }
    }

    // MARK: Configuration (FOS-5 §9) — identity, actions, management panes

    @ViewBuilder
    private func configurationSection(_ bot: FleetBot) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            SectionHeader(title: "Identity")
                .accessibilityIdentifier("fleet.bot-detail.identity.header")
            FleetCard {
                VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    FleetMetadataRow("Route", bot.route.id, showDivider: false)
                    FleetMetadataRow("Gateway", gatewayName, showDivider: false)
                    FleetMetadataRow("Profile", bot.profileSlug.rawValue, showDivider: false)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("fleet.bot-detail.route")

            SectionHeader(title: "Status")
                .accessibilityIdentifier("fleet.bot-detail.status.header")
            FleetCard {
                VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    if bot.model != nil {
                        FleetMetadataRow("Model", modelText(bot), showDivider: false)
                    }
                    FleetMetadataRow("Activity", activityText(bot.activity), showDivider: false)
                    FleetMetadataRow("Presence", presenceText(isGhost ? .unreachable : environment.botPresence(for: bot.route)), showDivider: false)
                    FleetMetadataRow("Own gateway process", bot.gatewayRunning ? "Running" : "No", showDivider: false)
                    if let latest = bot.latestSession {
                        FleetMetadataRow("Latest session", latest.title, showDivider: false)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("fleet.bot-detail.status")

            // Slice 2 management actions — Edit sheet, Duplicate (with
            // inherited/not-copied confirmation), Delete (capability-gated
            // honest state). Ghost writes are disabled: an offline-owning
            // gateway cannot take metadata writes.
            if isGhost || presence == .unreachable {
                Label(
                    "Write actions need the owning gateway online",
                    systemImage: "wifi.slash"
                )
                .font(.caption)
                .foregroundStyle(FleetTheme.textSecondary)
                .accessibilityIdentifier("fleet.bot-detail.writes-offline")
            } else {
                VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                    HStack(spacing: FleetTheme.spacingSm) {
                        Button {
                            showingEdit = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("fleet.bot-detail.edit")
                        BotActionsMenu(environment: environment, bot: bot)
                    }
                    // FOS-2: profile-scoped management panes entered from
                    // Bot Detail carry this Bot's Route — no picker, no
                    // fallback (SPEC §8 scope selection rule).
                    VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                        NavigationLink(value: FleetScreen.skills(route.gatewayID, profile: route.profileSlug)) {
                            Label("Skills", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("fleet.bot-detail.skills")
                        NavigationLink(value: FleetScreen.memoryGraph(route.gatewayID, profile: route.profileSlug)) {
                            Label("Memory", systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("fleet.bot-detail.memory")
                    }
                }
            }

            Text("Conversations refresh when you open this agent. Your chats stay connected to their original gateway.")
                .font(.caption2)
                .foregroundStyle(FleetTheme.textSecondary)
                .padding(.top, FleetTheme.spacingXs)
        }
    }

    private var gatewayName: String {
        environment.gateway(for: route.gatewayID)?.displayName ?? route.gatewayID.rawValue
    }

    private var presence: BotPresence {
        environment.botPresence(for: route)
    }

    private func modelText(_ bot: FleetBot) -> String {
        if let model = bot.model, let provider = bot.provider {
            return "\(model) · \(provider)"
        }
        return bot.model ?? "—"
    }

    private var unknownRoute: some View {
        ContentUnavailableView {
            Label {
                Text("Bot Unavailable")
            } icon: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(FleetTheme.textSecondary)
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
                // V3: session metadata (count · source · date) is telemetry —
                // mono caption, the terminal voice.
                .font(FleetTheme.monoCaptionFont)
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
