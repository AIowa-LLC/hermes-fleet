import SwiftUI

/// Settings tab (U3 Gold Fleet) — app settings, hosted as a tab (no longer
/// the H1 sheet from the Gateways toolbar).
///
/// Hosts the existing App Lock toggle (`AppLockController`, default ON,
/// persisted via UserDefaults — the H1 acceptance surface, unchanged). Honest
/// gaps: settings that do not exist yet are not fabricated; more sections
/// land with their features.
public struct FleetSettingsView: View {
    private let controller: AppLockController

    public init(controller: AppLockController) {
        self.controller = controller
    }

    public var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { controller.isEnabled },
                    set: { controller.setEnabled($0) }
                )) {
                    Label("App Lock", systemImage: "faceid")
                        .foregroundStyle(FleetTheme.textPrimary)
                }
                .accessibilityIdentifier("fleet.settings.app-lock.toggle")
            } header: {
                Text("Security")
            } footer: {
                Text("Require Face ID (or your device passcode) to unlock "
                     + "Hermes Fleet when the app opens. Stored gateway "
                     + "credentials stay protected by the Keychain.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(FleetTheme.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .accessibilityIdentifier("fleet.settings")
    }
}

#if DEBUG
#Preview("Settings") {
    NavigationStack {
        FleetSettingsView(controller: .init(auth: AlwaysSuccessSettingsAuth()))
    }
    .preferredColorScheme(.dark)
}

private struct AlwaysSuccessSettingsAuth: AppLockBiometricAuth {
    func canEvaluateBiometrics() -> Bool { true }
    func evaluateBiometrics(reason: String) async -> AppLockAuthResult { .success }
    func evaluateDevicePasscode(reason: String) async -> Bool { true }
}
#endif
