import SwiftUI
import FleetCore

extension EnvironmentValues {
    @Entry var openFleetDrawer: (@MainActor () -> Void)? = nil
}

/// Also used by the few locally pushed conversation destinations.
struct FleetDrawerMenu: ToolbarContent {
    @Environment(\.openFleetDrawer) private var openDrawer
    /// Dogfood r4: the unread aggregate (menu-button badge), supplied by
    /// the OWNING view (FleetTabView holds the AppEnvironment; there is no
    /// environment-object injection on this shell).
    var showsUnreadBadge: Bool = false

    var body: some ToolbarContent {
        if let openDrawer {
            ToolbarItem(placement: .topBarLeading) {
                // Dogfood r3: the ChatGPT two-line mark, CUSTOM-DRAWN —
                // `equals` is not a real SF Symbol (CoreGlyphs check
                // 2026-09-19) and rendered as a blank glyph inside the
                // glass. Two capsule bars render identically on every OS.
                // `.ultraThinMaterial` keeps XCUITest taps working (the
                // .glassEffect() look computes hit point {-1,-1}).
                Button(action: openDrawer) {
                    VStack(spacing: 5) {
        Capsule().fill(Color.primary).frame(width: 15, height: 2.5)
        Capsule().fill(Color.primary).frame(width: 15, height: 2.5)
                    }
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                    // Dogfood r4: unread badge (ChatGPT parity) — a small
                    // accent dot at the glass circle's top-right edge.
                    if showsUnreadBadge {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                            .offset(x: 10, y: -10)
                            .accessibilityLabel("Unread conversations")
                            .accessibilityIdentifier("fleet.menu.unread-badge")
                    }
                }
                .accessibilityLabel(showsUnreadBadge ? "Menu, unread conversations" : "Menu")
                .accessibilityIdentifier("fleet.drawer.open")
                .keyboardShortcut("m", modifiers: .command)
            }
        }
    }
}

