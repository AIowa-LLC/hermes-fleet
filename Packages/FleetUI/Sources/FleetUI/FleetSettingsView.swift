import SwiftUI

/// FOS-3 (SPEC §12) — Settings is an app-level SHEET reached from the Fleet
/// root's leading gearshape and Command Center. First item is useful
/// configuration, not a brand block. No invented preferences: Security
/// (App Lock), Appearance (System/Light/Dark — FOS-3), and the always-
/// reachable Agent Setup Prompt (C2) plus app version. FOS-7 (SPEC §14):
/// the accent picker is retired — Fleet uses one consistent interface
/// accent (fixed Fleet violet); the stored pick is preserved for rollback.
public struct FleetSettingsView: View {
    private let controller: AppLockController
    private let appearanceController: FleetAppearanceController

    /// C2: presents the always-reachable agent setup prompt sheet.
    @State private var showingSetupPrompt = false

    public init(controller: AppLockController,
                appearanceController: FleetAppearanceController = FleetAppearanceController.shared) {
        self.controller = controller
        self.appearanceController = appearanceController
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
                    .foregroundStyle(FleetTheme.textSecondary)
            } footer: {
                Text("Require Face ID (or your device passcode) to unlock "
                     + "Hermes Fleet when the app opens. Stored gateway "
                     + "credentials stay protected by the Keychain.")
                    .foregroundStyle(FleetTheme.textSecondary)
            }

            // FOS-3 (§12 Appearance): System / Light / Dark, default System.
            // FOS-7 (SPEC §14): the accent picker is RETIRED — the section is
            // the appearance preference plus a short note that Fleet uses one
            // consistent interface accent. The stored pick is preserved
            // untouched (rollback-safe; do not delete migration-unsafe state).
            Section {
                Picker("Appearance", selection: Binding(
                    get: { appearanceController.selection },
                    set: { appearanceController.selection = $0 }
                )) {
                    ForEach(FleetAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("fleet.settings.appearance")
            } header: {
                Text("Appearance")
                    .foregroundStyle(FleetTheme.textSecondary)
            } footer: {
                Text("Choose Light or Dark, or follow your device's system setting. Fleet uses one consistent interface accent, so buttons and links share the same color everywhere.")
                    .foregroundStyle(FleetTheme.textSecondary)
            }

            // C2: the ALWAYS-REACHABLE door to the agent setup prompt. The
            // old onboarding entry only existed in the empty-gateways state,
            // so it silently vanished for anyone with a configured gateway.
            Section {
                Button {
                    showingSetupPrompt = true
                } label: {
                    Label("Agent Setup Prompt", systemImage: "text.badge.star")
                        .foregroundStyle(FleetTheme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fleet.settings.setup-prompt")
            } header: {
                Text("Agent")
                    .foregroundStyle(FleetTheme.textSecondary)
            } footer: {
                Text("Copy or share the versioned setup prompt for your Hermes agent.")
                    .foregroundStyle(FleetTheme.textSecondary)
            }

            Section {
                LabeledContent("Version", value: Self.appVersion)
                    .accessibilityIdentifier("fleet.settings.version")
            } footer: {
                Text("Hermes Fleet — a pocket operations console for your agents.")
                    .foregroundStyle(FleetTheme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(FleetTheme.background.ignoresSafeArea())
        .tint(FleetTheme.accent)
        // C2: the setup-prompt door — standard sheet presentation.
        .sheet(isPresented: $showingSetupPrompt) {
            SetupPromptSheet()
        }
        .navigationTitle("Settings")
        .accessibilityIdentifier("fleet.settings")
    }

    /// Marketing/build version from the main bundle (no invented values).
    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let short, let build { return "\(short) (\(build))" }
        if let short { return short }
        return "Unknown"
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
