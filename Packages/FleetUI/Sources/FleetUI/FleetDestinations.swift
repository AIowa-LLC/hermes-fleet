import SwiftUI
import FleetCore

/// A session identity always includes its owning route; IDs may repeat across hosts.
struct FleetChatEntry: Identifiable {
    let route: Route
    let session: SessionSummary
    var id: String { "\(route.id)/\(session.id)" }
}

struct FleetChatsView: View {
    let environment: AppEnvironment
    @State private var query = ""
    @State private var gatewayID: GatewayID?

    private var entries: [FleetChatEntry] {
        environment.sessionsByRoute.flatMap { route, sessions in
            sessions.map { FleetChatEntry(route: route, session: $0) }
        }.filter { entry in
            environment.gateway(for: entry.route.gatewayID) != nil &&
            environment.bot(for: entry.route) != nil &&
            (gatewayID == nil || entry.route.gatewayID == gatewayID) &&
            (query.isEmpty || "\(entry.session.title) \(entry.session.preview) \(environment.bot(for: entry.route)?.displayName ?? "")".localizedCaseInsensitiveContains(query))
        }.sorted {
            if $0.session.startedAt == $1.session.startedAt { return $0.id < $1.id }
            return $0.session.startedAt > $1.session.startedAt
        }
    }

    var body: some View {
        List {
            Section {
                NavigationLink(value: FleetScreen.roster) {
                    Label("Start a conversation", systemImage: "square.and.pencil")
                        .foregroundStyle(FleetTheme.accent)
                }.accessibilityIdentifier("fleet.chats.new")
                Picker("Gateway", selection: $gatewayID) {
                    Text("All gateways").tag(Optional<GatewayID>.none)
                    ForEach(environment.gateways) { gateway in
                        Text(gateway.displayName).tag(Optional(gateway.id))
                    }
                }
            }
            if !environment.loadingRoutes.isEmpty {
                ProgressView("Refreshing conversations…")
            }
            if !environment.sessionReadErrors.isEmpty {
                Section {
                    Label("Some conversations could not refresh. Previously loaded chats may be out of date.", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.footnote).foregroundStyle(FleetTheme.textSecondary)
                    Button("Retry") { Task { await refresh() } }
                }
            }
            Section("Newest sessions") {
                ForEach(entries) { entry in
                    NavigationLink(value: FleetScreen.conversation(entry.route, sessionID: entry.session.id)) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(entry.session.title.isEmpty ? "Untitled conversation" : entry.session.title)
                                .font(.headline).foregroundStyle(FleetTheme.textPrimary).lineLimit(2)
                            if !entry.session.preview.isEmpty {
                                Text(entry.session.preview).font(.subheadline)
                                    .foregroundStyle(FleetTheme.textSecondary).lineLimit(2)
                            }
                            Text("\(environment.bot(for: entry.route)?.displayName ?? entry.route.profileSlug.rawValue) · \(environment.gateway(for: entry.route.gatewayID)?.displayName ?? entry.route.gatewayID.rawValue)")
                                .font(.caption).foregroundStyle(FleetTheme.accent)
                        }.padding(.vertical, 6)
                    }.accessibilityIdentifier("fleet.chats.session.\(entry.id)")
                }
                if entries.isEmpty && environment.loadingRoutes.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "Your next idea starts here" : "No matching conversations", systemImage: "bubble.left.and.bubble.right", description: Text(query.isEmpty ? "Choose a bot to begin, or refresh to load its conversations." : "Try a different title or bot name."))
                }
            }
        }
        .scrollContentBackground(.hidden).background(FleetTheme.background)
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

struct FleetWorkspaceView: View {
    let environment: AppEnvironment
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundStyle(FleetTheme.accent)
                    Text("Where ideas become work.").font(.title2.bold())
                    Text("Explore projects and files on your gateways. Open a host to browse its workspace.")
                        .font(.subheadline).foregroundStyle(FleetTheme.textSecondary)
                }.padding(.vertical, 12)
            }
            Section("Workspaces by gateway") {
                ForEach(environment.gateways) { gateway in
                    NavigationLink(value: FleetScreen.projects(gateway.id)) {
                        Label(gateway.displayName, systemImage: "folder")
                    }.accessibilityIdentifier("fleet.workspace.gateway.\(gateway.id.rawValue)")
                }
                if environment.gateways.isEmpty {
                    ContentUnavailableView("Connect your workspace", systemImage: "folder", description: Text("Add a gateway in Control to explore its projects."))
                }
            }
            Section {
                NavigationLink(value: FleetScreen.kanban) { Label("Work board", systemImage: "rectangle.split.3x1") }
            }
        }
        .scrollContentBackground(.hidden).background(FleetTheme.background)
        .navigationTitle("Workspace").accessibilityIdentifier("fleet.workspace")
    }
}

