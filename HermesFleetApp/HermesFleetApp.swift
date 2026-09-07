import SwiftUI
import FleetUI

/// Composition root for Hermes Fleet.
///
/// Builds the observable `AppEnvironment` runtime and injects it into the
/// navigation shell. This is the only app-level surface that wires concrete
/// networking services into the application; SwiftUI remains behind the
/// FleetCore seams enforced by `ModuleBoundaryTests`.
///
/// The root also owns the biometric app-lock controller and forwards
/// `scenePhase` so protected content is gated when the app returns to the
/// foreground. Keychain reads retain their platform at-rest protection.
@main
struct HermesFleetApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var environment = FleetServiceGraph.makeDefaultEnvironment()
    @State private var lockController = FleetServiceGraph.makeLockController()
    // Observe the accent selection at the root so app-level tint updates live
    // when the user changes it in Settings > Appearance.
    @State private var accentController = FleetAccentController.shared

    var body: some Scene {
        WindowGroup {
            ZStack {
                FleetTabView(environment: environment, lockController: lockController)
                    .task {
                        await environment.load()
                        await environment.refreshRoster()
                        await lockController.authenticateIfNeeded()
                    }

                // Continue the launch artwork past the native LaunchScreen for
                // a guaranteed minimum display window, then cross-fade into
                // the app UI. UI tests can skip or explicitly opt into it.
                if SplashOverlayView.isEnabled {
                    SplashOverlayView()
                }
            }
            // Apply the selected accent at app scope so sheets, covers, and
            // the lock overlay inherit the same tint.
            .tint(accentController.selection.color)
        }
        .onChange(of: scenePhase) { _, phase in
            lockController.handleScenePhase(phase)
        }
    }
}
