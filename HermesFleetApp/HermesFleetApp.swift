import SwiftUI
import FleetUI

/// Composition root for Hermes Fleet.
///
/// U1: builds the observable `AppEnvironment` runtime (registry + roster +
/// cache + connection lifecycle, all behind FleetCore seams) and injects it
/// into the U1 navigation shell. This is the ONLY place that wires the
/// FleetNetworking concrete services into the app — SwiftUI never imports the
/// transport module (M0 hard guard, enforced by ModuleBoundaryTests).
@main
struct HermesFleetApp: App {
    @State private var environment = FleetServiceGraph.makeDefaultEnvironment()

    var body: some Scene {
        WindowGroup {
            FleetRootView(environment: environment)
                .task {
                    await environment.load()
                    await environment.refreshRoster()
                }
        }
    }
}