struct FleetControlView: View {
    let environment: AppEnvironment
    let lockController: AppLockController
    var body: some View {
        List {
            Section("Fleet") {
                NavigationLink(value: FleetScreen.gateways) { Label("Gateways", systemImage: "server.rack") }
                NavigationLink(value: FleetScreen.health) { Label("Connection health", systemImage: "waveform.path.ecg") }
                NavigationLink(value: FleetScreen.activity) { Label("Connection history", systemImage: "clock.arrow.circlepath") }
            }
            ForEach(environment.gateways) { gateway in
                Section(gateway.displayName) {
                    NavigationLink(value: FleetScreen.cron(gateway.id)) { Label("Cron", systemImage: "calendar.badge.clock") }
                    NavigationLink(value: FleetScreen.skills(gateway.id)) { Label("Skills", systemImage: "sparkles") }
                    NavigationLink(value: FleetScreen.memoryGraph(gateway.id)) { Label("Memory Graph", systemImage: "point.3.connected.trianglepath.dotted") }
                }
            }
            Section("Security & preferences") {
                NavigationLink { FleetSettingsView(controller: lockController) } label: {
                    Label("App Lock & settings", systemImage: "lock.shield")
                }
            }
        }
        .scrollContentBackground(.hidden).background(FleetTheme.background)
        .navigationTitle("Control").accessibilityIdentifier("fleet.control")
    }
}

struct FleetCommandCenter: View {
    let environment: AppEnvironment
    let navigate: (FleetScreen) -> Void
    let selectTab: (FleetTab) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    private func open(_ screen: FleetScreen) { dismiss(); navigate(screen) }

    var body: some View {
        NavigationStack {
            List {
                Section("Go to") {
                    ForEach(FleetTab.allCases.filter { matches($0.label) }) { tab in
                        Button { dismiss(); selectTab(tab) } label: { Label(tab.label, systemImage: tab.systemImage) }
                    }
                }
                Section("Agents") {
                    ForEach((environment.rosterSnapshot?.roster.allBots ?? []).filter { matches("\($0.displayName) \($0.route.id)") }) { bot in
                        Button { open(.botDetail(bot.route)) } label: {
                            Label { VStack(alignment: .leading) {
                                Text(bot.displayName)
                                Text(environment.gateway(for: bot.route.gatewayID)?.displayName ?? bot.route.gatewayID.rawValue).font(.caption).foregroundStyle(FleetTheme.textSecondary)
                            } } icon: { Image(systemName: "cpu") }
                        }
                        Button("New chat with \(bot.displayName)", systemImage: "square.and.pencil") { open(.conversation(bot.route, sessionID: nil)) }
                    }
                }
                Section("Loaded conversations") {
                    ForEach(environment.sessionsByRoute.keys.filter { environment.gateway(for: $0.gatewayID) != nil }.sorted { $0.id < $1.id }, id: \.self) { route in
                        ForEach((environment.sessions(for: route) ?? []).filter { matches($0.title) }.prefix(20)) { session in
                            Button { open(.conversation(route, sessionID: session.id)) } label: {
                                VStack(alignment: .leading) {
                                    Text(session.title.isEmpty ? "Untitled conversation" : session.title)
                                    Text(route.id).font(.caption).foregroundStyle(FleetTheme.textSecondary)
                                }
                            }
                        }
                    }
                }
                ForEach(environment.gateways) { gateway in
                    Section(gateway.displayName) {
                        if matches("Projects files workspace \(gateway.displayName)") { Button("Projects", systemImage: "folder") { open(.projects(gateway.id)) } }
                        if matches("Cron schedule \(gateway.displayName)") { Button("Cron", systemImage: "calendar") { open(.cron(gateway.id)) } }
                        if matches("Skills \(gateway.displayName)") { Button("Skills", systemImage: "sparkles") { open(.skills(gateway.id)) } }
                        if matches("Memory Graph \(gateway.displayName)") { Button("Memory Graph", systemImage: "point.3.connected.trianglepath.dotted") { open(.memoryGraph(gateway.id)) } }
                    }
                }
                if matches("Refresh fleet") {
                    Button("Refresh fleet", systemImage: "arrow.clockwise") { Task { await environment.refreshRoster() } }.disabled(environment.isRefreshing)
                }
            }
            .searchable(text: $query, prompt: "Find a bot, conversation, or destination")
            .navigationTitle("Command Center").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .scrollContentBackground(.hidden).background(FleetTheme.background)
        }
        .accessibilityIdentifier("fleet.command-center")
    }
}
