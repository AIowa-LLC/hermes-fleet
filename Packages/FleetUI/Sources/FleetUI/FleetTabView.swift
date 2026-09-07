import SwiftUI
import FleetCore

public enum FleetTab: String, Hashable, Sendable, CaseIterable, Identifiable {
    case home, chats, bots, workspace, control
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .home: "Command"
        case .chats: "Chats"
        case .bots: "Bots"
        case .workspace: "Workspace"
        case .control: "Control"
        }
    }
    public var systemImage: String {
        switch self {
        case .home: "sparkle"
        case .chats: "bubble.left.and.bubble.right"
        case .bots: "cpu"
        case .workspace: "folder"
        case .control: "slider.horizontal.3"
        }
    }
}

/// Adaptive system navigation; every tab owns its stack and the lock gate owns all content.
public struct FleetTabView: View {
    private let environment: AppEnvironment
    private let lockController: AppLockController
    @State private var selection: FleetTab = .home
    @State private var paths: [FleetTab: [FleetScreen]] = [:]
    @State private var showingCommandCenter = false
    @State private var autoNavHandled = false

    public init(environment: AppEnvironment, lockController: AppLockController) {
        self.environment = environment
        self.lockController = lockController
    }

    public var body: some View {
        Group {
            if lockController.isLocked {
                AppLockView(controller: lockController)
            } else {
                TabView(selection: $selection) {
                    ForEach(FleetTab.allCases) { tab in
                        Tab(tab.label, systemImage: tab.systemImage, value: tab) {
                            NavigationStack(path: Binding(get: { paths[tab] ?? [] }, set: { paths[tab] = $0 })) {
                                root(tab)
                                    .navigationDestination(for: FleetScreen.self) { destination($0) }
                                    .toolbar {
                                        ToolbarItem(placement: .topBarTrailing) {
                                            Button("Command Center", systemImage: "magnifyingglass") { showingCommandCenter = true }
                                                .accessibilityIdentifier("fleet.command-center.open")
                                                .keyboardShortcut("k", modifiers: .command)
                                        }
                                    }
                            }
                            .accessibilityIdentifier("fleet.tab.\(tab.rawValue)")
                        }
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
                .sheet(isPresented: $showingCommandCenter) {
                    FleetCommandCenter(environment: environment, navigate: { screen in
                        paths[selection, default: []].append(screen)
                    }, selectTab: { selection = $0 })
                }
            }
        }
        .tint(FleetTheme.accent)
        .onChange(of: lockController.isLocked) { if lockController.isLocked { showingCommandCenter = false } }
        .onChange(of: environment.pendingBotChatNavigation) { target in
            guard let target else { return }
            // Route Bot Chat opens to the Chats tab where conversations live.
            if selection != .chats { selection = .chats }
            paths[.chats, default: []].append(target)
            environment.pendingBotChatNavigation = nil
        }
        .task { await performAutoNavIfNeeded() }
    }

    @ViewBuilder private func root(_ tab: FleetTab) -> some View {
        switch tab {
        case .home: FleetDashboardView(environment: environment)
        case .chats: FleetChatsView(environment: environment)
        case .bots: FleetRosterView(environment: environment)
        case .workspace: FleetWorkspaceView(environment: environment)
        case .control: FleetControlView(environment: environment, lockController: lockController)
        }
    }

    @ViewBuilder
    private func destination(_ screen: FleetScreen) -> some View {
        switch screen {
        case .bots(let gatewayID):
            BotsView(environment: environment, gatewayID: gatewayID)
        case .roster:
            FleetRosterView(environment: environment)
        case .botDetail(let route):
            BotDetailView(environment: environment, route: route)
        case .botRoutines(let route):
            BotRoutinesView(environment: environment, route: route)
        case .room(let room):
            RoomChatView(room: room, environment: environment)
        case .conversation(let route, let sessionID):
            ConversationView(environment: environment, route: route, sessionID: sessionID)
        case .health:
            HealthDashboardView(environment: environment)
        case .gateways:
            GatewaysView(environment: environment)
        case .activity:
            FleetActivityView(environment: environment)
        case .kanban:
            KanbanBoardView(environment: environment)
        case .cron(let gatewayID):
            CronView(environment: environment, gatewayID: gatewayID)
        case .skills(let gatewayID):
            SkillsView(environment: environment, gatewayID: gatewayID)
        case .memoryGraph(let gatewayID):
            MemoryGraphView(environment: environment, gatewayID: gatewayID)
        case .projects(let gatewayID, let focusPath):
            ProjectsView(environment: environment, gatewayID: gatewayID, focusPath: focusPath)
        }
    }


    @MainActor private func performAutoNavIfNeeded() async {
        #if DEBUG
        guard !autoNavHandled, let autoNav = ProcessInfo.processInfo.environment["HERMES_FLEET_AUTO_NAV"] else { return }
        autoNavHandled = true
        await environment.load()
        await environment.refreshRoster()
        if autoNav == "roster" { selection = .bots }
        if autoNav == "chats" { selection = .chats }
        if autoNav == "workspace" { selection = .workspace }
        if autoNav == "control" { selection = .control }
        if autoNav == "command-center" { showingCommandCenter = true }
        let gateway = environment.gateways.first { $0.id.rawValue == "workstation" } ?? environment.gateways.first
        if let gateway {
            switch autoNav {
            case "cron": paths[.home] = [.cron(gateway.id)]
            case "skills": paths[.home] = [.skills(gateway.id)]
            case "memory": paths[.home] = [.memoryGraph(gateway.id)]
            case "projects": paths[.home] = [.projects(gateway.id)]
            case "gateways": paths[.home] = [.gateways]
            default: break
            }
        }
        if autoNav == "bot-detail", let first = environment.rosterSnapshot?.roster.allBots.first {
            selection = .bots
            paths[.bots] = [.botDetail(first.route)]
        }
        #endif
    }
}
