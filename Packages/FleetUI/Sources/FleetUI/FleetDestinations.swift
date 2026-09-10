import SwiftUI
import FleetCore

/// A session identity always includes its owning route; IDs may repeat across hosts.
struct FleetChatEntry: Identifiable {
    let route: Route
    let session: SessionSummary
    var id: String { "\(route.id)/\(session.id)" }
}

/// FOS-5 (SPEC §10) Compose: a source-qualified Bot chooser — every roster
/// bot carries its owning gateway; picking one + explicit Create opens an
/// ordinary session on THAT bot's route. Never a silent first gateway.
struct ComposeBotPickerSheet: View {
    @Environment(\.fleetTheme) private var theme
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [(bot: FleetBot, gatewayName: String)] {
        environment.rosterSnapshot?.roster.allBots
            .compactMap { bot in
                guard let gateway = environment.gateway(for: bot.route.gatewayID) else { return nil }
                return (bot, gateway.displayName)
            }
            .filter { query.isEmpty || "\($0.bot.displayName) \($0.bot.route.profileSlug.rawValue) \($0.gatewayName)".localizedCaseInsensitiveContains(query) }
            .sorted { $0.bot.route.id < $1.bot.route.id } ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(candidates, id: \.bot.route.id) { candidate in
                Button {
                    // Explicit Create: ordinary session (canonical: false),
                    // exact source-qualified route.
                    environment.requestScreen(
                        .conversation(candidate.bot.route, sessionID: nil, canonical: false))
                    dismiss()
                } label: {
                    HStack(spacing: FleetTheme.spacingMd) {
                        BotAvatar(bot: candidate.bot, management: environment.botManagement)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.bot.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(theme.textPrimary)
                            Text("\(candidate.bot.route.profileSlug.rawValue) · \(candidate.gatewayName)")
                                .font(.caption)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                .accessibilityIdentifier("fleet.chats.compose.bot.\(candidate.bot.route.id)")
                }
            }
            .searchable(text: $query, prompt: "Bots across every gateway")
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .scrollContentBackground(.hidden).background(theme.background)
        }
        .accessibilityIdentifier("fleet.chats.compose")
    }
}

struct FleetChatsView: View {
    @Environment(\.fleetTheme) private var theme
    let environment: AppEnvironment
    @State private var query = ""
    @State private var gatewayID: GatewayID?
    @State private var showingCompose = false

    /// FOS-5 (SPEC §10): entries retained during a gateway outage even when
    /// the live roster no longer contains that Route — the ENTRY keeps its
    /// source identity (Route), never a name fallback. `sessionsByRoute`
    /// persists across refreshes (it is replaced only by a successful read),
    /// so loaded conversations survive the outage; the roster lookup moves
    /// from a hard requirement to a display-name enrichment.
    private var entries: [FleetChatEntry] {
        environment.sessionsByRoute.flatMap { route, sessions in
            sessions.filter { !environment.isCanonicalBotChat(route: route, sessionID: $0.id) }
                .map { FleetChatEntry(route: route, session: $0) }
        }.filter { entry in
            environment.gateway(for: entry.route.gatewayID) != nil &&
            (gatewayID == nil || entry.route.gatewayID == gatewayID) &&
            (query.isEmpty || "\(entry.session.title) \(entry.session.preview) \(botDisplayName(entry.route)) \(environment.gateway(for: entry.route.gatewayID)?.displayName ?? "")".localizedCaseInsensitiveContains(query))
        }.sorted {
            if $0.session.startedAt == $1.session.startedAt { return $0.id < $1.id }
            return $0.session.startedAt > $1.session.startedAt
        }
    }

    /// Route-qualified display name; falls back to the slug from the ROUTE
    /// (identity), never a same-name bot from another gateway.
    private func botDisplayName(_ route: Route) -> String {
        environment.bot(for: route)?.displayName ?? route.profileSlug.rawValue
    }

    /// FOS-5: entries whose Route dropped out of the live roster (outage
    /// retention) render an offline marker.
    private func isRetainedDuringOutage(_ entry: FleetChatEntry) -> Bool {
        environment.bot(for: entry.route) == nil
    }

