import SwiftUI
import UIKit
import FleetCore

/// P0-A "Report a Problem": the sanitized diagnostics report sheet.
///
/// The sheet assembles a `DiagnosticsReportInput` from facts this process
/// already holds (bundle version/build, OS version, hardware identifier,
/// per-gateway connection + capability state, the recorded faults) and renders
/// it with `DiagnosticsReport.render`. Nothing is sent anywhere: the user
/// copies or shares the text themselves, which is why the redaction guarantees
/// matter.
///
/// Gateway endpoints are redacted for local display before they reach the
/// input, and the renderer applies stricter share-report redaction to every
/// free-text field before the user copies or shares it.
public struct DiagnosticsReportSheet: View {
    let environment: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @Environment(\.fleetTheme) private var theme

    /// Facts gathered once per presentation (id, timestamp, hardware, gateway
    /// state). The description is layered on at render time, so typing never
    /// changes the report id or re-reads the device.
    @State private var baseInput: DiagnosticsReportInput?
    @State private var problemDescription = ""
    @State private var previewExpanded = false
    @State private var actionStatus: ActionStatus?
    /// The newest status owns the dismissal (AssistantReplyFooter pattern).
    @State private var statusResetTask: Task<Void, Never>?
    @Environment(\.openURL) private var openURL
    @FocusState private var descriptionFocused: Bool

    enum ActionStatus: Equatable {
        case copied
        case copyFailed
        case openFailed

