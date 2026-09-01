import SwiftUI
import FleetCore

/// Bot detail (U2) — identity Route, status, and sessions via `session.list`.
///
/// Renders the bot's canonical identity (the exact `Route`, never a display
/// name), its model/provider status, and the sessions list fetched through
/// the read-only `session.list` seam (`AppEnvironment.loadSessions`). Tapping
/// a session drills into the Conversation destination (U3 placeholder canvas).
///
/// Observation only (spec §5.4): this screen reads `session.list` and issues
/// no mutating RPC itself — the "New Session" affordance (P0-7) is a
/// navigation to the Conversation canvas, where `session.create` runs only on
/// that explicit user action (the mutating seam stays in the conversation
/// screen, never here).
public struct BotDetailView: View {
    private let environment: AppEnvironment
    private let route: Route

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
        List {
            identitySection(bot)
            statusSection(bot)
            sessionsSection(bot)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(FleetTheme.background)
        .accessibilityIdentifier("fleet.bot-detail.list")
    }

    // MARK: Identity — the canonical Route (spec §7)

    private func identitySection(_ bot: FleetBot) -> some View {
        Section {
            LabeledContent("Route") {
                Text(bot.route.id)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(FleetTheme.textSecondary)
            }
            .accessibilityIdentifier("fleet.bot-detail.route")
            LabeledContent("Gateway") {
                Text(environment.gateway(for: bot.gatewayID)?.displayName ?? bot.gatewayID.rawValue)
                    .foregroundStyle(FleetTheme.textSecondary)
            }
            LabeledContent("Profile") {
                Text(bot.profileSlug.rawValue)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(FleetTheme.textSecondary)
            }
        } header: {
            Text("Identity")
        }
    }

    // MARK: Status — model/provider + latest session + activity

    private func statusSection(_ bot: FleetBot) -> some View {
        Section {
            if let model = bot.model, let provider = bot.provider {
                LabeledContent("Model") { Text("\(model) · \(provider)").foregroundStyle(FleetTheme.textSecondary) }
            } else if let model = bot.model {
                LabeledContent("Model") { Text(model).foregroundStyle(FleetTheme.textSecondary) }
            }
            LabeledContent("Activity") {
                Text(activityText(bot.activity))
                    .foregroundStyle(FleetTheme.textSecondary)
            }
            if let latest = bot.latestSession {
                LabeledContent("Latest session") {
                    Text(latest.title)
                        .lineLimit(1)
                        .foregroundStyle(FleetTheme.textSecondary)
                }
            }
        } header: {
            Text("Status")
        }
    }

    // MARK: Sessions — read-only `session.list` (U2)

    private func sessionsSection(_ bot: FleetBot) -> some View {
        let sessions = environment.sessions(for: route)
        let isLoading = environment.loadingRoutes.contains(route)
        let readError = environment.sessionReadErrors[route]

        return Section {
            // P0-7: New session affordance — the only create path into the
            // conversation canvas (session.create over the mutating
            // ConversationProviding seam; sessionID nil = create).
            NavigationLink(value: FleetScreen.conversation(route, sessionID: nil)) {
                Label("New Session", systemImage: "plus.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FleetTheme.accent)
            }
            .accessibilityIdentifier("fleet.bot-detail.sessions.new")
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading sessions…")
                        .font(.caption)
                        .foregroundStyle(FleetTheme.textSecondary)
                }
                .accessibilityIdentifier("fleet.bot-detail.sessions.loading")
            } else if let readError {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Could not load sessions", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                    Text(readError)
                        .font(.caption)
                        .foregroundStyle(FleetTheme.textSecondary)
                    Button("Retry") {
                        Task { await environment.loadSessions(for: route) }
                    }
                    .font(.caption)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("fleet.bot-detail.sessions.error")
            } else if let sessions, sessions.isEmpty {
                Text("No sessions yet.")
                    .font(.caption)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .accessibilityIdentifier("fleet.bot-detail.sessions.empty")
            } else {
                ForEach(sessions ?? []) { session in
                    NavigationLink(value: FleetScreen.conversation(route, sessionID: session.id)) {
                        SessionRowView(session: session)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("fleet.bot-detail.sessions.row.\(session.id)")
                }
            }
        } header: {
            HStack(spacing: 4) {
                Text("Sessions")
                Text("\(environment.sessions(for: route)?.count ?? 0)")
                    .font(.caption2)
                    .foregroundStyle(FleetTheme.textSecondary)
            }
        } footer: {
            Text("Sessions refresh from session.list each time this screen appears. New Session starts a conversation via session.create.")
        }
    }

    private var unknownRoute: some View {
        ContentUnavailableView {
            Label {
                Text("Bot Unavailable")
            } icon: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(FleetTheme.accent)
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
}

/// A `session.list` row: title + preview + message count + start time.
private struct SessionRowView: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title.isEmpty ? "Untitled session" : session.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(FleetTheme.textPrimary)
                .lineLimit(2)
            if !session.preview.isEmpty {
                Text(session.preview)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
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
