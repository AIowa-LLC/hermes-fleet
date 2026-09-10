import Foundation
import SwiftUI

/// FOS-3 (SPEC §12) — Settings is an app-level SHEET reached from the Fleet
/// root's leading gearshape and Command Center. First item is useful
/// configuration, not a brand block. No invented preferences: Security
/// (App Lock), Appearance (System/Light/Dark — FOS-3), and the always-
/// reachable Agent Setup Prompt (C2) plus app version. Appearance owns both
/// the System/Light/Dark choice and the V1 environment-backed theme editor.
public struct FleetSettingsView: View {
    private let controller: AppLockController
    private let appearanceController: FleetAppearanceController
    private let themeController: FleetThemeController

    /// C2: presents the always-reachable agent setup prompt sheet.
    @State private var showingSetupPrompt = false
    @State private var showingThemeEditor = false
    @Environment(\.fleetTheme) private var theme

    public init(controller: AppLockController,
                appearanceController: FleetAppearanceController = FleetAppearanceController.shared,
                themeController: FleetThemeController = FleetThemeController.shared) {
        self.controller = controller
        self.appearanceController = appearanceController
        self.themeController = themeController
    }

    public var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { controller.isEnabled },
                    set: { controller.setEnabled($0) }
                )) {
                    Label("App Lock", systemImage: "faceid")
                        .foregroundStyle(theme.textPrimary)
                }
                .accessibilityIdentifier("fleet.settings.app-lock.toggle")
            } header: {
                Text("Security")
                    .foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Require Face ID (or your device passcode) to unlock "
                     + "Hermes Fleet when the app opens. Stored gateway "
                     + "credentials stay protected by the Keychain.")
                    .foregroundStyle(theme.textSecondary)
            }

            // FOS-3 (§12 Appearance): System / Light / Dark, default System.
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
                    .foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Choose Light or Dark, or follow your device's system setting. Theme colors are edited separately and applied across Fleet together.")
                    .foregroundStyle(theme.textSecondary)
            }

            Section {
                Button {
                    showingThemeEditor = true
                } label: {
                    Label("Theme", systemImage: "paintpalette")
                        .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fleet.settings.theme")
            } header: {
                Text("Theme")
                    .foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Choose an opaque Highlight, Text, and Background color. Changes stay in a preview until you apply them.")
                    .foregroundStyle(theme.textSecondary)
            }

            // C2: the ALWAYS-REACHABLE door to the agent setup prompt. The
            // old onboarding entry only existed in the empty-gateways state,
            // so it silently vanished for anyone with a configured gateway.
            Section {
                Button {
                    showingSetupPrompt = true
                } label: {
                    Label("Agent Setup Prompt", systemImage: "text.badge.star")
                        .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fleet.settings.setup-prompt")
            } header: {
                Text("Agent")
                    .foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Copy or share the versioned setup prompt for your Hermes agent.")
                    .foregroundStyle(theme.textSecondary)
            }

            Section {
                LabeledContent("Version", value: Self.appVersion)
                    .accessibilityIdentifier("fleet.settings.version")
            } footer: {
                Text("Hermes Fleet — a pocket operations console for your agents.")
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .tint(theme.highlight)
        // C2: the setup-prompt door — standard sheet presentation.
        .sheet(isPresented: $showingSetupPrompt) {
            SetupPromptSheet()
        }
        .sheet(isPresented: $showingThemeEditor) {
            NavigationStack {
                FleetThemeEditorView(controller: themeController)
            }
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

/// Local-draft editor for the applied V1 palette. ColorPicker changes only
/// `draft`; the rest of the app observes `FleetThemeController.activePalette`
/// and therefore does not change until Apply (or the explicit Reset action).
public struct FleetThemeEditorView: View {
    private let controller: FleetThemeController
    @State private var draft: FleetThemePalette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init(controller: FleetThemeController = FleetThemeController.shared) {
        self.controller = controller
        #if DEBUG
        let debugPalette: FleetThemePalette? = if ProcessInfo.processInfo.arguments.contains("-issue6-low-contrast") {
            .lowContrastFixture
        } else if ProcessInfo.processInfo.arguments.contains("-issue6-arbitrary-theme") {
            .arbitraryFixture
        } else {
            nil
        }
        _draft = State(initialValue: debugPalette ?? controller.activePalette)
        #else
        _draft = State(initialValue: controller.activePalette)
        #endif
    }

    public var body: some View {
        Form {
            Section {
                ColorPicker("Highlight", selection: highlightBinding, supportsOpacity: false)
                    .accessibilityValue(draft.highlight.hexString)
                    .accessibilityIdentifier("fleet.theme.highlight")
                ColorPicker("Text", selection: textBinding, supportsOpacity: false)
                    .accessibilityValue(draft.text.hexString)
                    .accessibilityIdentifier("fleet.theme.text")
                ColorPicker("Background", selection: backgroundBinding, supportsOpacity: false)
                    .accessibilityValue(draft.background.hexString)
                    .accessibilityIdentifier("fleet.theme.background")
            } header: {
                Text("Palette")
            } footer: {
                Text("Fleet stores one opaque sRGB palette. Any color is allowed; contrast warnings are advisory in normal appearance.")
            }

            Section("Preview") {
                preview
                    .accessibilityIdentifier("fleet.theme.preview")
            }

            Section("Contrast") {
                contrastSummary
            }

            Section {
                Button("Reset to Fleet Default") {
                    controller.reset()
                    draft = controller.activePalette
                }
                .accessibilityIdentifier("fleet.theme.reset")
            }
        }
        .navigationTitle("Theme")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("fleet.theme.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    controller.apply(draft)
                    dismiss()
                }
                .accessibilityIdentifier("fleet.theme.apply")
            }
        }
        .tint(previewTheme.highlight)
    }

    private var previewTheme: FleetThemeValues {
        FleetThemeValues(
            palette: draft,
            isDarkAppearance: colorScheme == .dark,
            isIncreasedContrast: colorSchemeContrast == .increased)
    }

    private var report: FleetThemeContrastReport {
        FleetThemeContrastReport(palette: draft, isDark: colorScheme == .dark)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Text("Assistant response")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(previewTheme.textPrimary)
            Text("The same palette styles prose, links, code, and controls throughout Fleet.")
                .font(.body)
                .foregroundStyle(previewTheme.textPrimary)
            Link("Open documentation", destination: URL(string: "https://example.com")!)
                .foregroundStyle(previewTheme.highlight)
            Text("inline code")
                .font(FleetTheme.monoFont)
                .foregroundStyle(previewTheme.textPrimary)
                .padding(.horizontal, FleetTheme.spacingSm)
                .padding(.vertical, FleetTheme.spacingXs)
                .background(previewTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
            Button("Primary action") {}
                .buttonStyle(.borderedProminent)
                .tint(previewTheme.highlight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FleetTheme.spacingMd)
        .background(previewTheme.background)
        .overlay {
            RoundedRectangle(cornerRadius: FleetTheme.radiusCard)
                .stroke(previewTheme.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: FleetTheme.radiusCard))
    }

    @ViewBuilder
    private var contrastSummary: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            Text("Text contrast: \(formatted(report.textToBackground))")
                .accessibilityIdentifier("fleet.theme.contrast.text")
            Text("Highlight contrast: \(formatted(report.highlightToBackground))")
                .accessibilityIdentifier("fleet.theme.contrast.highlight")
            Text("Highlight control text: \(formatted(report.highlightControlText))")
                .accessibilityIdentifier("fleet.theme.contrast.control")
            if report.hasWarning {
                Label("Low contrast — this combination may be difficult to read.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(FleetTheme.statusNeedsIntervention)
                    .accessibilityIdentifier("fleet.theme.contrast.warning")
            } else {
                Label("Contrast meets the Fleet preview thresholds.", systemImage: "checkmark.circle")
                    .foregroundStyle(FleetTheme.statusOnline)
            }
        }
        .font(FleetTheme.secondaryFont)
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.1f:1", value)
    }

    private var highlightBinding: Binding<Color> {
        Binding(
            get: { draft.highlight.swiftUIColor },
            set: { if let color = FleetStoredColor(color: $0) { draft.highlight = color } })
    }

    private var textBinding: Binding<Color> {
        Binding(
            get: { draft.text.swiftUIColor },
            set: { if let color = FleetStoredColor(color: $0) { draft.text = color } })
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: { draft.background.swiftUIColor },
            set: { if let color = FleetStoredColor(color: $0) { draft.background = color } })
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
