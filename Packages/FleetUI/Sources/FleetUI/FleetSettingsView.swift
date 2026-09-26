import Foundation
import SwiftUI

/// ADR-0011 — Settings is a first-class tab (Build 43) restructured into the
/// ChatGPT anatomy: quick Theme value-pickers at the top, "App settings"
/// chevron rows pushing sub-screens (`FleetScreen.settingsSecurity` /
/// `.settingsData` — the Settings stack is typed `[FleetScreen]`, so the
/// sub-routes are Settings-owned FleetScreen cases), and the always-
/// reachable Agent Setup Prompt (C2). Version, legal, and support live in
/// the About tab (`FleetAboutView`). No invented preferences (SPEC §12):
/// every control maps to implemented behavior.
public struct FleetSettingsView: View {
    private let appearanceController: FleetAppearanceController
    private let themeController: FleetThemeController
    /// Dogfood round 2 (ADR-0011): the About row selects the About TAB
    /// (the drawer circle is retired — Settings is About's entry point).
    private let onSelectAbout: () -> Void
    /// Dogfood r4 (decision 6): Manage Gateways is duplicated into Settings
    /// — routes via open(.gateways), which selects the Fleet tab and pushes
    /// the registry cockpit (the Command Center routing contract).
    private let onOpenGateways: () -> Void
    /// P0-A: the runtime, used by the "Report a Problem" row to assemble the
    /// sanitized diagnostics report. Optional — previews and non-runtime
    /// call sites pass nil and the row is omitted (the
    /// `FleetSettingsDataView` pattern).
    private let environment: AppEnvironment?

    /// C2: presents the always-reachable agent setup prompt sheet.
    @State private var showingSetupPrompt = false
    /// P0-A: presents the "Report a Problem" diagnostics report sheet.
    @State private var showingDiagnosticsReport = false
    @Environment(\.fleetTheme) private var theme

    public init(appearanceController: FleetAppearanceController = FleetAppearanceController.shared,
                themeController: FleetThemeController = FleetThemeController.shared,
                onSelectAbout: @escaping () -> Void = {},
                onOpenGateways: @escaping () -> Void = {},
                environment: AppEnvironment? = nil) {
        self.appearanceController = appearanceController
        self.themeController = themeController
        self.onSelectAbout = onSelectAbout
        self.onOpenGateways = onOpenGateways
        self.environment = environment
    }

