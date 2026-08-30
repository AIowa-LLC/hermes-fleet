import SwiftUI
import FleetCore

/// Root navigation shell — the U2 fleet cockpit.
///
/// Hosts a `NavigationStack` over the typed `FleetScreen` destinations:
/// Gateways → Bots (roster) → Bot detail → Conversation (list-detail push
/// flow per the synthesis UX plan). The concrete `AppEnvironment` is injected
/// by the app target composition root; SwiftUI never imports FleetNetworking
/// (M0 guard).
///
/// DEBUG auto-navigation hook (launch environment, evidence capture only):
/// `HERMES_FLEET_AUTO_NAV=roster` opens the union Bots roster on launch;
/// `HERMES_FLEET_AUTO_NAV=bot-detail` opens the first seeded bot's detail.
/// Compiled out of Release. Never a product feature.
///
/// M14 theme: the whole stack is tinted Signal Red and rides on the themed
/// background.
public struct FleetRootView: View {
    private let environment: AppEnvironment
    private let autoNav: String?
    @State private var path: [FleetScreen] = []
    @State private var autoNavHandled = false

    public init(environment: AppEnvironment) {
        self.environment = environment
        #if DEBUG
        self.autoNav = ProcessInfo.processInfo.environment["HERMES_FLEET_AUTO_NAV"]
        #else
        self.autoNav = nil
        #endif
    }

    public var body: some View {
        NavigationStack(path: $path) {
            GatewaysView(environment: environment)
                .navigationDestination(for: FleetScreen.self) { screen in
                    switch screen {
                    case .bots(let gatewayID):
                        BotsView(environment: environment, gatewayID: gatewayID)
                    case .roster:
                        FleetRosterView(environment: environment)
                    case .botDetail(let route):
                        BotDetailView(environment: environment, route: route)
                    case .conversation(let route, let sessionID):
                        ConversationView(environment: environment, route: route, sessionID: sessionID)
                    }
                }
        }
        .task {
            await performAutoNavIfNeeded()
        }
        .tint(FleetTheme.accent)
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
            path = [.roster]
        case "bot-detail":
            if let first = environment.rosterSnapshot?.roster.allBots.first {
                path = [.botDetail(first.route)]
            }
        default:
            break
        }
        #endif
    }
}
