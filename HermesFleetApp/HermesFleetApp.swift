import SwiftUI
import FleetUI

/// Composition root for Hermes Fleet.
///
/// U1: builds the observable `AppEnvironment` runtime (registry + roster +
/// cache + connection lifecycle, all behind FleetCore seams) and injects it
/// into the U1 navigation shell. This is the ONLY place that wires the
/// FleetNetworking concrete services into the app — SwiftUI never imports the
/// transport module (M0 hard guard, enforced by ModuleBoundaryTests).
///
/// H1 (R4): also builds the `AppLockController` (biometric app lock) and
/// forwards `scenePhase` so the lock gates at foreground — before any
/// roster/conversation content renders — with automatic device-passcode
/// fallback. Keychain reads are deliberately NOT wrapped (at-rest protection
/// already comes from `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
@main
struct HermesFleetApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var environment = FleetServiceGraph.makeDefaultEnvironment()
    @State private var lockController = FleetServiceGraph.makeLockController()

    var body: some Scene {
        WindowGroup {
            FleetRootView(environment: environment, lockController: lockController)
                .task {
                    await environment.load()
                    await environment.refreshRoster()
                    await lockController.authenticateIfNeeded()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            lockController.handleScenePhase(phase)
        }
    }
}