    public var body: some View {
        Form {
            // ADR-0011 W2: Appearance collapses to ONE Menu row (ChatGPT
            // value-picker anatomy). Same options, same immediate apply
            // through FleetAppearanceController.shared; the identifier
            // `fleet.settings.appearance` is KEPT (contract continuity).
            Section {
                Menu {
                    ForEach(FleetAppearance.allCases) { appearance in
                        Button {
                            appearanceController.selection = appearance
                        } label: {
                            if appearance == appearanceController.selection {
                                Label(appearance.label, systemImage: "checkmark")
                            } else {
                                Text(appearance.label)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Label("Appearance", systemImage: "circle.lefthalf.filled")
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text(appearanceController.selection.label)
                            .foregroundStyle(theme.textSecondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .accessibilityLabel("Appearance, \(appearanceController.selection.label)")
                .accessibilityIdentifier("fleet.settings.appearance")

                // ChatGPT-style accent picker (dogfood: the full theme
                // editor is retired from Settings; the picker applies a
                // curated highlight over Fleet-default colors IMMEDIATELY).
                Menu {
                    ForEach(FleetAccent.allCases) { accent in
                        Button {
                            applyAccent(accent)
                        } label: {
                            HStack {
                                Text(accent.label)
                                if accent == currentAccent {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .accessibilityIdentifier("fleet.settings.accent.\(accent.rawValue)")
                    }
                } label: {
                    HStack {
                        Circle()
                            .fill(Color(accentColorHighlight.uiColor))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
                            .accessibilityHidden(true)
                        Text("Accent")
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                        Text(currentAccent?.label ?? "Custom")
                            .foregroundStyle(theme.textSecondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .accessibilityLabel("Accent, \(currentAccent?.label ?? "Custom")")
                .accessibilityIdentifier("fleet.settings.accent")
            } header: {
                Text("Theme")
                    .foregroundStyle(theme.textSecondary)
            }

            // ADR-0011 W3/W4: App settings is a chevron group — Security
            // and Data & Storage push sub-screens on the Settings stack.
            Section {
                NavigationLink(value: FleetScreen.settingsSecurity) {
                    Label("Security", systemImage: "faceid")
                        .foregroundStyle(theme.textPrimary)
                }
                .accessibilityIdentifier("fleet.settings.security")
                // Dogfood r4: gateway management duplicated from the Fleet
                // dashboard into Settings (App settings group).
                Button {
                    onOpenGateways()
                } label: {
                    Label("Manage Gateways", systemImage: "server.rack")
                        .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fleet.settings.gateways")
                NavigationLink(value: FleetScreen.settingsData) {
                    Label("Data & Storage", systemImage: "externaldrive")
                        .foregroundStyle(theme.textPrimary)
                }
                .accessibilityIdentifier("fleet.settings.data")
                // P0-A: the diagnostics door. Rendered only when the
                // runtime is available (previews pass nil).
                if let environment {
                    Button {
                        showingDiagnosticsReport = true
                    } label: {
                        Label("Report a Problem", systemImage: "exclamationmark.bubble")
                            .foregroundStyle(theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("fleet.settings.report-problem")
                    .sheet(isPresented: $showingDiagnosticsReport) {
                        DiagnosticsReportSheet(environment: environment)
                    }
                }
            } header: {
                Text("App settings")
                    .foregroundStyle(theme.textSecondary)
            }

            // C2: the ALWAYS-REACHABLE door to the agent setup prompt. With
            // one or more gateways configured this is the add-another-server
            // path; the sheet itself carries the copy. The row stays
            // available with 1, 2, or 20 gateways.
            Section {
                Button {
                    showingSetupPrompt = true
                } label: {
                    Label("Set Up Another Server", systemImage: "text.badge.star")
                        .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fleet.settings.setup-prompt")
            } header: {
                Text("Agent")
                    .foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Copy or share the setup prompt to add another Hermes server to Fleet.")
                    .foregroundStyle(theme.textSecondary)
            }

            // ADR-0011 W8: version + legal + support rows moved to the
            // About tab (FleetAboutView) — retired ids are pinned by
            // source guards in the hosted composition tests.
            //
            // Dogfood round 2: the About tab's entry point is HERE (the
            // drawer circle is retired). The chevron reads as "more"; the
            // row selects the About tab.
            Section {
                // Same Button shape as the proven C2 setup-prompt row
                // (trailing-closure action, single Label, .plain style) —
                // the HStack/Spacer/chevron label variant did not fire in
                // Form on iOS 26 (measured: action never invoked).
                Button {
                    onSelectAbout()
                } label: {
                    Label("About", systemImage: "info.circle")
                        .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fleet.settings.about")
            } header: {
                Text("About")
                    .foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Version, terms, privacy, and support.")
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
        .navigationTitle("Settings")
        .accessibilityIdentifier("fleet.settings")
    }

    // MARK: - Accent picker support (ChatGPT-style)

    private var currentAccent: FleetAccent? {
        FleetAccent.matching(active: themeController.activePalette)
    }

    private var accentColorHighlight: FleetStoredColor {
        // ADR-0009: the swatch shows the ACTIVE appearance's resolution
        // (the mono White accent renders near-black in light, white in dark).
        theme.resolvedPalette.highlight
    }

    private func applyAccent(_ accent: FleetAccent) {
        // Immediate apply — the ChatGPT contract. The controller's
        // invisible-pair guard still runs (all 7 pass over Fleet-default
        // backgrounds by construction).
        themeController.apply(accent.palette)
    }
}

/// ADR-0011 W3: the Security sub-screen — the App Lock toggle and its real
/// biometric/passcode behavior, unchanged from the pre-restructure surface.
public struct FleetSettingsSecurityView: View {
    private let controller: AppLockController
    @Environment(\.fleetTheme) private var theme

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
                        .foregroundStyle(theme.textPrimary)
                }
                .accessibilityIdentifier("fleet.settings.app-lock.toggle")
            } footer: {
                Text("Require Face ID (or your device passcode) to unlock "
                     + "Hermes Fleet when the app opens. Stored gateway "
                     + "credentials stay protected by the Keychain.")
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .tint(theme.highlight)
        .navigationTitle("Security")
        .accessibilityIdentifier("fleet.settings.security.screen")
    }
}

/// ADR-0011 W4: the Data & Storage sub-screen — the destructive cache-clear
/// action, its confirmation dialog, and failure alert, unchanged from the
/// pre-restructure surface.
public struct FleetSettingsDataView: View {
    private let environment: AppEnvironment?
    @State private var showingCacheClearConfirmation = false
    @State private var cacheClearFailed = false
    @State private var cacheClearError = ""
    @State private var clearingCache = false
    @Environment(\.fleetTheme) private var theme

    public init(environment: AppEnvironment? = nil) {
        self.environment = environment
    }

    public var body: some View {
        Form {
            Section {
                if environment != nil {
                    Button("Delete Local Cache", role: .destructive) {
                        showingCacheClearConfirmation = true
                    }
                    .disabled(clearingCache)
                    .accessibilityIdentifier("fleet.settings.delete-local-cache")
                }
            } footer: {
                Text("Deletes cached conversations, roster snapshots, health history, and recent destinations. Saved gateways and Keychain credentials are kept.")
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .tint(theme.highlight)
        .confirmationDialog("Delete local cache?", isPresented: $showingCacheClearConfirmation, titleVisibility: .visible) {
            Button("Delete Cache", role: .destructive) {
                guard let environment else { return }
                clearingCache = true
                Task {
                    do {
                        try await environment.clearLocalCache()
                    } catch {
                        cacheClearError = "The local cache could not be deleted. Try again after closing any active gateway operation."
                        cacheClearFailed = true
                    }
                    clearingCache = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes cached fleet and conversation data from this device. Saved gateways and credentials are not removed.")
        }
        .alert("Unable to Delete Cache", isPresented: $cacheClearFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cacheClearError)
        }
        .navigationTitle("Data & Storage")
        .accessibilityIdentifier("fleet.settings.data.screen")
    }
}

/// Local-draft editor for the applied V1 palette. ColorPicker changes only
/// `draft`; the rest of the app observes `FleetThemeController.activePalette`
/// and therefore does not change until Apply (or the explicit Reset action).
public struct FleetThemeEditorView: View {
    private let controller: FleetThemeController
    @State private var draft: FleetThemePalette
    @State private var colorConversionFailed = false
    @State private var applyFailed = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init(controller: FleetThemeController = FleetThemeController.shared) {
        self.controller = controller
        #if DEBUG
        let debugPalette: FleetThemePalette? = if ProcessInfo.processInfo.arguments.contains("-issue6-low-contrast") {
            .lowContrastFixture
        } else if ProcessInfo.processInfo.arguments.contains("-b41-white-highlight") {
            FleetThemePalette(
                highlight: FleetStoredColor(hex: 0xFFFFFF),
                text: FleetStoredColor(hex: 0xF5F5F7),
                background: FleetStoredColor(hex: 0x101216))
        } else if ProcessInfo.processInfo.arguments.contains("-b41-invisible-palette") {
            FleetThemePalette(
                highlight: FleetStoredColor(hex: 0xFFFFFF),
                text: FleetStoredColor(hex: 0x1C1C1E),
                background: FleetStoredColor(hex: 0xFFFFFF))
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
                Text("Fleet stores one opaque sRGB palette. Any color is allowed; contrast warnings are advisory. A palette whose highlight or text would be invisible against its background in either appearance cannot be applied.")
            }

            if colorConversionFailed {
                Label(
                    "That color could not be stored as an opaque sRGB value. Try another color.",
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(FleetTheme.statusNeedsIntervention)
                    .accessibilityIdentifier("fleet.theme.color-conversion-error")
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
                    // Reset is a draft change like any other editor change;
                    // the app and persisted value remain untouched until the
                    // explicit Apply action.
                    draft = controller.defaultPalette
                    colorConversionFailed = false
                    applyFailed = false
                }
                .accessibilityIdentifier("fleet.theme.reset")
            }

            if applyFailed {
                Label(
                    "This palette cannot be applied: a color would be invisible against its background in light or dark appearance. Your current theme is unchanged.",
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(FleetTheme.statusDestructive)
                    .accessibilityIdentifier("fleet.theme.apply-error")
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
                    if controller.apply(draft) {
                        applyFailed = false
                        dismiss()
                    } else {
                        applyFailed = true
                    }
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
            Link("Open documentation", destination: URL(string: "https://github.com/AIowa-LLC/hermes-fleet/blob/main/docs/features.md")!)
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
                .foregroundStyle(previewTheme.onHighlight)
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
            set: {
                guard let color = FleetStoredColor(color: $0) else {
                    colorConversionFailed = true
                    return
                }
                colorConversionFailed = false
                draft.highlight = color
                if draft.appearance == .adaptiveFleetDefault {
                    draft.appearance = .adaptiveCustomHighlight
                }
            })
    }

    private var textBinding: Binding<Color> {
        Binding(
            get: { draft.text.swiftUIColor },
            set: {
                guard let color = FleetStoredColor(color: $0) else {
                    colorConversionFailed = true
                    return
                }
                colorConversionFailed = false
                draft.text = color
                draft.appearance = .fixed
            })
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: { draft.background.swiftUIColor },
            set: {
                guard let color = FleetStoredColor(color: $0) else {
                    colorConversionFailed = true
                    return
                }
                colorConversionFailed = false
                draft.background = color
                draft.appearance = .fixed
            })
    }
}

#if DEBUG
#Preview("Settings") {
    NavigationStack {
        FleetSettingsView()
    }
    .preferredColorScheme(.dark)
}

#Preview("Security") {
    NavigationStack {
        FleetSettingsSecurityView(controller: .init(auth: AlwaysSuccessSettingsAuth()))
    }
    .preferredColorScheme(.dark)
}

private struct AlwaysSuccessSettingsAuth: AppLockBiometricAuth {
    func canEvaluateBiometrics() -> Bool { true }
    func evaluateBiometrics(reason: String) async -> AppLockAuthResult { .success }
    func evaluateDevicePasscode(reason: String) async -> Bool { true }
}
#endif
