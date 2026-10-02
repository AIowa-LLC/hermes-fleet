import SwiftUI

/// Opaque branded cover shown while the app is not active (P0.3a).
///
/// The theme background plus the wing identity mark — no roster, conversation,
/// or gateway content. It exists so the iOS app-switcher snapshot never
/// captures protected content.
public struct PrivacyShieldView: View {
    @Environment(\.fleetTheme) private var theme

    public init() {}

    public var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            Image("FleetWingMark", bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hermes Fleet")
        .accessibilityIdentifier("fleet.privacy-shield")
    }
}

#if canImport(UIKit)
import UIKit

/// Scene-level privacy window (P0.3a).
///
/// A SwiftUI overlay inside the root view cannot cover system-presented sheets
/// (the command center, settings sheets, alerts) because those are separate
/// UIKit presentation layers above the hosting view. A dedicated `UIWindow` at
/// a level above everything does, and showing/hiding it is a synchronous UIKit
/// operation performed in the same run-loop turn as the `scenePhase` change —
/// so the cover is in the render tree before the system takes the snapshot.
///
/// The cover appears instantly (a partially faded cover could be snapshotted);
/// it fades out on return unless Reduce Motion is on.
@MainActor
public final class PrivacyShieldWindow {
    private var window: UIWindow?

    public init() {}

    public var isShowing: Bool { window.map { !$0.isHidden } ?? false }

    /// Reconcile the window with the controller's desired visibility.
    public func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

    private func show() {
        guard let scene = Self.activeScene() else { return }
        let window = window ?? UIWindow(windowScene: scene)
        if window.windowScene !== scene { window.windowScene = scene }

        let appearance = FleetAppearanceController.shared.selection
        window.overrideUserInterfaceStyle = switch appearance {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }

        // Rebuilt on every show so the current palette/appearance is used.
        let root = FleetThemeRoot(controller: FleetThemeController.shared) {
            PrivacyShieldView()
        }
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.isUserInteractionEnabled = false
        window.layer.removeAllAnimations()
        window.alpha = 1
        window.isHidden = false
        // Force layout + render now rather than at the next display pass.
        window.layoutIfNeeded()
        self.window = window
    }

    private func hide() {
        guard let window, !window.isHidden else { return }
        if UIAccessibility.isReduceMotionEnabled {
            window.isHidden = true
            window.rootViewController = nil
            return
        }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) {
            window.alpha = 0
        } completion: { finished in
            // A re-show mid-fade resets alpha to 1 and cancels this fade
            // (`finished == false`); only hide when the fade really completed.
            guard finished, window.alpha == 0 else { return }
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}
#endif
