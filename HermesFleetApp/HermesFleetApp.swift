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
    // V7.5: the root observes the accent pick so .tint re-renders live when
    // the user changes it in Settings ▸ Appearance (FleetTheme.accent alone
    // is a static seam and would not invalidate the root body).
    @State private var accentController = FleetAccentController.shared

    var body: some Scene {
        WindowGroup {
            // Semantic colors follow system appearance, including the lock gate.
            ZStack {
                FleetTabView(environment: environment, lockController: lockController)
                    .task {
                        await environment.load()
                        await environment.refreshRoster()
                        await lockController.authenticateIfNeeded()
                    }

                // P0-1: continue Tony's artwork past the native LaunchScreen
                // for a guaranteed minimum display window, then cross-fade
                // into the app UI. Skipped under XCUITest unless opted in
                // (see SplashOverlayView.isEnabled).
                if SplashOverlayView.isEnabled {
                    SplashOverlayView()
                }
            }
            // V7 (D5 §2): the ONE app-level accent — reaches sheets, covers
            // and the lock overlay that sit outside FleetTabView's subtree.
            // V7.5: reads the observed controller so a pick re-tints live.
            .tint(accentController.selection.color)
        }
        .onChange(of: scenePhase) { _, phase in
            lockController.handleScenePhase(phase)
        }
    }
}
