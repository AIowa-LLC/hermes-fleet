import SwiftUI
import FleetCore

/// A session identity always includes its owning route; IDs may repeat across hosts.
struct FleetChatEntry: Identifiable {
    let route: Route
    let session: SessionSummary
    var id: String { "\(route.id)/\(session.id)" }

    /// The stable pin identity for this conversation (the same value the
    /// drawer's pinned section and the pin store key on).
    var pinIdentity: FleetConversationIdentity {
        .individual(route: route, sessionID: session.id)
    }
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

/// Device-level archive/hide store for the Chats list (Codex-style
/// cleanup). The gateway seam has no archive RPC on this client yet —
/// archive/delete are HONEST local hides: persisted, filter-aware, and
/// never claimed as server deletions.
enum FleetChatsArchiveStore {
    private static let key = "fleet.chats.archived.v1"

    static func hiddenIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    /// UI-test hygiene (HERMES_FLEET_NAV_RESET): archived rows must not leak
    /// across suite runs.
    static func resetForUITests() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func setHidden(_ entryID: String, hidden: Bool) {
        var ids = hiddenIDs()
        if hidden {
            ids.insert(entryID)
        } else {
            ids.remove(entryID)
        }
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
    }
}

struct FleetChatsView: View {
    @Environment(\.fleetTheme) private var theme
    let environment: AppEnvironment
    @State private var query = ""
    @State private var gatewayID: GatewayID?
    @State private var showingCompose = false
    @State private var showingGroupCompose = false
    @State private var pendingDeleteEntry: FleetChatEntry?
    @State private var archivedNotice: String?

    /// Codex-style cleanup: locally hidden conversations (archive). The
    /// gateway has no archive RPC on this client's seam yet — archive is an
    /// honest device-level hide, persisted and filter-aware (never hides a
    /// search match).
    @State private var hiddenEntryIDs: Set<String> = []

    private var visibleEntries: [FleetChatEntry] {
        entries.filter { !hiddenEntryIDs.contains($0.id) }
    }

    private func togglePin(_ entry: FleetChatEntry) async {
        if environment.isPinned(entry.pinIdentity) {
            await environment.unpinConversation(entry.pinIdentity)
        } else {
            await environment.pinConversation(
                identity: entry.pinIdentity,
                title: entry.session.title.isEmpty ? "Untitled conversation" : entry.session.title,
                preview: SessionPreviewText.humanReadable(entry.session.preview),
                authoritativeGatewayID: nil,
                avatarKey: nil
            )
        }
    }

    /// Local hide (device-level). Honest copy: the conversation stays on the
    /// gateway; it is hidden from THIS list until revealed.
    private func archiveLocally(_ entry: FleetChatEntry) {
        hiddenEntryIDs.insert(entry.id)
        FleetChatsArchiveStore.setHidden(entry.id, hidden: true)
        archivedNotice = "Archived on this device — \(entry.session.title.isEmpty ? "Untitled conversation" : entry.session.title)"
    }

    private func deleteEntry(_ entry: FleetChatEntry) async {
        // Delete mirrors archive's honest scope for now: a device-level hide
        // with destructive styling (the gateway seam has no session.delete).
        hiddenEntryIDs.insert(entry.id)
        FleetChatsArchiveStore.setHidden(entry.id, hidden: true)
        archivedNotice = "Removed from this device — \(entry.session.title.isEmpty ? "Untitled conversation" : entry.session.title)"
    }

    private var groups: [FleetRoom] {
        environment.allRooms.filter { room in
            (gatewayID == nil || room.id.gatewayID == gatewayID)
                && (query.isEmpty || "\(room.name) \(room.members.map(\.name).joined(separator: " "))".localizedCaseInsensitiveContains(query))
        }
    }

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

    /// Dogfood finding 1: cached/retained conversations this screen can still
    /// render — every non-canonical session on a route whose gateway is known
    /// (a session retained from a bot that dropped out of the live roster still
    /// counts: FOS-5 outage retention must not regress).
    private var usableSessionCount: Int {
        environment.sessionsByRoute.reduce(0) { count, pair in
            guard environment.gateway(for: pair.key.gatewayID) != nil else { return count }
            return count + pair.value.filter {
                !environment.isCanonicalBotChat(route: pair.key, sessionID: $0.id)
            }.count
        }
    }

