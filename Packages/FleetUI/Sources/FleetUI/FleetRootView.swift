import SwiftUI
import FleetCore

/// Root navigation shell — the U1 cockpit.
///
/// Hosts a `NavigationStack` over the typed `FleetScreen` destinations:
/// Gateways → Bots → Sessions → Conversation (list-detail push flow per the
/// synthesis UX plan). The concrete `AppEnvironment` is injected by the app
/// target composition root; SwiftUI never imports FleetNetworking (M0 guard).
///
/// M14 theme: the whole stack is tinted Signal Red and rides on the themed
/// background.
public struct FleetRootView: View {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        NavigationStack {
            GatewaysView(environment: environment)
                .navigationDestination(for: FleetScreen.self) { screen in
                    switch screen {
                    case .bots(let gatewayID):
                        BotsView(environment: environment, gatewayID: gatewayID)
                    case .sessions(let route):
                        SessionsView(environment: environment, route: route)
                    case .conversation(let route, let sessionID):
                        ConversationView(route: route, sessionID: sessionID)
                    }
                }
        }
        .tint(FleetTheme.accent)
    }
}
