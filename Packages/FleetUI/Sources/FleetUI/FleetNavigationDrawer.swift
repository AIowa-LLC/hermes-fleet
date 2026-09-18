import SwiftUI
import FleetCore

/// Shared drawer/sidebar content for compact iPhone and regular iPad layouts.
/// It has no connection lifecycle responsibilities: choosing a row only
/// changes the shell's typed navigation selection.
struct FleetNavigationDrawer: View {
    let environment: AppEnvironment
    let selection: FleetTab
    let compact: Bool
    let onClose: () -> Void
    let onSearch: () -> Void
    let onNewChat: () -> Void
    let onSelectTab: (FleetTab) -> Void
    let onOpenConversation: (Route, String) -> Void
    let onTogglePin: (
        FleetConversationIdentity, String, String, GatewayID?, String?
    ) -> Void
    /// Card D: open a pushed destination (Artifacts) on its owning stack.
    let onOpenScreen: (FleetScreen) -> Void
    /// Card D: whether the Artifacts destination is the active Fleet screen
    /// (highlight state — restored navigation included).
    let artifactsActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fleetTheme) private var theme
    @AccessibilityFocusState private var headerFocused: Bool

    private var primaryTabs: [FleetTab] {
        FleetTab.allCases.filter(\.isPrimary)
    }

    private var pinnedIDs: Set<String> {
        Set(environment.pinnedConversations.map(\.id))
    }

    private var recentEntries: [FleetChatEntry] {
        environment.sessionsByRoute
            .flatMap { route, sessions in
                sessions.map { FleetChatEntry(route: route, session: $0) }
            }
            .filter { environment.gateway(for: $0.route.gatewayID) != nil }
            .sorted {
                if $0.session.startedAt == $1.session.startedAt { return $0.id < $1.id }
                return $0.session.startedAt > $1.session.startedAt
            }
            .filter {
                !pinnedIDs.contains(
                    FleetConversationIdentity.individual(
                        route: $0.route, sessionID: $0.session.id
                    ).id
                )
            }
            .prefix(12)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
                header
                primarySection
                pinnedSection
                recentSection
                Divider()
                    .overlay(theme.border)
                settingsRow
            }
            .padding(.horizontal, FleetTheme.spacingMd)
            .padding(.top, FleetTheme.spacingLg)
            .padding(.bottom, FleetTheme.spacingLg)
        }
        .background(theme.background)
        .accessibilityIdentifier("fleet.drawer")
        .onAppear {
            guard compact else { return }
            if !reduceMotion { headerFocused = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            HStack(spacing: FleetTheme.spacingSm) {
                Image("FleetWingMark", bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .accessibilityLabel("Hermes Fleet")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hermes Fleet")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Your agents. Within reach.")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if compact {
                    Button("Close", systemImage: "xmark") { onClose() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("fleet.drawer.close")
                }
            }
            .accessibilityFocused($headerFocused)

            HStack(spacing: FleetTheme.spacingSm) {
                drawerAction("Search", systemImage: "magnifyingglass", action: onSearch,
                             identifier: "fleet.drawer.search")
                drawerAction("New Chat", systemImage: "square.and.pencil", action: onNewChat,
                             identifier: "fleet.drawer.new-chat")
            }
        }
    }

    private var primarySection: some View {
        drawerSection("Navigate") {
            ForEach(primaryTabs) { tab in
                Button { onSelectTab(tab) } label: {
                    Label(tab.label, systemImage: tab.systemImage)
                        .font(.body.weight(selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? theme.highlight : theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FleetTheme.spacingMd)
                        .padding(.vertical, 11)
                        .background(
                            selection == tab ? theme.highlight.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityValue(selection == tab ? "Selected" : "")
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("fleet.drawer.destination.\(tab.rawValue)")
            }
            // Card D: Artifacts (observed generated media) is a pushed
            // destination on the Fleet stack — not a tab: the five-tab
            // architecture, pins, recents and nav-restore stay untouched.
            Button { onOpenScreen(.artifacts) } label: {
                Label("Artifacts", systemImage: "photo.on.rectangle")
                    .font(.body.weight(artifactsActive ? .semibold : .regular))
                    .foregroundStyle(artifactsActive ? theme.highlight : theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, FleetTheme.spacingMd)
                    .padding(.vertical, 11)
                    .background(
                        artifactsActive ? theme.highlight.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityValue(artifactsActive ? "Selected" : "")
            .accessibilityAddTraits(artifactsActive ? .isSelected : [])
            .accessibilityIdentifier("fleet.drawer.destination.artifacts")
        }
    }

    private var pinnedSection: some View {
        drawerSection("Pinned") {
            if environment.pinnedConversations.isEmpty {
                emptySectionText("Pin a conversation to keep it here.", identifier: "fleet.drawer.pinned.empty")
            } else {
                ForEach(environment.pinnedConversations) { pin in
                    conversationRow(pin: pin, isRecent: false)
                }
            }
        }
    }

    private var recentSection: some View {
        drawerSection("Recent chats") {
            if recentEntries.isEmpty {
                emptySectionText("Your recent conversations will appear here.", identifier: "fleet.drawer.recent.empty")
            } else {
                ForEach(recentEntries) { entry in
                    recentRow(entry)
                }
            }
        }
    }

    private var settingsRow: some View {
        Button { onSelectTab(.settings) } label: {
            Label("Settings", systemImage: FleetTab.settings.systemImage)
                .font(.body.weight(selection == .settings ? .semibold : .regular))
                .foregroundStyle(selection == .settings ? theme.highlight : theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FleetTheme.spacingMd)
                .padding(.vertical, 11)
                .background(
                    selection == .settings ? theme.highlight.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                )
        }
        .buttonStyle(.plain)
        .accessibilityValue(selection == .settings ? "Selected" : "")
        .accessibilityAddTraits(selection == .settings ? .isSelected : [])
        .accessibilityIdentifier("fleet.drawer.destination.settings")
    }

    private func drawerSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Text(title.uppercased())
                .font(FleetTheme.sectionHeaderFont)
                .tracking(0.8)
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, FleetTheme.spacingSm)
            content()
        }
    }

    private func drawerAction(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void,
        identifier: String
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, FleetTheme.spacingSm)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textPrimary)
        .accessibilityIdentifier(identifier)
    }

    private func conversationRow(pin: FleetConversationPin, isRecent: Bool) -> some View {
        // Codex-style row diet: title + muted secondary only. No avatar, no
        // pin glyph — pinning is managed by swipe on the Chats list.
        let unavailable = !isAvailable(pin)
        return Button {
            open(pin)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.title.isEmpty ? "Untitled conversation" : pin.title)
                    .font(.body.weight(.regular))
                    .foregroundStyle(unavailable ? theme.textSecondary : theme.textPrimary)
                    .lineLimit(1)
                if unavailable {
                    Text("Last synced — reconnect to open")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FleetTheme.spacingMd)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("fleet.drawer.pinned.\(pin.id)")
    }

    private func recentRow(_ entry: FleetChatEntry) -> some View {
        let identity = FleetConversationIdentity.individual(route: entry.route, sessionID: entry.session.id)
        let title = entry.session.title.isEmpty ? "Untitled conversation" : entry.session.title
        return HStack(spacing: FleetTheme.spacingSm) {
            Button { onOpenConversation(entry.route, entry.session.id) } label: {
                conversationLabel(
                    title: title,
                    subtitle: "\(entry.route.profileSlug.rawValue) · \(gatewayName(entry.route.gatewayID))",
                    identity: identity,
                    unavailable: false
                )
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .contain)
    }

    private func conversationLabel(
        title: String,
        subtitle: String,
        identity: FleetConversationIdentity,
        unavailable: Bool
    ) -> some View {
        HStack(spacing: FleetTheme.spacingSm) {
            if identity.isGroup {
                Image(systemName: "person.3")
                    .font(.body)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(unavailable ? theme.textSecondary : theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(unavailable ? "Unavailable · \(subtitle)" : subtitle)
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityLabel(unavailable ? "\(title), unavailable, \(subtitle)" : "\(title), \(subtitle)")
    }

    private func emptySectionText(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, FleetTheme.spacingSm)
            .accessibilityIdentifier(identifier)
    }

    private func isAvailable(_ pin: FleetConversationPin) -> Bool {
        switch pin.identity {
        case .individual(let route, _):
            // An offline registered gateway is still an exact, safe route:
            // ConversationView can show cached history and its explicit
            // reconnect state. A removed gateway is not routable.
            return environment.gateway(for: route.gatewayID) != nil
        case .group:
            // Group presentation is owned by the fleet-wide group surface.
            // Keep persisted rows visible until that surface can resolve its
            // authoritative host; never route by display name.
            return false
        }
    }

    private func open(_ pin: FleetConversationPin) {
        guard isAvailable(pin) else { return }
        if case .individual(let route, let sessionID) = pin.identity {
            onOpenConversation(route, sessionID)
        }
    }

    private func avatarName(for identity: FleetConversationIdentity) -> String {
        guard case .individual(let route, _) = identity else { return "Group" }
        return environment.bot(for: route)?.displayName ?? route.profileSlug.rawValue
    }

    private func provenance(for pin: FleetConversationPin) -> String {
        switch pin.identity {
        case .individual(let route, _):
            return "\(route.profileSlug.rawValue) · \(gatewayName(route.gatewayID))"
        case .group:
            if let gatewayID = pin.authoritativeGatewayID {
                return "Group · \(gatewayName(gatewayID))"
            }
            return "Group"
        }
    }

    private func gatewayName(_ id: GatewayID) -> String {
        environment.gateway(for: id)?.displayName ?? id.rawValue
    }
}
