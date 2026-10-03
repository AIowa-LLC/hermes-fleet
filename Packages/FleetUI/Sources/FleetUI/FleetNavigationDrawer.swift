import SwiftUI
import FleetCore

/// Shared drawer/sidebar content for compact iPhone and regular iPad layouts.
/// It has no connection lifecycle responsibilities: choosing a row only
/// changes the shell's typed navigation selection.
struct FleetNavigationDrawer: View {
    let environment: AppEnvironment
    let selection: FleetTab
    let compact: Bool
    let dismissGesture: AnyGesture<DragGesture.Value>
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
    @State private var hiddenIDs: Set<String> = []
    @State private var pendingDelete: FleetConversationIdentity?
    @State private var notice: String?

    private var visiblePins: [FleetConversationPin] {
        environment.pinnedConversations.filter {
            !hiddenIDs.contains(FleetChatsArchiveStore.entryID(for: $0.identity))
        }
    }

    private var primaryTabs: [FleetTab] {
        FleetTab.allCases.filter(\.isPrimary)
    }

    private var pinnedIDs: Set<String> {
        Set(environment.pinnedConversations.map(\.id))
    }

    private var recentEntries: [FleetChatEntry] {
        environment.sessionsByRoute
            .flatMap { route, sessions in
                sessions.filter {
                    FleetChatsPresentation.isRecentConversation($0) &&
                    !environment.isCanonicalBotChat(route: route, sessionID: $0.id)
                }.map { FleetChatEntry(route: route, session: $0) }
            }
            .filter { environment.gateway(for: $0.route.gatewayID) != nil && !hiddenIDs.contains($0.id) }
            .sorted {
                let left = FleetChatsPresentation.recency($0.session)
                let right = FleetChatsPresentation.recency($1.session)
                if left == right { return $0.id < $1.id }
                return left > right
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
        List {
            Group {
                header
                    .simultaneousGesture(dismissGesture)
                    .padding(.top, FleetTheme.spacingLg)
                    .padding(.bottom, FleetTheme.spacingMd)
                primarySection
                    .simultaneousGesture(dismissGesture)
                    .padding(.bottom, FleetTheme.spacingMd)
                sectionHeading("Pinned")
                ForEach(visiblePins) { pin in
                    conversationRow(pin: pin)
                        .modifier(ConversationSwipeActions(
                            identity: pin.identity, pinned: true, theme: theme,
                            togglePin: {
                                onTogglePin(pin.identity, pin.title, pin.preview,
                                            pin.authoritativeGatewayID, pin.avatarKey)
                            }, archive: { hide(pin.identity, deleted: false) },
                            delete: { pendingDelete = pin.identity }))
                }
                sectionHeading("Recents")
                ForEach(recentEntries) { entry in
                    recentRow(entry)
                        .modifier(ConversationSwipeActions(
                            identity: entry.pinIdentity, pinned: false, theme: theme,
                            togglePin: {
                                onTogglePin(entry.pinIdentity, entry.session.title,
                                            SessionPreviewText.humanReadable(entry.session.preview), nil, nil)
                            }, archive: { hide(entry.pinIdentity, deleted: false) },
                            delete: { pendingDelete = entry.pinIdentity }))
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: FleetTheme.spacingMd,
                                      bottom: 0, trailing: FleetTheme.spacingMd))
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 44)
        .listRowSpacing(0)
        .scrollContentBackground(.hidden)
        // Drawer polish: the scrollbar indicator is chrome noise on a
        // compact drawer — hidden; scrolling/momentum/dismiss untouched.
        .scrollIndicators(.hidden)
        .background(theme.background)
        .accessibilityIdentifier("fleet.drawer")
        .onAppear {
            hiddenIDs = FleetChatsArchiveStore.hiddenIDs()
            guard compact else { return }
            if !reduceMotion { headerFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: FleetChatsArchiveStore.didChange)) { _ in
            hiddenIDs = FleetChatsArchiveStore.hiddenIDs()
        }
        .alert("Delete conversation?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { hide(pendingDelete, deleted: true) }
                pendingDelete = nil
            }
            .accessibilityIdentifier("fleet.drawer.delete.confirm")
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the conversation from this device. It stays on the gateway.")
        }
        // ChatGPT parity: the compose affordance and Settings float in a
        // pinned footer — always reachable regardless of scroll position.
        // AX RULE: the surface id attaches BEFORE this inset — a container
        // identifier applied after floating chrome wraps it and swallows
        // every descendant id (measured: footer buttons vanished from the
        // AX tree while list rows stayed visible).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                if let notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, FleetTheme.spacingMd)
                        .accessibilityIdentifier("fleet.drawer.archived.notice")
                        .task(id: notice) {
                            try? await Task.sleep(for: .seconds(3))
                            if !Task.isCancelled { self.notice = nil }
                        }
                }
                footer
                    .simultaneousGesture(dismissGesture)
            }
        }
    }

    /// ChatGPT-parity header: one bold title and the circular search
    /// (ADR-0008: the ✕ close is retired — the drawer dismisses via
    /// scrim tap, destination select, or a left swipe). The wide
    /// Search / New Chat pills are gone — Search lives here as a
    /// circle, the compose pill lives in the pinned footer.
    private var header: some View {
        HStack(spacing: FleetTheme.spacingMd) {
            Text("Hermes Fleet")
                .font(.title2.weight(.bold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            circleAction("Search", systemImage: "magnifyingglass", action: onSearch,
                         identifier: "fleet.drawer.search")
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
                        .font(.body.weight(selection == tab ? .semibold : .regular))
                        .imageScale(.large)
                        .foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FleetTheme.spacingMd)
                        .padding(.vertical, 12)
                        .background(
                            selection == tab ? FleetTheme.neutralFill : .clear,
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
                    .imageScale(.large)
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, FleetTheme.spacingMd)
                    .padding(.vertical, 12)
                    .background(
                        artifactsActive ? FleetTheme.neutralFill : .clear,
                        in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityValue(artifactsActive ? "Selected" : "")
            .accessibilityAddTraits(artifactsActive ? .isSelected : [])
            .accessibilityIdentifier("fleet.drawer.destination.artifacts")
        }
    }

    /// Codex-parity pinned footer (ADR-0008): the compose pill leads, the
    /// glass Settings control sits at the drawer's trailing edge.
    /// Identifiers are unchanged (contract stability) — only position moved.
    /// The pill follows the active theme highlight (ADR-0009): fill
    /// theme.highlight, ink theme.onHighlight — the guaranteed-legible ink
    /// seam, so any accent (incl. the mono White) renders >= 4.5:1 content.
    private var footer: some View {
        HStack(spacing: FleetTheme.spacingMd) {
            Button(action: onNewChat) {
                Label("Chat", systemImage: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.onHighlight)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(theme.highlight, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("fleet.drawer.new-chat")

            Spacer(minLength: 0)

            // Dogfood round 2: the About drawer circle is retired — About
            // is reached from the Settings root's About row (ADR-0011).

            Button { onSelectTab(.settings) } label: {
                Image(systemName: FleetTab.settings.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityValue(selection == .settings ? "Selected" : "")
            .accessibilityAddTraits(selection == .settings ? .isSelected : [])
            .accessibilityIdentifier("fleet.drawer.destination.settings")
        }
        .padding(.horizontal, FleetTheme.spacingMd)
        .padding(.top, FleetTheme.spacingSm)
        .padding(.bottom, FleetTheme.spacingSm)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(FleetTheme.sectionHeaderFont)
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, FleetTheme.spacingSm)
            .padding(.top, FleetTheme.spacingMd)
            .padding(.bottom, FleetTheme.spacingSm)
            .accessibilityAddTraits(.isHeader)
    }

    private func hide(_ identity: FleetConversationIdentity, deleted: Bool) {
        FleetChatsArchiveStore.setHidden(FleetChatsArchiveStore.entryID(for: identity), hidden: true)
        hiddenIDs = FleetChatsArchiveStore.hiddenIDs()
        notice = deleted ? "Removed from this device" : "Archived on this device"
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
                .background(FleetTheme.neutralFill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func conversationRow(pin: FleetConversationPin) -> some View {
        // Codex-style row diet: title + muted secondary only. No avatar, no
        // pin glyph — conversation organization lives in swipe actions.
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
            // A plain Button hit-tests only drawn pixels: without a shape the
            // blank space right of the title was dead (Build 96 feedback).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("fleet.drawer.pinned.\(pin.id)")
    }

    private func recentRow(_ entry: FleetChatEntry) -> some View {
        let identity = FleetConversationIdentity.individual(route: entry.route, sessionID: entry.session.id)
        let title = entry.session.title.isEmpty ? "Untitled conversation" : entry.session.title
        let isUnread = environment.isConversationUnread(route: entry.route, session: entry.session)
        return HStack(spacing: FleetTheme.spacingSm) {
            Button { onOpenConversation(entry.route, entry.session.id) } label: {
                conversationLabel(
                    title: title,
                    identity: identity,
                    unavailable: false,
                    isUnread: isUnread,
                    unreadIdentifier: "fleet.drawer.recent.unread.\(entry.id)"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("fleet.drawer.recent.\(entry.id)")
        }
        .accessibilityElement(children: .contain)
    }

    private func conversationLabel(
        title: String,
        identity: FleetConversationIdentity,
        unavailable: Bool,
        isUnread: Bool,
        unreadIdentifier: String
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
            if isUnread {
                Circle()
                    .fill(theme.highlight)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Unread")
                    .accessibilityIdentifier(unreadIdentifier)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityLabel(
            unavailable ? "\(title), unavailable" : isUnread ? "\(title), unread" : title)
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
}

/// Native list actions also expose accessible actions without a drag.
private struct ConversationSwipeActions: ViewModifier {
    let identity: FleetConversationIdentity
    let pinned: Bool
    let theme: FleetThemeValues
    let togglePin: () -> Void
    let archive: () -> Void
    let delete: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button(action: togglePin) {
                    Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
                }
                .tint(theme.swipeActionTint)
                .accessibilityIdentifier("fleet.drawer.swipe.pin.\(identity.id)")
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive, action: delete) {
                    Label("Delete", systemImage: "trash")
                }
                .tint(theme.destructiveSwipeTint)
                .accessibilityIdentifier("fleet.drawer.swipe.delete.\(identity.id)")
                Button(action: archive) {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(theme.archiveSwipeTint)
                .accessibilityIdentifier("fleet.drawer.swipe.archive.\(identity.id)")
            }
    }
}
