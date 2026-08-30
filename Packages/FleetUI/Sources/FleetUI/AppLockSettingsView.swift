import SwiftUI

/// In-app Settings sheet for the H1 app lock.
///
/// Holds the single App Lock toggle (default ON, persisted via the
/// controller's UserDefaults key). The setting is a non-secret UI preference
/// — deliberately NOT a Keychain value; the lock gates the UI only, never
/// Keychain reads.
public struct AppLockSettingsView: View {
    let controller: AppLockController
    @Environment(\.dismiss) private var dismiss

    public init(controller: AppLockController) {
        self.controller = controller
    }

    public var body: some View {
        NavigationStack {
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
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("fleet.settings.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#if DEBUG
#Preview("Settings") {
    AppLockSettingsView(controller: .init(auth: AlwaysSuccessSettingsAuth()))
}

private struct AlwaysSuccessSettingsAuth: AppLockBiometricAuth {
    func canEvaluateBiometrics() -> Bool { true }
    func evaluateBiometrics(reason: String) async -> AppLockAuthResult { .success }
    func evaluateDevicePasscode(reason: String) async -> Bool { true }
}
#endif
