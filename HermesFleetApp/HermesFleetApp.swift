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
    // FOS-3 (§12): System/Light/Dark appearance preference applied at the
    // app root (nil = System — defer to the device setting).
    @State private var appearanceController = FleetAppearanceController.shared

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
            // FOS-7 (SPEC §14): one fixed Fleet violet interactive tint at
            // app scope — sheets, covers, and the lock overlay inherit it.
            // The retired V7.5 accent pick stays persisted (rollback-safe)
            // but no longer applies.
            .tint(FleetTheme.accent)
            // FOS-3: apply the persisted appearance override app-wide.
            .preferredColorScheme(appearanceController.selection.colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            lockController.handleScenePhase(phase)
        }
    }
}
