import SwiftUI

/// Settings tab (U3 Gold Fleet, U7 polish) — app settings, hosted as a tab
/// (no longer the H1 sheet from the Gateways toolbar).
///
/// Hosts the existing App Lock toggle (`AppLockController`, default ON,
/// persisted via UserDefaults — the H1 acceptance surface, unchanged). The
/// U7 re-skin applies the Gold Fleet tokens: gold brand header, secondary
/// section headers, magenta control tint. Honest gaps: settings that do not
/// exist yet are not fabricated; more sections land with their features.
public struct FleetSettingsView: View {
    private let controller: AppLockController

    public init(controller: AppLockController) {
        self.controller = controller
    }

    public var body: some View {
        Form {
            // U7: gold brand header (matches the Home dashboard wordmark).
            Section {
                HStack(spacing: FleetTheme.spacingMd) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(FleetTheme.accentGold)
                        .accessibilityHidden(true)
                    Text("Hermes Fleet")
                        .font(FleetTheme.titleFont)
                        .foregroundStyle(FleetTheme.accentGold)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // One combined element: the identifier carries the merged
                // label (icon + wordmark) instead of forwarding to the
                // symbol image (U3 accessibility-identifier lesson).
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("fleet.settings.brand")
            }
            .listRowBackground(Color.clear)

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
                    .foregroundStyle(FleetTheme.textSecondary)
            } footer: {
                Text("Require Face ID (or your device passcode) to unlock "
                     + "Hermes Fleet when the app opens. Stored gateway "
                     + "credentials stay protected by the Keychain.")
                    .foregroundStyle(FleetTheme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(FleetTheme.background.ignoresSafeArea())
        .tint(FleetTheme.accentMagenta)
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