    /// Routes currently in the roster — exactly the routes `refresh()`
    /// re-reads, so they are the only failures this screen can still retry.
    private var currentRosterRoutes: Set<Route> {
        Set((environment.rosterSnapshot?.roster.allBots ?? []).map(\.route))
    }

    /// Failed routes that are STILL in the current roster. A route that has
    /// left the roster can no longer be re-read by `Retry` from this screen, so
    /// its error is stale here (it stays visible on the owner surface — Bot
    /// detail — which can retry it).
    private var reportedFailureRouteCount: Int {
        FleetChatsPresentation.currentFailureRoutes(
            failedRoutes: Set(environment.sessionReadErrors.keys),
            rosterRoutes: currentRosterRoutes
        ).count
    }

    /// Dogfood finding 1: truthful partial-failure reporting, compact when the
    /// user still has conversations to look at.
    private var refreshFailure: RefreshFailureSurface {
        FleetChatsPresentation.refreshFailureSurface(
            failedRouteCount: reportedFailureRouteCount,
            hasUsableSessions: usableSessionCount > 0
        )
    }

    var body: some View {
        List {
            Section {
                Picker("Gateway", selection: $gatewayID) {
                    Text("All gateways").tag(Optional<GatewayID>.none)
                    ForEach(environment.gateways) { gateway in
                        Text(gateway.displayName).tag(Optional(gateway.id))
                    }
                }
                .accessibilityIdentifier("fleet.chats.gateway-filter")
            }
            Section("Groups") {
                if groups.isEmpty {
                    Text("No groups in the connected fleet yet.")
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("fleet.chats.groups.empty")
                } else {
                    ForEach(groups, id: \.canonicalIdentity) { room in
                        NavigationLink(value: FleetScreen.room(room.id)) {
                            VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                                RoomRowView(room: room)
                                if environment.roomSyncWarnings[room.canonicalIdentity] != nil {
                                    Label("History sync pending", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.caption2)
                                        .foregroundStyle(FleetTheme.statusNeedsIntervention)
                                        .padding(.leading, FleetTheme.spacingMd)
                                }
                            }
                        }
                        .accessibilityIdentifier("fleet.chats.group.\(room.canonicalIdentity)")
                    }
                }
            }
            if !environment.loadingRoutes.isEmpty {
                if entries.isEmpty && environment.sessionsByRoute.isEmpty {
                    ProgressView("Refreshing conversations…")
                        .accessibilityIdentifier("fleet.chats.loading.first")
                } else {
                    HStack(spacing: FleetTheme.spacingSm) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                        Text("Updating…")
                            .font(.footnote)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("fleet.chats.loading.background")
                }
            }
            // Dogfood finding 1: truthful failure reporting, scoped to routes
            // this screen can actually retry. Compact/inline while usable
            // conversations remain; the stronger empty/error surface only when
            // there is nothing honest to show.
            switch refreshFailure {
            case .none:
                EmptyView()
            case .inline:
                inlineRefreshFailure
            case .prominent:
                prominentRefreshFailure
            }
            // FOS-5 (SPEC §10): heading stays "Newest sessions" — honest
            // startedAt ordering; not renamed to "Recent" (no last-activity
            // ranking until it is real). lastActive IS decoded+preserved on
            // SessionSummary for the future upgrade.
            Section("Newest sessions") {
                ForEach(visibleEntries) { entry in
                    NavigationLink(value: FleetScreen.conversation(entry.route, sessionID: entry.session.id)) {
                        // Codex/ChatGPT-style row diet: single-line title +
                        // one muted secondary line. No avatars, no previews,
                        // no pin icons — pin/archive/delete live on swipes.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.session.title.isEmpty ? "Untitled conversation" : entry.session.title)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                if isRetainedDuringOutage(entry) {
                                    Image(systemName: "wifi.slash")
                                        .font(.caption2)
                                        .foregroundStyle(theme.textSecondary)
                                        .accessibilityHidden(true)
                                }
                                Text("\(botDisplayName(entry.route)) · \(environment.gateway(for: entry.route.gatewayID)?.displayName ?? entry.route.gatewayID.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                            }
                            .accessibilityIdentifier("fleet.chats.retained.\(entry.id)")
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityIdentifier("fleet.chats.session.\(entry.id)")
                    // Swipe right (leading): pin / unpin — the existing pin
                    // store, same identity as the drawer's pinned section.
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            Task { await togglePin(entry) }
                        } label: {
                            Label(
                                environment.isPinned(entry.pinIdentity) ? "Unpin" : "Pin",
                                systemImage: environment.isPinned(entry.pinIdentity) ? "pin.slash" : "pin"
                            )
                        }
                        .tint(theme.highlight)
                        .accessibilityIdentifier("fleet.chats.swipe.pin.\(entry.id)")
                    }
                    // Swipe left (trailing): archive + delete.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteEntry = entry
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier("fleet.chats.swipe.delete.\(entry.id)")
                        Button {
                            archiveLocally(entry)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(theme.textSecondary)
                        .accessibilityIdentifier("fleet.chats.swipe.archive.\(entry.id)")
                    }
                }
                if entries.isEmpty && environment.loadingRoutes.isEmpty && refreshFailure != .prominent {
                    // F4 (dogfood corrective pass): the empty state is
                    // filter-aware and never claims the user has no data when
                    // a filter merely hid usable conversations.
                    let empty = FleetChatsPresentation.emptyState(
                        hasQuery: !query.isEmpty,
                        hasGatewayFilter: gatewayID != nil,
                        hasUsableSessions: usableSessionCount > 0)
                    ContentUnavailableView(empty.title, systemImage: "bubble.left.and.bubble.right", description: Text(empty.description))
                }
            }
            if !query.isEmpty {
                Section {
                    Text("Search loaded conversations")
                        .font(.caption).foregroundStyle(theme.textSecondary)
                }
            }
        }
        // Surface id rides the List BEFORE overlays attach — a container id
        // applied after .overlay wraps the overlays too and REPLACES every
        // descendant identifier (QA-measured: the floating cluster surfaced
        // as 'fleet.chats'). Order matters.
        .accessibilityIdentifier("fleet.chats")
        .sheet(isPresented: $showingCompose) {
            ComposeBotPickerSheet(environment: environment)
        }
        .sheet(isPresented: $showingGroupCompose) {
            CreateRoomSheet(environment: environment) { room in
                environment.requestScreen(.room(room.id))
            }
        }
        .alert(
            "Delete conversation?",
            isPresented: Binding(
                get: { pendingDeleteEntry != nil },
                set: { if !$0 { pendingDeleteEntry = nil } }
            ),
            presenting: pendingDeleteEntry
        ) { entry in
            Button("Delete", role: .destructive) {
                Task { await deleteEntry(entry) }
                pendingDeleteEntry = nil
            }
            .accessibilityIdentifier("fleet.chats.delete.confirm")
            Button("Cancel", role: .cancel) { pendingDeleteEntry = nil }
        } message: { _ in
            Text("This removes the conversation from this device. It stays on the gateway.")
        }
        // Codex/ChatGPT-style floating action cluster: new chat (left) +
        // settings (right), Liquid Glass, hovering OVER the list.
        .overlay(alignment: .bottomTrailing) {
            floatingActionCluster
            .padding(.trailing, FleetTheme.spacingLg)
            .padding(.bottom, FleetTheme.spacingMd)
        }
        // The archived/deleted notice floats bottom-leading, same layer.
        .overlay(alignment: .bottomLeading) {
            if let archivedNotice {
                Text(archivedNotice)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, FleetTheme.spacingMd)
                    .padding(.vertical, FleetTheme.spacingSm)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.leading, FleetTheme.spacingLg)
                    .padding(.bottom, FleetTheme.spacingMd)
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        self.archivedNotice = nil
                    }
                    .accessibilityIdentifier("fleet.chats.archived.notice")
            }
        }
        // No bar on scroll: the nav bar keeps NO background at the scroll
        // edge (content scrolls under a permanently transparent edge).
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { hiddenEntryIDs = FleetChatsArchiveStore.hiddenIDs() }
        .scrollContentBackground(.hidden).background(theme.background)
        // Dogfood finding 3: reserve bottom breathing room with a SwiftUI
        // safe-area API (design-token value) so the final card comes to rest
        // clear of the iOS 26 floating tab bar instead of tucking under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: FleetChatsListLayout.bottomBreathingRoom)
                .accessibilityHidden(true)
        }
        .navigationTitle("Chats").searchable(text: $query, prompt: "Conversations and bots")
        .refreshable { await refresh(force: true) }.task { await refresh() }
    }

    /// Floating Liquid Glass action cluster (Codex-inspired): new chat to
    /// the LEFT of settings, bottom-trailing, hovering over the list.
    private var floatingActionCluster: some View {
        HStack(spacing: FleetTheme.spacingSm) {
            // New chat: menu keeps BOTH entry points (direct + group).
            Menu {
                Button {
                    showingCompose = true
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("fleet.chats.new")
                Button {
                    showingGroupCompose = true
                } label: {
                    Label("New Group", systemImage: "person.3")
                }
                .accessibilityIdentifier("fleet.chats.new-group")
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .background(.ultraThinMaterial)
            .buttonStyle(.fleetPressable)
            .accessibilityLabel("New chat")
            .accessibilityIdentifier("fleet.chats.new")

            // Settings: navigates to the Settings tab.
            Button {
                environment.requestSettingsTab()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.fleetPressable)
            .background(.ultraThinMaterial)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("fleet.chats.settings")
        }
    }

    // MARK: - Refresh failure surfaces (dogfood finding 1)

    /// Compact, inline partial-failure line: the truthful last-refresh caveat
    /// plus `Retry`, without displacing the conversations below it.
    private var inlineRefreshFailure: some View {
        HStack(alignment: .center, spacing: FleetTheme.spacingSm) {
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            // F2 (dogfood corrective pass): the surface id rides this LEAF. A
            // container `accessibilityIdentifier` overrides every descendant
            // id, which erased the Retry control's own id from the
            // accessibility tree (QA: `fleet.chats.refresh.retry` = 0 matches).
            Text("Some conversations could not refresh. Previously loaded chats may be out of date.")
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fleet.chats.refresh.inline")
            Spacer(minLength: FleetTheme.spacingSm)
            Button("Retry") { Task { await refresh(force: true) } }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.highlight)
                .buttonStyle(.borderless)
                // F3 (dogfood corrective pass): the shared 44pt control
                // pattern (FleetListRow's rule). A bare `.frame(minHeight:)`
                // leaves the accessibility frame at the label's intrinsic
                // size; the explicit hit shape makes the padded area the real
                // tap target without changing compact visual density.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("fleet.chats.refresh.retry")
        }
        .padding(.vertical, FleetTheme.spacingXs)
    }

    /// The stronger empty/error surface: no conversations could be loaded and
    /// none were retained. Replaces the first-run empty state when that would
    /// lie.
    private var prominentRefreshFailure: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            HStack(spacing: FleetTheme.spacingSm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityHidden(true)
                // F2: heading id rides this LEAF, never the wrapping container.
                Text("Could not load conversations")
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityIdentifier("fleet.chats.refresh.error")
            }
            Text(FleetChatsPresentation.prominentFailureDetail(
                failedRouteCount: reportedFailureRouteCount,
                totalRouteCount: currentRosterRoutes.count,
                // F5 (dogfood corrective pass): while the refresh is still
                // running, other routes have not returned yet — the surface
                // must not claim the rest returned no conversations.
                isRefreshing: !environment.loadingRoutes.isEmpty))
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") { Task { await refresh(force: true) } }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.highlight)
                .buttonStyle(.borderless)
                // F3: same shared 44pt control pattern as the inline surface.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("fleet.chats.refresh.retry")
        }
        .padding(.vertical, FleetTheme.spacingXs)
    }

    private func refresh(force: Bool = false) async {
        if environment.rosterSnapshot == nil { await environment.refreshRoster() }
        await environment.loadRooms()
        let routes = (environment.rosterSnapshot?.roster.allBots ?? []).map(\.route)
        guard !Task.isCancelled else { return }
        await environment.refreshSessions(routes: routes, force: force)
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

        // Groups — the verified unified room roster. Canonical identity, not
        // display name, is the command-center key.
        for room in environment.allRooms {
            let host = environment.gateway(for: room.id.gatewayID)?.displayName ?? room.id.gatewayID.rawValue
            items.append(Item(
                kind: .group,
                title: room.name,
                subtitle: "Group · \(host)",
                keywords: "group room \(room.id.key) \(host)",
                id: "group:\(room.canonicalIdentity)",
                screen: .room(room.id)
            ))
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
                            .accessibilityIdentifier("fleet.command-center.goto.\(tab.rawValue)")
                    }
                    // Card D: Artifacts is a pushed Fleet-stack destination, not
                    // a tab — the Command Center is the reachable entry on every
                    // width (the compact drawer carries it too).
                    if matches("Artifacts") {
                        Button {
                            dismiss()
                            navigate(.artifacts)
                        } label: {
                            Label("Artifacts", systemImage: "photo.on.rectangle")
                        }
                        .accessibilityIdentifier("fleet.command-center.goto.artifacts")
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
