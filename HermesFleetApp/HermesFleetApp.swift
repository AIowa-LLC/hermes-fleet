import SwiftUI
import FleetUI

/// Composition root for Hermes Fleet.
///
/// M0: assembles the fleet dashboard model and injects it into the UI shell.
/// Later milestones wire the real service graph (transport, security,
/// persistence) here — all behind the FleetCore seams, never inside SwiftUI.
@main
struct HermesFleetApp: App {
    @State private var model = FleetDashboardModel()

    var body: some Scene {
        WindowGroup {
            FleetRootView(model: model)
        }
    }
}
