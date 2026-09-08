import SwiftUI

/// FOS-3 (SPEC §12) — Settings is an app-level SHEET reached from the Fleet
/// root's leading gearshape and Command Center. First item is useful
/// configuration, not a brand block (the U7 gold banner is retired with this
/// card). No invented preferences: Security (App Lock), Appearance
/// (System/Light/Dark — new; the accent picker retires in FOS-7), and the
/// always-reachable Agent Setup Prompt (C2) plus app version.
public struct FleetSettingsView: View {
    private let controller: AppLockController
    private let accentController: FleetAccentController
    private let appearanceController: FleetAppearanceController

    /// C2: presents the always-reachable agent setup prompt sheet.
    @State private var showingSetupPrompt = false

    public init(controller: AppLockController,
                accentController: FleetAccentController = FleetAccentController.shared,
                appearanceController: FleetAppearanceController = FleetAppearanceController.shared) {
        self.controller = controller
        self.accentController = accentController
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
            // The accent picker RETIRES in FOS-7; until then the V7.5 picker
            // keeps applying unchanged (its tests migrate with FOS-7).
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
                ForEach(FleetAccent.allCases) { accent in
                    Button {
                        accentController.selection = accent
                    } label: {
                        HStack(spacing: FleetTheme.spacingMd) {
                            Circle()
                                .fill(accent.color)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(FleetTheme.border, lineWidth: 1))
                            Text(accent.label)
                                .foregroundStyle(FleetTheme.textPrimary)
                            Spacer()
                            if accentController.selection == accent {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(FleetTheme.accent)
                                    .accessibilityIdentifier("fleet.settings.accent.selected.\(accent.rawValue)")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("fleet.settings.accent.\(accent.rawValue)")
                }
            } header: {
                Text("Appearance")
                    .foregroundStyle(FleetTheme.textSecondary)
            } footer: {
                Text("Choose Light or Dark, or follow your device's system setting. The accent picker retires in a coming update in favor of one consistent Fleet interface accent.")
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