public enum FleetTab: String, Hashable, Sendable, CaseIterable, Identifiable, Codable {
    /// Build 43 order: Bots / Chats / Kanban / Fleet / Settings — Bots is
    /// the normal launch tab; Kanban is a first-class owning surface; the
    /// Gateways tab is retired (gateway management lives under Fleet).
    /// ADR-0010: Groups is a first-class tab directly under Chats.
    /// ADR-0011: About is a first-class tab directly after Settings
    /// (identity, version, legal, support).
    case bots, chats, groups, cron, kanban, fleet, settings, about
    public var id: String { rawValue }
    /// Drawer: the primary destinations render in the Navigate section;
    /// Settings and About render as the drawer's dedicated trailing rows.
    public var isPrimary: Bool { self != .settings && self != .about }
    public var label: String {
        switch self {
        case .bots: "Bots"
        case .chats: "Chats"
        case .groups: "Groups"
        case .cron: "Scheduled"
        case .kanban: "Kanban"
        case .fleet: "Fleet"
        case .settings: "Settings"
        case .about: "About"
        }
    }
    public var systemImage: String {
        switch self {
        case .bots: "cpu"
        case .chats: "bubble.left.and.bubble.right"
        case .groups: "person.3"
        case .cron: "clock"
        case .kanban: "rectangle.split.3x1"
        case .fleet: "square.grid.2x2"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// Adaptive system navigation; every tab owns its stack and the lock gate owns all content.
public struct FleetTabView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment
    private let lockController: AppLockController
    @State private var navigation = FleetNavigationState()
    @State private var restored = false
    @State private var showingCommandCenter = false
    @State private var autoNavHandled = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawerPresented = false
    /// ADR-0008: live left-swipe offset while the drawer is presented.
    @State private var drawerDrag: CGFloat = 0
    @State private var visitedDestinations: Set<FleetTab> = []

    public init(environment: AppEnvironment, lockController: AppLockController) {
        self.environment = environment
        self.lockController = lockController
    }

    public var body: some View {
        Group {
            if lockController.isLocked {
                AppLockView(controller: lockController)
            } else {
                // First-run gate (Hermex-style lifecycle): before the
                // registry has hydrated we show the launch continuation (the
                // splash overlay covers this window on cold launch); once
                // hydration settles, a ZERO-gateway fleet lands on the
                // first-server setup experience INSTEAD of the normal tab
                // UI — a brand-new user must understand Fleet needs a Hermes
                // server before entering the cockpit. The gate is driven by
                // the hydrated registry itself (no hasSeenOnboarding flag):
                // registering the first gateway swaps in the normal app, and
                // removing the final gateway returns to setup (intended).
                switch environment.hydrationPhase {
                case .loading:
                    ProgressView("Starting…")
                        .accessibilityIdentifier("fleet.root.loading")
                case .unconfigured:
                    FirstRunSetupView(environment: environment)
                case .configured:
                    tabShell
                }
            }
        }
        .onChange(of: navigation) { _, state in
            guard restored else { return }
            if let data = try? JSONEncoder().encode(state) {
                UserDefaults.standard.set(data, forKey: FleetNavigationState.storageKey)
            }
        }
        .tint(theme.highlight)
        .onChange(of: lockController.isLocked) { if lockController.isLocked { showingCommandCenter = false; drawerPresented = false } }
        .onChange(of: navigation.selection) { _, _ in
            drawerPresented = false
        }
        .onChange(of: environment.pendingBotChatNavigation) { target in
            guard let target else { return }
            navigation.open(target)
            environment.pendingBotChatNavigation = nil
        }
        .onChange(of: environment.pendingScreenNavigation) { target in
            guard let target else { return }
            navigation.open(target)
            environment.pendingScreenNavigation = nil
        }
        .onChange(of: environment.pendingSettingsTabRequest) { requested in
            guard requested else { return }
            navigation.selection = .settings
            drawerPresented = false
            environment.pendingSettingsTabRequest = false
        }
        .task {
            if !restored {
                if ProcessInfo.processInfo.environment["HERMES_FLEET_AUTO_NAV"] == nil && ProcessInfo.processInfo.environment["HERMES_FLEET_NAV_RESET"] != "1" {
                    navigation = .restore(UserDefaults.standard.data(forKey: FleetNavigationState.storageKey))
                }
                restored = true
            }
            // UI-test hygiene: NAV_RESET also clears persisted explicit
            // profile selections so the §8 chooser deterministically renders
            // (a stored choice would otherwise skip straight into the pane).
            // Pinned conversations clear EARLIER — at AppEnvironment.load():
            // they hydrate eagerly, before this block runs (ConversationPinning).
            if ProcessInfo.processInfo.environment["HERMES_FLEET_NAV_RESET"] == "1" {
                GatewayResourceView.resetStoredSelections()
                FleetChatsArchiveStore.resetForUITests()
                // Dogfood r4: read watermarks are persisted state — reset
                // them with the same hygiene window (leak = phantom dots).
                environment.resetUnreadStateForUITests()
                // ADR-0012 (W8b): the launch cache is persisted state too —
                // a cached fleet from an earlier suite must not paint in a
                // hermetic run (unless the suite seeds the fixture knob).
                if ProcessInfo.processInfo.environment["HERMES_FLEET_LAUNCH_CACHE_FIXTURE"] != "1" {
                    await environment.resetLaunchCacheForUITests()
                }
            }
            // Build 41: KANBAN_BOARD_RESET (deliberately separate from
            // NAV_RESET — board-selection persistence is product behavior
            // the B1 suite asserts) clears board selections for
            // board-content determinism.
            if ProcessInfo.processInfo.environment["HERMES_FLEET_KANBAN_BOARD_RESET"] == "1" {
                KanbanBoardSelectionStore.clearAllPersistedSelections()
            }
            await performAutoNavIfNeeded()
        }
    }

    /// Compact navigation keeps visited stacks mounted: switching sections must
    /// not discard drafts or tear down a streaming conversation. Regular width
    /// retains the system sidebar. Both presentations use the same durable paths.
    private var tabShell: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Group {
                    if horizontalSizeClass == .regular {
                        tabs
                    } else {
                        ZStack {
                            ForEach(FleetTab.allCases) { tab in
                                if tab == navigation.selection || visitedDestinations.contains(tab) {
                                    navigationStack(tab)
                                        .opacity(tab == navigation.selection ? 1 : 0)
                                        .allowsHitTesting(tab == navigation.selection && !drawerPresented)
                                        .accessibilityHidden(tab != navigation.selection || drawerPresented)
                                        .zIndex(tab == navigation.selection ? 1 : 0)
                                }
                            }
                        }
                    }
                }
                .onAppear { visitedDestinations.insert(navigation.selection) }
                .onChange(of: navigation.selection) { old, new in
                    visitedDestinations.formUnion([old, new])
                }
                if drawerPresented {
                    FleetTheme.drawerScrim
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { drawerPresented = false }
                        .accessibilityLabel("Close navigation drawer")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("fleet.drawer.scrim")
                        .zIndex(1)
                    FleetNavigationDrawer(
                        environment: environment,
                        selection: navigation.selection,
                        compact: true,
                        onSearch: { showingCommandCenter = true },
                        onNewChat: {
                            navigation.selection = .chats
                            navigation.paths[.chats] = [.roster]
                            drawerPresented = false
                        },
                        onSelectTab: { tab in
                            if navigation.selection == tab {
                                // Re-selecting the current destination is the
                                // conventional pop-to-root affordance.
                                navigation.paths[tab] = []
                            }
                            navigation.selection = tab
                            drawerPresented = false
                        },
                        onOpenConversation: { route, sessionID in
                            guard environment.gateway(for: route.gatewayID) != nil else { return }
                            navigation.selection = .chats
                            navigation.paths[.chats] = [.conversation(route, sessionID: sessionID, canonical: false)]
                            drawerPresented = false
                        },
                        onTogglePin: { identity, title, preview, gatewayID, avatarKey in
                            Task {
                                if environment.isPinned(identity) {
                                    await environment.unpinConversation(identity)
                                } else {
                                    await environment.pinConversation(
                                        identity: identity,
                                        title: title,
                                        preview: preview,
                                        authoritativeGatewayID: gatewayID,
                                        avatarKey: avatarKey
                                    )
                                }
                            }
                        },
                        onOpenScreen: { screen in
                            navigation.open(screen)
                            drawerPresented = false
                        },
                        artifactsActive: navigation.selection == .fleet
                            && navigation.paths[.fleet]?.last == .artifacts
                    )
                    .frame(width: min(340, geometry.size.width * 0.78))
                    .frame(maxHeight: .infinity)
                    .background(theme.background)
                    .offset(x: drawerDrag)
                    .simultaneousGesture(
                        drawerSwipeGesture(width: min(340, geometry.size.width * 0.78)))
                    .transition(reduceMotion ? .identity : .move(edge: .leading))
                    .zIndex(2)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: drawerPresented)
        .environment(\.openFleetDrawer, drawerAction)
        .onChange(of: horizontalSizeClass) { _, _ in drawerPresented = false }
        .sheet(isPresented: $showingCommandCenter) {
            FleetCommandCenter(environment: environment, navigate: { screen in
                navigation.open(screen)
            }, selectTab: { navigation.selection = $0 })
        }
    }

    /// ADR-0008 (Codex parity): interactive left-swipe dismissal. The
    /// drawer follows a horizontal drag, springs back under threshold, and
    /// dismisses past 25% of its width (or a decisive flick). Reduce Motion
    /// skips the live follow — the threshold still dismisses.
    private func drawerSwipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard !reduceMotion else { return }
                let t = value.translation
                // Axis lock: horizontal-dominant drags only — a mostly
                // vertical drag belongs to the drawer's ScrollView.
                guard abs(t.width) > abs(t.height) else { return }
                drawerDrag = min(0, t.width)
            }
            .onEnded { value in
                let threshold = max(80, width * 0.25)
                let flicksAway = value.predictedEndTranslation.width < -160
                if value.translation.width < -threshold || flicksAway {
                    drawerDrag = 0
                    drawerPresented = false
                } else {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        drawerDrag = 0
                    }
                }
            }
    }

    private var drawerAction: (@MainActor () -> Void)? {
        // The drawer is universal now: on iPad the top control hosts only
        // the five PRIMARY destinations (sidebarAdaptable paginates past
        // five), so Settings — and the full destination list — needs the
        // drawer on regular width too. Compact keeps its single surface.
        { drawerPresented = true }
    }

    /// All six destinations stay HOSTED: on regular-width iPad the top
    /// control paginates past five (UIKit hides the trailing bar button),
    /// but a paginated Tab still RENDERS when selected programmatically —
    /// and the universal drawer is the always-visible entry that selects
    /// Settings (and everything else). Compact iPhone is unaffected: the
    /// drawer owns navigation there regardless.
    private var hostedTabs: [FleetTab] {
        FleetTab.allCases
    }

    private var tabs: some View {
        TabView(selection: Binding(get: { navigation.selection }, set: { tab in
            navigation.selection = tab
        })) {
            ForEach(hostedTabs) { tab in
                Tab(tab.label, systemImage: tab.systemImage, value: tab) {
                    navigationStack(tab)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    private func navigationStack(_ tab: FleetTab) -> some View {
        NavigationStack(path: Binding(get: { navigation.paths[tab] ?? [] }, set: { path in
            if let target = path.last, path.count > (navigation.paths[tab]?.count ?? 0) {
                navigation.open(target)
            } else {
                navigation.paths[tab] = path
            }
        })) {
            root(tab)
                .toolbar { rootShellToolbar }
                .navigationDestination(for: FleetScreen.self) { screen in
                    destination(screen)
                        .toolbar { destinationShellToolbar }
                }
        }
        .accessibilityIdentifier("fleet.tab.\(tab.rawValue)")
    }

    /// Tab roots host the Command Center affordance. Pushed destinations
    /// do NOT: their own toolbar content (e.g. the Kanban board's picker,
    /// add and menu) already fills the compact bar, and adding a fourth
    /// trailing item collapses the set into the system overflow — the
    /// board's Add Card became unreachable that way. Search stays one
    /// drawer-tap away on every screen.
    @ToolbarContentBuilder
    private var rootShellToolbar: some ToolbarContent {
        // Dogfood r4 (decisions 4–5): search is DRAWER-ONLY — the trailing
        // toolbar button (and its ⌘K shortcut) is retired. The drawer's
        // search circle (fleet.drawer.search) is the one entry.
        FleetDrawerMenu(showsUnreadBadge: environment.anyUnreadSessions)
    }

    @ToolbarContentBuilder
    private var destinationShellToolbar: some ToolbarContent {
        FleetDrawerMenu(showsUnreadBadge: environment.anyUnreadSessions)
    }

    @ViewBuilder private func root(_ tab: FleetTab) -> some View {
        switch tab {
        case .fleet: FleetDashboardView(environment: environment)
        case .chats: FleetChatsView(environment: environment)
        case .groups: GroupsHomeView(environment: environment)
        case .bots: FleetRosterView(environment: environment)
        case .kanban: KanbanHomeView(environment: environment)
        case .cron: CronHomeView(environment: environment)
        // Build 43: Settings is a first-class tab (was a Fleet-toolbar
        // sheet). The tab IS the settings destination; its stack stays at
        // the root screen. ADR-0011: the App Lock toggle moved into the
        // Security sub-screen; the root no longer needs the controllers.
        case .settings: FleetSettingsView(
            onSelectAbout: { navigation.selection = .about },
            onOpenGateways: { navigation.open(.gateways) })
        // ADR-0011: About — identity, version, Terms / Privacy / Support.
        case .about: FleetAboutView()
        }
    }

    @ViewBuilder
    private func destination(_ screen: FleetScreen) -> some View {
        if let id = screen.gatewayID, !environment.gateways.contains(where: { $0.id == id }), screen != .gatewayConnection(id) {
            ContentUnavailableView("Gateway unavailable", systemImage: "server.rack", description: Text("This saved destination belongs to a gateway that is no longer registered."))
        } else {
        switch screen {
        case .bots(let gatewayID):
            FleetRosterView(environment: environment, gatewayID: gatewayID)
        case .roster:
            FleetRosterView(environment: environment)
        case .botDetail(let route):
            BotDetailView(environment: environment, route: route)
        case .botRoutines(let route):
            BotRoutinesView(environment: environment, route: route)
        case .room(let id):
            if let room = environment.room(for: id) {
                RoomChatView(room: room, environment: environment)
            } else {
                ContentUnavailableView("Group unavailable", systemImage: "person.3", description: Text("This exact group has not been resolved. Refresh its gateway to try again."))
            }
        case .conversation(let route, let sessionID, _):
            ConversationView(environment: environment, route: route, sessionID: sessionID)
        case .health:
            HealthDashboardView(environment: environment)
        case .gateways:
            GatewaysView(environment: environment)
        case .activity:
            FleetActivityView(environment: environment)
        case .gatewayDetail(let id):
            GatewayDetailView(environment: environment, gatewayID: id)
        case .gatewayConnection(let id):
            GatewaysView(environment: environment, connectionGatewayID: id)
        case .gatewayGroups(let id):
            GatewayGroupsView(environment: environment, gatewayID: id)
        case .gatewayHealth(let id):
            HealthDashboardView(environment: environment, gatewayID: id)
        case .settingsSecurity:
            // ADR-0011 W3: the App Lock sub-screen owns the lock controller.
            FleetSettingsSecurityView(controller: lockController)
        case .settingsData:
            // ADR-0011 W4: Data & Storage owns the cache-clear flow.
            FleetSettingsDataView(environment: environment)
        case .kanban:
            // Legacy unscoped entry: land on the Kanban tab's chooser root
            // (the tab is the authoritative Kanban surface now).
            KanbanHomeView(environment: environment)
        case .artifacts:
            // Card D: the device-local Artifacts destination (Fleet stack).
            ArtifactsView(environment: environment)
        case .gatewayKanban(let id, let board):
            KanbanBoardView(environment: environment, gatewayID: id, board: board)
        case .cron(let id, let profile), .skills(let id, let profile), .memoryGraph(let id, let profile), .projects(let id, let profile, _):
            GatewayResourceView(environment: environment, gatewayID: id, screen: screen, profile: profile, focusPath: screen.focusPath) { selected in
                let scoped: FleetScreen
                switch screen {
                case .cron: scoped = .cron(id, profile: selected)
                case .skills: scoped = .skills(id, profile: selected)
                case .memoryGraph: scoped = .memoryGraph(id, profile: selected)
                case .projects(_, _, let path): scoped = .projects(id, profile: selected, focusPath: path)
                default: return
                }
                // Build 43: gateway-resource panes are pushed on the FLEET
                // stack (the Gateways tab no longer exists to host them).
                if let index = navigation.paths[.fleet]?.firstIndex(of: screen) {
                    navigation.paths[.fleet]?[index] = scoped
                }
            }
        }
        }
    }

    @MainActor private func performAutoNavIfNeeded() async {
        #if DEBUG
        guard !autoNavHandled, let autoNav = ProcessInfo.processInfo.environment["HERMES_FLEET_AUTO_NAV"] else { return }
        autoNavHandled = true
        await environment.load()
        await environment.refreshRoster()
        if let tab = FleetNavigationState.legacyTab(autoNav) { navigation.selection = tab }
        if autoNav == "command-center" { showingCommandCenter = true }
        // Build 43: "settings" selects the Settings TAB (was: the sheet).
        if autoNav == "settings" { navigation.selection = .settings }
        // ADR-0011: "about" selects the About tab.
        if autoNav == "about" { navigation.selection = .about }
        if autoNav == "groups" { navigation.selection = .groups }
        if autoNav == "kanban" { navigation.open(.kanban) }
        // Test automation specifies a stable fixture identity; it never picks a machine by order.
        if let gateway = environment.gateways.first(where: { $0.id.rawValue == "workstation" }) {
            switch autoNav {
            case "cron": navigation.open(.cron(gateway.id))
            case "skills": navigation.open(.skills(gateway.id))
            case "memory": navigation.open(.memoryGraph(gateway.id))
            case "projects", "workspace": navigation.open(.projects(gateway.id))
            case "bot-detail":
                if let bot = environment.rosterSnapshot?.roster.allBots.first(where: { $0.route.gatewayID == gateway.id && $0.route.profileSlug.rawValue == "default" }) {
                    navigation.open(.botDetail(bot.route))
                }
            default: break
            }
        }
        #endif
    }
}
