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
            }
            .padding(.horizontal, FleetTheme.spacingMd)
            .padding(.top, FleetTheme.spacingLg)
            .padding(.bottom, FleetTheme.spacingLg)
        }
        // Drawer polish: the scrollbar indicator is chrome noise on a
        // compact drawer — hidden; scrolling/momentum/dismiss untouched.
        .scrollIndicators(.hidden)
        .background(theme.background)
        .accessibilityIdentifier("fleet.drawer")
        .onAppear {
            guard compact else { return }
            if !reduceMotion { headerFocused = true }
        }
        // ChatGPT parity: the compose affordance and Settings float in a
        // pinned footer — always reachable regardless of scroll position.
        // AX RULE: the surface id attaches BEFORE this inset — a container
        // identifier applied after floating chrome wraps it and swallows
        // every descendant id (measured: footer buttons vanished from the
        // AX tree while ScrollView rows stayed visible).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
    }

    /// ChatGPT-parity header: one bold title, circular search, circular
    /// close (compact only). The wide Search / New Chat pills are gone —
    /// Search lives here as a circle, New Chat lives in the pinned footer.
    private var header: some View {
        HStack(spacing: FleetTheme.spacingMd) {
            Text("Hermes Fleet")
                .font(.title2.weight(.bold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            circleAction("Search", systemImage: "magnifyingglass", action: onSearch,
                         identifier: "fleet.drawer.search")
            if compact {
                circleAction("Close", systemImage: "xmark", action: onClose,
                             identifier: "fleet.drawer.close")
            }
        }
        .accessibilityFocused($headerFocused)
    }

    /// ChatGPT parity: primary destinations render directly under the
    /// header — no section wrapper.
    private var primarySection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            ForEach(primaryTabs) { tab in
                Button { onSelectTab(tab) } label: {
                    Label(tab.label, systemImage: tab.systemImage)
                        .font(.title3.weight(selection == tab ? .semibold : .regular))
                        .imageScale(.large)
                        .foregroundStyle(selection == tab ? theme.highlight : theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FleetTheme.spacingMd)
                        .padding(.vertical, 13)
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
                    .font(.title3.weight(artifactsActive ? .semibold : .regular))
                    .imageScale(.large)
                    .foregroundStyle(artifactsActive ? theme.highlight : theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, FleetTheme.spacingMd)
                    .padding(.vertical, 13)
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
            // ChatGPT parity: no empty-state caption — an empty section
            // renders just its header.
            ForEach(environment.pinnedConversations) { pin in
                conversationRow(pin: pin, isRecent: false)
            }
        }
    }

    private var recentSection: some View {
        drawerSection("Recents") {
            ForEach(recentEntries) { entry in
                recentRow(entry)
            }
        }
    }

    /// ChatGPT-parity pinned footer: the accent compose pill and the
    /// circular Settings button float at the drawer's bottom edge.
    /// Identifiers are unchanged (contract stability) — only position moved.
    /// Pill text uses the canvas color: dark-mode lavender accent carries
    /// near-black text, light-mode deep violet carries near-white text.
    private var footer: some View {
        HStack(spacing: FleetTheme.spacingMd) {
            Button(action: onNewChat) {
                Label("New Chat", systemImage: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.background)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(theme.highlight, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("fleet.drawer.new-chat")

            Button { onSelectTab(.settings) } label: {
                Image(systemName: FleetTab.settings.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityValue(selection == .settings ? "Selected" : "")
            .accessibilityAddTraits(selection == .settings ? .isSelected : [])
            .accessibilityIdentifier("fleet.drawer.destination.settings")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, FleetTheme.spacingMd)
        .padding(.top, FleetTheme.spacingSm)
        .padding(.bottom, FleetTheme.spacingSm)
    }

    private func drawerSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, FleetTheme.spacingSm)
            content()
        }
    }

    /// Circular header action (ChatGPT parity: search/close are circles,
    /// not wide pills).
    private func circleAction(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void,
        identifier: String
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 34, height: 34)
                .background(theme.surfaceElevated, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
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
            .padding(.vertical, 10)
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
        identity: FleetConversationIdentity,
        unavailable: Bool
    ) -> some View {
        HStack(spacing: FleetTheme.spacingSm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.regular))
                    .foregroundStyle(unavailable ? theme.textSecondary : theme.textPrimary)
                    .lineLimit(1)
                if unavailable {
                    Text("Unavailable")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityLabel(unavailable ? "\(title), unavailable" : title)
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

    private func gatewayName(_ id: GatewayID) -> String {
        environment.gateway(for: id)?.displayName ?? id.rawValue
    }
}
