import SwiftUI
import AppIntents
import FleetUI
import FleetCore

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
    @State private var themeController = FleetThemeController.shared
    #if FLEET_DEV
    // Fleet Dev only: phone side of the Apple Watch companion link.
    @State private var watchLink = FleetWatchLink()
    #endif

    var body: some Scene {
        WindowGroup {
            FleetThemeRoot(controller: themeController) {
                ZStack {
                    FleetTabView(environment: environment, lockController: lockController)
                        .task {
                            // Authenticate before touching the registry,
                            // cache, or roster. Protected content must not
                            // be hydrated while the lock screen is showing.
                            #if DEBUG && targetEnvironment(simulator)
                            // Cold-launch pairing-link delivery for UI tests.
                            if let link = PairingTestInjection.launchLink {
                                environment.pairing.receive(text: link, entry: .link)
                            }
                            #endif
                            await lockController.authenticateIfNeeded()
                            guard !lockController.isLocked else { return }
                            await environment.hydrateIfNeeded()
                            #if DEBUG && targetEnvironment(simulator)
                            if ProcessInfo.processInfo.environment["HERMES_FLEET_LIVEOPS_UI_FIXTURE"] == "1" {
                                // This UI fixture exercises the monitor's
                                // connected-only polling contract without
                                // relying on connection intent persisted by
                                // another simulator test.
                                await environment.connect(to: GatewayID(rawValue: "workstation"))
                                await environment.connect(to: GatewayID(rawValue: "render-box"))
                                await environment.connect(to: GatewayID(rawValue: "arch"))
                            }
                            #endif
                        }

                    // Continue the launch artwork past the native LaunchScreen
                    // for a guaranteed minimum display window, then cross-fade
                    // into the app UI. UI tests can skip or explicitly opt in.
                    if SplashOverlayView.isEnabled {
                        SplashOverlayView()
                    }

                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-issue6-theme-proof") {
                        FleetThemeProofView()
                            .allowsHitTesting(false)
                    }
                    #endif
                }
            }
            .task {
                HermesFleetShortcuts.updateAppShortcutParameters()
            }
            // FOS-3: apply the persisted appearance override app-wide.
            .preferredColorScheme(appearanceController.selection.colorScheme)
            .fleetPrivacyShield(lockController: lockController)
            .onOpenURL { url in
                // Add to Fleet pairing links first (Universal Links arrive here too). Receiving a
                // link only queues the confirmation screen; nothing is consumed or approved.
                if environment.pairing.receive(url: url) { return }
                #if DEBUG && targetEnvironment(simulator)
                // Simulator-only test injection (compiled out of device builds):
                //   <scheme>://pairing-test?link=<percent-encoded https link>
                if let injected = PairingTestInjection.link(from: url) {
                    environment.pairing.receive(text: injected, entry: .link)
                    return
                }
                #endif
                guard let target = FleetConversationDeepLink.target(from: url) else { return }
                environment.openConversationFromShortcut(
                    route: target.route,
                    sessionID: target.sessionID,
                    canonical: target.canonical)
            }
            // Universal Links delivered as a web-browsing user activity.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { environment.pairing.receive(url: url) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            lockController.handleScenePhase(phase)
            #if FLEET_DEV
            watchLink.scenePhaseChanged(phase, environment: environment, lock: lockController)
            #endif
            if phase == .active && !lockController.isLocked {
                Task {
                    await environment.restoreIntendedConnections()
                    await environment.restoreConversationSessions()
                }
            }
        }
        .onChange(of: lockController.isLocked) { _, isLocked in
            if isLocked {
                // App Lock gates presentation. It is not a user disconnect
                // and must not clear desired gateway connection intent.
            } else {
                // Biometric failure enters passcode fallback. The initial
                // launch task has already returned at that point, so the
                // unlock transition must resume protected hydration.
                Task {
                    await environment.hydrateIfNeeded()
                    await environment.restoreIntendedConnections()
                    await environment.restoreConversationSessions()
                }
            }
        }
        .onChange(of: lockController.isEnabled) { _, _ in
            // App Intents caches entity display representations for system
            // surfaces. Refresh those labels whenever the privacy setting
            // changes so a previously unlocked name is not left cached.
            HermesFleetShortcuts.updateAppShortcutParameters()
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Simulator-only seam so UI tests can deliver a pairing link to a running or cold-launching
/// app without a verified domain: `<scheme>://pairing-test?link=<percent-encoded link>`.
/// Not compiled into device builds, so the shipped app has no custom-scheme pairing path.
enum PairingTestInjection {
    static func link(from url: URL) -> String? {
        guard url.host == "pairing-test",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name == "link" })?.value else { return nil }
        return value
    }

    /// Cold-launch delivery: `HERMES_FLEET_PAIRING_TEST_LINK` in the launch environment.
    static var launchLink: String? {
        ProcessInfo.processInfo.environment["HERMES_FLEET_PAIRING_TEST_LINK"]
    }
}
#endif
