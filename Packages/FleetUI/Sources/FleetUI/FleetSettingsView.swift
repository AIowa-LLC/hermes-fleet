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
    private let accentController: FleetAccentController

    /// C2: presents the always-reachable agent setup prompt sheet.
    @State private var showingSetupPrompt = false

    public init(controller: AppLockController,
                accentController: FleetAccentController = FleetAccentController.shared) {
        self.controller = controller
        self.accentController = accentController
    }

    public var body: some View {
        Form {
            // U7: gold brand header (matches the Home dashboard wordmark).
            Section {
                HStack(spacing: FleetTheme.spacingMd) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(FleetTheme.accent)
                        .accessibilityHidden(true)
                    Text("Hermes Fleet")
                        .font(FleetTheme.titleFont)
                        .foregroundStyle(FleetTheme.accent)
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

            // V7.5: the ONE accent is user-choosable — vetted catalog only
            // (no free-text hex; teal permanently banned, brand rule).
            Section {
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
                Text("Sets the app's single accent color. Warm Gold is the strongest contrast pairing with the white-wing mark; Hermes Blue is the Apple standard look.")
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