    var body: some View {
        List {
            Section {
                Button {
                    showingCompose = true
                } label: {
                    Label("Start a conversation", systemImage: "square.and.pencil")
                        .foregroundStyle(theme.highlight)
                }.accessibilityIdentifier("fleet.chats.new")
                Picker("Gateway", selection: $gatewayID) {
                    Text("All gateways").tag(Optional<GatewayID>.none)
                    ForEach(environment.gateways) { gateway in
                        Text(gateway.displayName).tag(Optional(gateway.id))
                    }
                }
                .accessibilityIdentifier("fleet.chats.gateway-filter")
            }
            if !environment.loadingRoutes.isEmpty {
                ProgressView("Refreshing conversations…")
            }
            if !environment.sessionReadErrors.isEmpty {
                Section {
                    Label("Some conversations could not refresh. Previously loaded chats may be out of date.", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.footnote).foregroundStyle(theme.textSecondary)
                    Button("Retry") { Task { await refresh() } }
                }
            }
            // FOS-5 (SPEC §10): heading stays "Newest sessions" — honest
            // startedAt ordering; not renamed to "Recent" (no last-activity
            // ranking until it is real). lastActive IS decoded+preserved on
            // SessionSummary for the future upgrade.
            Section("Newest sessions") {
                ForEach(entries) { entry in
                    NavigationLink(value: FleetScreen.conversation(entry.route, sessionID: entry.session.id)) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(entry.session.title.isEmpty ? "Untitled conversation" : entry.session.title)
                                .font(.headline).foregroundStyle(theme.textPrimary).lineLimit(2)
                            if !entry.session.preview.isEmpty {
                                Text(entry.session.preview).font(.subheadline)
                                    .foregroundStyle(theme.textSecondary).lineLimit(2)
                            }
                            Text("\(botDisplayName(entry.route)) · \(environment.gateway(for: entry.route.gatewayID)?.displayName ?? entry.route.gatewayID.rawValue)")
                                .font(.caption).foregroundStyle(theme.highlight)
                            if isRetainedDuringOutage(entry) {
                                Label("Last synced — bot offline from this phone", systemImage: "wifi.slash")
                                    .font(.caption2).foregroundStyle(theme.textSecondary)
                                    .accessibilityIdentifier("fleet.chats.retained.\(entry.id)")
                            }
                        }.padding(.vertical, 6)
                    }.accessibilityIdentifier("fleet.chats.session.\(entry.id)")
                }
                if entries.isEmpty && environment.loadingRoutes.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "Your next idea starts here" : "No matching conversations", systemImage: "bubble.left.and.bubble.right", description: Text(query.isEmpty ? "Choose a bot to begin, or refresh to load its conversations." : "Try a different title or bot name."))
                }
            }
            if !query.isEmpty {
                Section {
                    Text("Search loaded conversations")
                        .font(.caption).foregroundStyle(theme.textSecondary)
                }
            }
        }
        .sheet(isPresented: $showingCompose) {
            ComposeBotPickerSheet(environment: environment)
        }
        .scrollContentBackground(.hidden).background(theme.background)
        .navigationTitle("Chats").searchable(text: $query, prompt: "Conversations and bots")
        .refreshable { await refresh() }.task { await refresh() }
        .accessibilityIdentifier("fleet.chats")
    }

    private func refresh() async {
        if environment.rosterSnapshot == nil { await environment.refreshRoster() }
        // Sequential fetches avoid opening an unbounded number of roster transports.
        for bot in environment.rosterSnapshot?.roster.allBots ?? [] {
            guard !Task.isCancelled else { return }
            await environment.loadSessions(for: bot.route)
        }
    }
}

// FOS-3: FleetControlView and FleetWorkspaceView are RETIRED (SPEC §6/§19 —
// "Control root: Remove + Redistribute", "Workspace root / slogan: Remove").
// Their capabilities were already redistributed by FOS-1/FOS-2: registry,
// health, history and per-gateway resources live beneath the Gateways tab
// (Gateway Detail cockpit); Settings is the Fleet gear sheet. Both views were
// dead code after FOS-1; this card deletes them.

