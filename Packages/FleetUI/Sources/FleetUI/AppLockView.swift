import SwiftUI

/// Minimal app-lock overlay (H1 / R4).
///
/// Rendered at the root BEFORE any roster/conversation content when the
/// `AppLockController` is not `.unlocked`. Token background with the Gold
/// Fleet brand accent (U7 re-skin) — a gold lock glyph + wordmark + a single
/// magenta unlock action. When biometrics fail or are unavailable the
/// controller transitions to `.passcodeFallback` and this view automatically
/// shows the passcode prompt (failed-biometric acceptance path).
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
            FleetTheme.background.ignoresSafeArea()

            VStack(spacing: FleetTheme.spacingXl) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(FleetTheme.accentGold)
                    .accessibilityHidden(true)

                Text("Hermes Fleet")
                    .font(FleetTheme.titleFont)
                    .foregroundStyle(FleetTheme.accentGold)

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
            .tint(FleetTheme.accent)
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
            .tint(FleetTheme.accent)
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
