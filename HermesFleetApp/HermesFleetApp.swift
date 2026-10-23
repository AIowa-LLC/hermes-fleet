import SwiftUI
import AppIntents
import FleetUI
import FleetCore
import FleetSecurity

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
    // F0: must stay the first stored property so `launch.to-paint` begins
    // before the service graph below is built.
    private let launchSignpost = FleetLaunchSignpostMark()
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

    init() {
        // B3: installed before the first scene so a cold-launch notification
        // tap is delivered. Requests no permission.
        FleetNotificationRouter.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            FleetThemeRoot(controller: themeController) {
                ZStack {
                    FleetTabView(environment: environment, lockController: lockController)
                        .task {
                            // Authenticate before touching the registry,
                            // cache, or roster. Protected content must not
                            // be hydrated while the lock screen is showing.
                            environment.setForegroundRecoveryAllowed(false)
                            await lockController.authenticateIfNeeded()
                            guard !lockController.isLocked, scenePhase == .active else { return }
                            environment.setForegroundRecoveryAllowed(true)
                            await environment.hydrateIfNeeded()
                            await connectScriptedLiveOpsIfNeeded()
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
                FleetMetricKitSubscriber.shared.register() // F0: on-device only
                // B3: local approval notifications observe the inbox from here on.
                await environment.inboxNotifications.start()
                // Notification Review/tap and onOpenURL share one parser
                // (FleetInboxDeepLink) and one focus path (openInbox).
                FleetNotificationRouter.shared.attach(environment.inboxNotifications) { itemID in
                    environment.openInbox(focus: itemID)
                }
            }
            // FOS-3: apply the persisted appearance override app-wide.
            .preferredColorScheme(appearanceController.selection.colorScheme)
            .fleetPrivacyShield(lockController: lockController)
            .onOpenURL { url in
                // `<scheme>://pair#…` (and https `/pair#…`) starts the connect flow; other
                // links on the same scheme (conversations) keep their own handling.
                if environment.pairing.receive(url: url) { return }
                // Phase B: `<scheme>://inbox[?item=<id>]` opens the approvals inbox.
                if let inboxTarget = FleetInboxDeepLink.target(
                    from: url, scheme: FleetAppIdentity.current.conversationURLScheme) {
                    environment.openInbox(focus: inboxTarget.itemID)
                    return
                }
                guard let target = FleetConversationDeepLink.target(from: url) else { return }
                environment.openConversationFromShortcut(
                    route: target.route,
                    sessionID: target.sessionID,
                    canonical: target.canonical)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            lockController.handleScenePhase(phase)
            environment.inboxNotifications.setAppActive(phase == .active)
            #if FLEET_DEV
            watchLink.scenePhaseChanged(phase, environment: environment, lock: lockController)
            #endif
            let canRecover = phase == .active && !lockController.isLocked
            environment.setForegroundRecoveryAllowed(canRecover)
            if phase == .background {
                environment.beginBackgroundSuspension()
            } else if canRecover {
                Task {
                    await environment.resumeAfterForeground()
                    await connectScriptedLiveOpsIfNeeded()
                }
            }
        }
        .onChange(of: lockController.isLocked) { _, isLocked in
            if isLocked {
                environment.setForegroundRecoveryAllowed(false)
                // App Lock gates presentation. It is not a user disconnect
                // and must not clear desired gateway connection intent.
            } else {
                let canRecover = scenePhase == .active
                environment.setForegroundRecoveryAllowed(canRecover)
                // Biometric failure enters passcode fallback. The initial
                // launch task has already returned at that point, so the
                // unlock transition must resume protected hydration.
                if canRecover {
                    Task {
                        await environment.resumeAfterForeground()
                        await connectScriptedLiveOpsIfNeeded()
                    }
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

    private func connectScriptedLiveOpsIfNeeded() async {
        #if DEBUG && targetEnvironment(simulator)
        guard scenePhase == .active, !lockController.isLocked else { return }
        // Preserve the connected-only synthetic fixture whether authentication
        // settles in the initial task or in a later active/unlock transition.
        if ProcessInfo.processInfo.environment["HERMES_FLEET_LIVEOPS_UI_FIXTURE"] == "1" {
            for id in ["workstation", "render-box", "arch"] {
                await environment.connect(to: GatewayID(rawValue: id))
            }
        }
        // The inbox fixture's approval is answerable only while its gateway is
        // connected (Approve is disabled offline). Connect the scripted
        // workstation for the connected fixture; the offline knob skips this.
        if ScriptedInboxFixture.seeded, !ScriptedInboxFixture.offline {
            await environment.connect(to: ScriptedInboxFixture.gatewayID)
        }
        #endif
    }
}