/// FOS-3 (SPEC §13) — Command Center result model. Results carry their
/// OWNING tab and an exact destination; `Environment`-derived search text
/// (bots, groups, gateways) is precomputed so the query is a pure filter.
struct FleetCommandCenterResults {
    struct Item: Identifiable {
        enum Kind { case bot, group, gateway, conversation, resource }
        let kind: Kind
        let title: String
        let subtitle: String
        let keywords: String
        /// Identifier pattern: "bot:<route>" / "group:<roomKey>" /
        /// "gateway:<id>" / "conv:<route>/<session>" / "res:<screen>".
        let id: String
        let screen: FleetScreen

        func matches(_ query: String) -> Bool {
            query.isEmpty
                || title.localizedCaseInsensitiveContains(query)
                || subtitle.localizedCaseInsensitiveContains(query)
                || keywords.localizedCaseInsensitiveContains(query)
        }
    }

    let items: [Item]

    /// Build the loaded-index result set from the environment. No transport
    /// is opened: bots/groups/gateways come from the current roster/registry
    /// snapshots, conversations from `sessionsByRoute` with the SAME canonical
    /// exclusion Chats applies (SPEC §13: canonical sessions must not appear
    /// as ordinary chats).
    @MainActor
    init(environment: AppEnvironment) {
        var items: [Item] = []

        // Bots — roster truth (owner: Bots).
        for bot in environment.rosterSnapshot?.roster.allBots ?? [] {
            let gatewayName = environment.gateway(for: bot.route.gatewayID)?.displayName
                ?? bot.route.gatewayID.rawValue
            items.append(Item(
                kind: .bot,
                title: bot.displayName,
                subtitle: "Bot · \(gatewayName)",
                keywords: "bot agent profile \(bot.route.id) \(gatewayName)",
                id: "bot:\(bot.route.id)",
                screen: .botDetail(bot.route)
            ))
        }

        // Groups — room union (owner: Bots; room key is the identity).
        for gateway in environment.gateways {
            for room in environment.rooms(for: gateway.id) {
                items.append(Item(
                    kind: .group,
                    title: room.name,
                    subtitle: "Group · \(gateway.displayName)",
                    keywords: "group room \(room.id.key) \(gateway.displayName)",
                    id: "group:\(room.id.key)",
                    screen: .room(room.id)
                ))
            }
        }

        // Gateways — direct object results (SPEC §13 addition).
        for gateway in environment.gateways {
            items.append(Item(
                kind: .gateway,
                title: gateway.displayName,
                subtitle: "Gateway · \(gateway.id.rawValue)",
                keywords: "gateway machine server \(gateway.displayName) \(gateway.id.rawValue)",
                id: "gateway:\(gateway.id.rawValue)",
                screen: .gatewayDetail(gateway.id)
            ))
        }

        // Loaded conversations — canonical sessions EXCLUDED (§13).
        for route in environment.sessionsByRoute.keys.sorted(by: { $0.id < $1.id }) {
            guard environment.gateway(for: route.gatewayID) != nil else { continue }
            let botName = environment.bot(for: route)?.displayName
            for session in environment.sessions(for: route) ?? [] {
                guard !environment.isCanonicalBotChat(route: route, sessionID: session.id)
                else { continue }
                let title = session.title.isEmpty ? "Untitled conversation" : session.title
                items.append(Item(
                    kind: .conversation,
                    title: title,
                    subtitle: "\(botName ?? route.profileSlug.rawValue) · \(route.id)",
                    keywords: "conversation chat session \(title) \(route.id) \(session.id)",
                    id: "conv:\(route.id)/\(session.id)",
                    screen: .conversation(route, sessionID: session.id)
                ))
            }
        }

        // Per-gateway resources (owner: Gateways; exact-gateway routes from FOS-2).
        for gateway in environment.gateways {
            let name = gateway.displayName
            items.append(Item(kind: .resource, title: "Projects — \(name)", subtitle: "Gateway resource · \(name)", keywords: "projects files workspace \(name)", id: "res:projects:\(gateway.id.rawValue)", screen: .projects(gateway.id)))
            items.append(Item(kind: .resource, title: "Schedules — \(name)", subtitle: "Gateway resource · \(name)", keywords: "cron schedules jobs \(name)", id: "res:cron:\(gateway.id.rawValue)", screen: .cron(gateway.id)))
            items.append(Item(kind: .resource, title: "Skills — \(name)", subtitle: "Gateway resource · \(name)", keywords: "skills \(name)", id: "res:skills:\(gateway.id.rawValue)", screen: .skills(gateway.id)))
            items.append(Item(kind: .resource, title: "Memory — \(name)", subtitle: "Gateway resource · \(name)", keywords: "memory graph knowledge \(name)", id: "res:memory:\(gateway.id.rawValue)", screen: .memoryGraph(gateway.id)))
        }

        self.items = items
    }
}