        var text: String {
            switch self {
            case .copied: "Copied"
            case .copyFailed: "Couldn't copy the report. Try Share instead."
            case .openFailed: "Couldn't open the support page."
            }
        }
        var isFailure: Bool { self != .copied }
    }

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// The exact text Copy and Share hand to the user. Empty until the base
    /// facts are gathered.
    private var reportText: String {
        guard let baseInput else { return "" }
        return DiagnosticsReport.render(baseInput.withUserDescription(problemDescription))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                    explanation
                    descriptionField
                    previewDisclosure
                    actions
                    supportNote
                }
                .padding(FleetTheme.spacingMd)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Surface identity attaches BEFORE any toolbar/inset content, so
            // descendant ids stay queryable (drawer-scrollview order rule).
            .accessibilityIdentifier("fleet.diagnostics.sheet")
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Report a Problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Nothing has been sent anywhere, so closing simply discards
                // the draft.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("fleet.diagnostics.done")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Hide keyboard") { descriptionFocused = false }
                        .accessibilityIdentifier("fleet.diagnostics.hide-keyboard")
                }
            }
        }
        .tint(theme.highlight)
        .onAppear {
            if baseInput == nil { baseInput = makeBaseInput() }
        }
    }

    // MARK: - Sections

    private var explanation: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Text("This builds a report you can review, then copy or share yourself. Nothing is sent automatically.")
                .font(.body)
                .foregroundStyle(theme.textPrimary)
            Text("Included: app version, iOS version and device model, your gateways' names, connection state and capabilities (addresses hidden), and recent errors the app recorded.")
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
            Text("Not included: messages, credentials, or server addresses.")
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("fleet.diagnostics.explanation")
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            Text("What happened?")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $problemDescription)
                    .focused($descriptionFocused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(FleetTheme.spacingSm)
                    .accessibilityIdentifier("fleet.diagnostics.description")
                    .accessibilityLabel("What happened?")
                if problemDescription.isEmpty {
                    Text("What were you doing, and what did you expect?")
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, FleetTheme.spacingSm + 5)
                        .padding(.vertical, FleetTheme.spacingSm + 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            Text("Don't paste passwords, tokens, or private messages. Links and token-like text are masked automatically, but check the preview.")
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var previewDisclosure: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { previewExpanded.toggle() }
            } label: {
                HStack {
                    Text("Preview report")
                        .font(.headline)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(previewExpanded ? 90 : 0))
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(previewExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the exact text that Copy and Share will use")
            .accessibilityIdentifier("fleet.diagnostics.preview")
            if previewExpanded {
                Text(reportText.isEmpty ? "Preparing report…" : reportText)
                    .font(FleetTheme.monoFont)
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("fleet.diagnostics.text")
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Button {
                copyReport()
            } label: {
                Label("Copy report", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(baseInput == nil)
            .accessibilityIdentifier("fleet.diagnostics.copy")

            ShareLink(item: reportText) {
                Label("Share…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(baseInput == nil)
            .accessibilityIdentifier("fleet.diagnostics.share")

            if let actionStatus {
                Text(actionStatus.text)
                    .font(.footnote)
                    .foregroundStyle(actionStatus.isFailure ? theme.textPrimary : theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(actionStatus == .copied
                        ? "fleet.diagnostics.copied" : "fleet.diagnostics.status")
            }
        }
    }

    private var supportNote: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Button {
                openSupportPage()
            } label: {
                Label("Open support page", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("fleet.diagnostics.support")
            Text("The support page is a public issue tracker, so anything you post there is visible to everyone. Review the report before posting it.")
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func show(_ status: ActionStatus) {
        withAnimation(.easeIn(duration: 0.15)) { actionStatus = status }
        statusResetTask?.cancel()
        statusResetTask = Task {
            try? await Task.sleep(for: .seconds(status.isFailure ? 4 : 2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { actionStatus = nil }
        }
    }

    private func copyReport() {
        let text = reportText
        guard !text.isEmpty else { show(.copyFailed); return }
        UIPasteboard.general.string = text
        // `hasStrings` does not trigger the paste-permission prompt; "Copied"
        // is only claimed once the pasteboard really holds text.
        show(UIPasteboard.general.hasStrings ? .copied : .copyFailed)
    }

    private func openSupportPage() {
        openURL(FleetLegal.supportURL) { accepted in
            if !accepted { show(.openFailed) }
        }
    }

    // MARK: - Assembly

    /// Build the report. `surfaceContext` names the surface that generated
    /// it ("Settings · Report a Problem") — factual, never invented.
    private func makeBaseInput(now: Date = Date()) -> DiagnosticsReportInput {
        let info = Bundle.main.infoDictionary
        let sections = environment.gateways.map { gateway in
            DiagnosticsGatewaySection(
                label: gateway.displayName,
                endpointDisplay: gateway.endpoint.map(Redaction.redactedURL) ?? "not configured",
                connectionState: GatewayConnectionCopy.label(environment.connectionStates[gateway.id] ?? .idle),
                transportCapabilities: transportCapabilities(for: gateway.id),
                groupsCapability: groupsCapability(for: gateway.id),
                rosterSummary: rosterSummary(for: gateway.id))
        }
        let events = environment.diagnosticsRecorder.snapshot().map { entry in
            DiagnosticsEvent(at: entry.at, category: entry.category, detail: entry.detail)
        }
        return DiagnosticsReportInput(
            generatedAt: now,
            reportID: DiagnosticsReport.makeReportID(now: now, suffix: Self.freshSuffix()),
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info?["CFBundleVersion"] as? String ?? "unknown",
            osVersion: UIDevice.current.systemVersion,
            deviceModel: Self.deviceModelIdentifier(),
            surfaceContext: "Settings · Report a Problem",
            gateways: sections,
            recentEvents: events,
            performance: FleetPerformanceReport.current())
    }

    /// Advertised transport capabilities: the last connection-test probe wins,
    /// falling back to the roster's gateway record. Sorted for a stable report.
    private func transportCapabilities(for id: GatewayID) -> [String] {
        let capabilities: Set<String>? = environment.testResults[id]?.capabilities.allStrings
            ?? environment.rosterSnapshot?.roster.gateways[id]?.capabilities
        return Array(capabilities ?? []).sorted()
    }

    /// `groups.create` capability from the app's last probe. Never probed ⇒
    /// "unknown" (fail closed — never "supported" by assumption).
    private func groupsCapability(for id: GatewayID) -> String {
        switch environment.canCreateRoomsByGateway[id] {
        case .some(true): return "supported"
        case .some(false): return "unsupported"
        case .none: return "unknown"
        }
    }

    /// One-line roster outcome, or nil when no settled refresh classified this
    /// gateway (absent is absent — the report renders no Roster row).
    private func rosterSummary(for id: GatewayID) -> String? {
        guard let outcome = environment.rosterSnapshot?.outcome(for: id) else { return nil }
        switch outcome {
        case .loaded(let profileCount): return "answered — \(profileCount) bots"
        case .failed(let status, _): return "did not answer — \(status.rawValue)"
        }
    }

    // MARK: - Device facts

    /// A 4-character random token for the report id. Fixed at 4 so the id
    /// format (`DF-<yyMMdd-HHmmss>-<4 alnum>`) always holds.
    private static func freshSuffix() -> String {
        String(UUID().uuidString
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            .prefix(4))
    }

    /// The hardware identifier (e.g. "iPhone17,2"). Computed once per report;
    /// a failed `uname` renders "unknown" instead of crashing.
    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }
        let bytes = withUnsafeBytes(of: &systemInfo.machine) { Array($0) }
        let identifier = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return identifier.isEmpty ? "unknown" : identifier
    }
}
