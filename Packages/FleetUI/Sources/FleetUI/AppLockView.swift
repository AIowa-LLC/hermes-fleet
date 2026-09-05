import SwiftUI

/// App-lock overlay (H1 / R4; D-1 V7 lock spec, t_9ce36690).
///
/// Rendered at the root BEFORE any roster/conversation content when the
/// `AppLockController` is not `.unlocked`. HIG-native lock screen: system
/// background, the white-wing identity mark in the upper third, the app name
/// directly under it in system type (.title2 semibold, .label) — NOT gold,
/// NOT custom font — and the existing unlock control in system styling.
/// When biometrics fail or are unavailable the controller transitions to
/// `.passcodeFallback` and this view shows the passcode prompt.
///
/// The overlay is deliberately minimal: it gates access, it does not host
/// fleet UI. All elements carry accessibility identifiers for the H1 UI test.
public struct AppLockView: View {
    let controller: AppLockController

    public init(controller: AppLockController) {
        self.controller = controller
    }

    public var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: FleetTheme.spacingXl) {
                // D-1 fix per D5 §3: the white-wing identity mark replaces
                // the absent gold wordmark — system bg + white-wing mark +
                // app name in system type (agreed in-room; NO gold restore).
                // Bundle.module: the mark ships in FleetUI's package
                // resources (AppLockView lives in FleetUI, not the app).
                Image("FleetWingMark", bundle: .module)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
                    // Exposed (NOT accessibilityHidden): the D5 spec requires
                    // the mark queryable as "lock-identity-mark".
                    .accessibilityLabel("Hermes Fleet")
                    .accessibilityIdentifier("lock-identity-mark")

                Text("Hermes Fleet")
                    .font(.system(.title2, design: .default, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .label))
                    .accessibilityIdentifier("lock-app-name")

                Spacer(minLength: 0)

                if controller.state == .passcodeFallback {
                    passcodePrompt
                } else {
                    biometricPrompt
                }
            }
            .padding(FleetTheme.spacingXl)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.app-lock.screen")
    }

    /// Biometrics ready: a single unlock action (Face ID / Touch ID).
    private var biometricPrompt: some View {
        VStack(spacing: FleetTheme.spacingMd) {
            Text(controller.state == .authenticating
                 ? "Checking…"
                 : "Unlock to access your fleet")
                .font(.subheadline)
                .foregroundStyle(FleetTheme.textSecondary)

            Button {
                Task { await controller.authenticate() }
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(controller.state == .authenticating)
            .accessibilityIdentifier("fleet.app-lock.unlock")
        }
    }

    /// Passcode fallback: biometrics failed or are unavailable — show the
    /// passcode path (system device-passcode via LocalAuthentication).
    private var passcodePrompt: some View {
        VStack(spacing: FleetTheme.spacingMd) {
            Label("Authentication unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(FleetTheme.statusDegraded)
                .accessibilityIdentifier("fleet.app-lock.passcode.banner")

            Text("Use your device passcode to continue.")
                .font(.subheadline)
                .foregroundStyle(FleetTheme.textSecondary)

            Button {
                Task { await controller.unlockWithPasscode() }
            } label: {
                Label("Use Passcode", systemImage: "key.horizontal")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(controller.state == .authenticating)
            .accessibilityIdentifier("fleet.app-lock.passcode.unlock")
        }
    }
}

#if DEBUG
#Preview("Locked") {
    AppLockView(controller: .init(auth: AlwaysSucceedAuth()))
}

#Preview("Locked — passcode fallback") {
    AppLockView(controller: .init(
        auth: AlwaysFailAuth(),
        mode: .followSetting
    ))
}

private struct AlwaysSucceedAuth: AppLockBiometricAuth {
    func canEvaluateBiometrics() -> Bool { true }
    func evaluateBiometrics(reason: String) async -> AppLockAuthResult { .success }
    func evaluateDevicePasscode(reason: String) async -> Bool { true }
}

private struct AlwaysFailAuth: AppLockBiometricAuth {
    func canEvaluateBiometrics() -> Bool { true }
    func evaluateBiometrics(reason: String) async -> AppLockAuthResult { .failure }
    func evaluateDevicePasscode(reason: String) async -> Bool { false }
}
#endif