struct FleetCommandCenter: View {
    @Environment(\.fleetTheme) private var theme
    let environment: AppEnvironment
    let navigate: (FleetScreen) -> Void
    let selectTab: (FleetTab) -> Void
    /// FOS-3 (§12): Settings is reachable from Command Center as well as the
    /// Fleet gear — the shell passes the sheet-presentation callback in.
    var openSettings: (() -> Void)? = nil
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    private func open(_ screen: FleetScreen) {
        // FOS-3 (§6 routing contract): navigation goes through
        // `FleetNavigationState.open`, which selects the OWNING tab and
        // focuses the exact destination — bots → Bots, gateway resources →
        // Gateways, conversations → their canonical owner.
        dismiss()
        navigate(screen)
    }

    /// All matching results, grouped by kind. Cap the visible rows per
    /// section (Show more never truncates silently — the section header
    /// carries the total).
    private var results: [FleetCommandCenterResults.Item] {
        let all = FleetCommandCenterResults(environment: environment).items
        return all.filter { $0.matches(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Go to") {
                    ForEach(FleetTab.allCases.filter { matches($0.label) }) { tab in
                        Button { dismiss(); selectTab(tab) } label: { Label(tab.label, systemImage: tab.systemImage) }
                    }
                }
                if let openSettings, matches("settings preferences appearance app lock") {
                    Section {
                        Button { dismiss(); openSettings() } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("fleet.command-center.settings")
                    }
                }
                resultSections(bots: results.filter { $0.kind == .bot },
                               groups: results.filter { $0.kind == .group },
                               gateways: results.filter { $0.kind == .gateway },
                               conversations: results.filter { $0.kind == .conversation },
                               resources: results.filter { $0.kind == .resource })
                if matches("Refresh fleet") {
                    Button("Refresh fleet", systemImage: "arrow.clockwise") { Task { await environment.refreshRoster() } }.disabled(environment.isRefreshing)
                }
            }
            .searchable(text: $query, prompt: "Find a bot, conversation, or destination")
            .navigationTitle("Command Center").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .scrollContentBackground(.hidden).background(theme.background)
        }
        .accessibilityIdentifier("fleet.command-center")
    }

    @ViewBuilder
    private func resultSections(bots: [Item2], groups: [Item2], gateways: [Item2], conversations: [Item2], resources: [Item2]) -> some View {
        section("Bots", icon: "cpu", items: bots)
        section("Groups", icon: "person.3", items: groups)
        section("Gateways", icon: "server.rack", items: gateways)
        section("Loaded conversations", icon: "bubble.left", items: conversations)
        section("Resources", icon: "folder", items: resources)
    }

    private typealias Item2 = FleetCommandCenterResults.Item

    @ViewBuilder
    private func section(_ title: String, icon: String, items: [FleetCommandCenterResults.Item]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items.prefix(10)) { item in
                    Button { open(item.screen) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon)
                                .foregroundStyle(theme.highlight)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text(item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("fleet.command-center.row.\(item.id)")
                }
                if items.count > 10 {
                    Text("Show more — \(items.count - 10) more")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            } header: {
                Text("\(title) — \(items.count)")
            }
        }
    }
}
