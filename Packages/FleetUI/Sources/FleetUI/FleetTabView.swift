import SwiftUI
import FleetCore

/// U3 (Gold Fleet) — a root navigation tab.
///
/// Presentation-layer model only: SF Symbol icon + title per the plan-of-record
/// tab bar (Home / Bots / Gateways / Activity / Settings). Case order IS tab
/// order; `FleetTabTests` pins both the count and the order so accidental tab
/// reordering fails a test instead of shipping.
public enum FleetTab: String, Hashable, Sendable, CaseIterable, Identifiable {
    case home
    case bots
    case gateways
    case activity
    case settings

    public var id: String { rawValue }

    /// Tab-bar title.
    public var label: String {
        switch self {
        case .home: return "Home"
        case .bots: return "Bots"
        case .gateways: return "Gateways"
        case .activity: return "Activity"
        case .settings: return "Settings"
        }
    }

    /// SF Symbol for the tab item.
    public var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .bots: return "cpu"
        case .gateways: return "server.rack"
        case .activity: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// U3 (Gold Fleet) root navigation shell — the five-tab `TabView`.
///
/// Tabs: Home (dashboard) / Bots (fleet roster) / Gateways (registry) /
/// Activity (connection event feed) / Settings (App Lock), SF Symbols, active
/// tab tinted the pale-cyan accent (`.tint(FleetTheme.accent)` on the
/// TabView; the lock gate keeps the app-wide tint). Each tab hosts its OWN `NavigationStack`
/// with the typed `FleetScreen` destinations registered, so per-tab push
/// navigation (bots → detail → conversation) works from every tab root and
/// switching tabs preserves each stack.
///
/// Screen mapping (existing surfaces, no logic changes):
/// - Home: `FleetDashboardView` over the live `AppEnvironment` — stat row
///   (real counts only) + gateways summary + active-bots summary.
/// - Bots: the union roster (`FleetRosterView`), previously the toolbar link.
/// - Gateways: the registry cockpit (`GatewaysView`) — unchanged surface,
///   now with the Roster/Health/Settings entries removed from its toolbar
///   (they are tabs now).
/// - Activity: `FleetActivityView` — REAL accumulated connection events from
///   the H2 health stats (uptime / reconnects / last-disconnect per gateway).
///   Honest gaps: no persistent event log exists yet; the empty state says so
///   (no fabricated timeline entries).
/// - Settings: `FleetSettingsView` hosting the existing App Lock toggle
///   (previously the H1 sheet; same controller, same persisted key).
///
/// H1 (R4): when the app-lock controller is not unlocked, ONLY the minimal
/// lock screen renders — no fleet content exists behind it (unchanged gate).
///
/// DEBUG auto-navigation hook (launch environment, evidence capture only):
/// `HERMES_FLEET_AUTO_NAV=roster|bot-detail` now selects the Bots tab (and
/// pushes bot detail on that tab's stack). Compiled out of Release. Never a
/// product feature.
public struct FleetTabView: View {
    private let environment: AppEnvironment
    private let lockController: AppLockController
    private let autoNav: String?
    @State private var selection: FleetTab = .home
    @State private var botsPath: [FleetScreen] = []
    @State private var autoNavHandled = false

    public init(environment: AppEnvironment, lockController: AppLockController) {
        self.environment = environment
        self.lockController = lockController
        #if DEBUG
        self.autoNav = ProcessInfo.processInfo.environment["HERMES_FLEET_AUTO_NAV"]
        #else
        self.autoNav = nil
        #endif
    }

    public var body: some View {
        Group {
            if lockController.isLocked {
                AppLockView(controller: lockController)
            } else {
                TabView(selection: $selection) {
                    NavigationStack(path: $botsPath) {
                        FleetDashboardView(environment: environment)
                            .navigationDestination(for: FleetScreen.self) { screen in
                                destination(screen)
                            }
                    }
                    .tabItem { Label(FleetTab.home.label, systemImage: FleetTab.home.systemImage) }
                    .tag(FleetTab.home)
                    .accessibilityIdentifier("fleet.tab.home")

                    NavigationStack {
                        FleetRosterView(environment: environment)
                            .navigationDestination(for: FleetScreen.self) { screen in
                                destination(screen)
                            }
                    }
                    .tabItem { Label(FleetTab.bots.label, systemImage: FleetTab.bots.systemImage) }
                    .tag(FleetTab.bots)
                    .accessibilityIdentifier("fleet.tab.bots")

                    NavigationStack {
                        GatewaysView(environment: environment)
                            .navigationDestination(for: FleetScreen.self) { screen in
                                destination(screen)
                            }
                    }
                    .tabItem { Label(FleetTab.gateways.label, systemImage: FleetTab.gateways.systemImage) }
                    .tag(FleetTab.gateways)
                    .accessibilityIdentifier("fleet.tab.gateways")

                    NavigationStack {
                        FleetActivityView(environment: environment)
                            .navigationDestination(for: FleetScreen.self) { screen in
                                destination(screen)
                            }
                    }
                    .tabItem { Label(FleetTab.activity.label, systemImage: FleetTab.activity.systemImage) }
                    .tag(FleetTab.activity)
                    .accessibilityIdentifier("fleet.tab.activity")

                    NavigationStack {
                        FleetSettingsView(controller: lockController)
                    }
                    .tabItem { Label(FleetTab.settings.label, systemImage: FleetTab.settings.systemImage) }
                    .tag(FleetTab.settings)
                    .accessibilityIdentifier("fleet.tab.settings")
                }
            }
        }
        .task {
            await performAutoNavIfNeeded()
        }
        .tint(FleetTheme.accent)
    }

    /// Shared typed-destination renderer (every tab stack registers the same
    /// `FleetScreen` destinations; only roster pushes actually originate
    /// outside the roster today).
    @ViewBuilder
    private func destination(_ screen: FleetScreen) -> some View {
        switch screen {
        case .bots(let gatewayID):
            BotsView(environment: environment, gatewayID: gatewayID)
        case .roster:
            FleetRosterView(environment: environment)
        case .botDetail(let route):
            BotDetailView(environment: environment, route: route)
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
        }
    }

    /// DEBUG-only: drive the shell to the requested screen after the runtime
    /// has loaded its registry + roster (so the destination has data).
    @MainActor
    private func performAutoNavIfNeeded() async {
        #if DEBUG
        guard !autoNavHandled, let autoNav else { return }
        autoNavHandled = true
        await environment.load()
        await environment.refreshRoster()
        switch autoNav {
        case "roster":
            selection = .bots
        case "bot-detail":
            if let first = environment.rosterSnapshot?.roster.allBots.first {
                selection = .bots
                botsPath = [.botDetail(first.route)]
            }
        default:
            break
        }
        #endif
    }
}
