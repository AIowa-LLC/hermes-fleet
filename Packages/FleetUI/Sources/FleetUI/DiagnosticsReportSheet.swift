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

    /// The rendered report. Assembled once per presentation in `.onAppear` —
    /// the hardware identifier and bundle facts are read exactly once, and the
    /// text is stable while the sheet is open.
    @State private var reportText = ""
    @State private var showingCopiedConfirmation = false
    /// The newest copy tap owns the dismissal (AssistantReplyFooter pattern):
    /// without this, tapping copy twice starts two timers whose completion
    /// order is not guaranteed, so the first could hide the second's badge.
    @State private var copiedResetTask: Task<Void, Never>?

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                Text(reportText.isEmpty ? "Preparing report…" : reportText)
                    .font(FleetTheme.monoFont)
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FleetTheme.spacingMd)
                    .accessibilityIdentifier("fleet.diagnostics.text")
            }
            // Surface identity attaches BEFORE any toolbar/inset content, so
            // descendant ids stay queryable (drawer-scrollview order rule).
            .accessibilityIdentifier("fleet.diagnostics.sheet")
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Report a Problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Copy") { copyReport() }
                        .accessibilityIdentifier("fleet.diagnostics.copy")
                    ShareLink(item: reportText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("fleet.diagnostics.share")
                    if showingCopiedConfirmation {
                        Text("Copied")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(theme.textSecondary)
                            .transition(.opacity)
                            .accessibilityIdentifier("fleet.diagnostics.copied")
                    }
                }
            }
        }
        .tint(theme.highlight)
        .onAppear { reportText = makeReportText() }
    }

    // MARK: - Copy

    private func copyReport() {
        UIPasteboard.general.string = reportText
        withAnimation(.easeIn(duration: 0.15)) { showingCopiedConfirmation = true }
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { showingCopiedConfirmation = false }
        }
    }

    // MARK: - Assembly

    /// Build the report. `surfaceContext` names the surface that generated
    /// it ("Settings · Report a Problem") — factual, never invented.
    private func makeReportText(now: Date = Date()) -> String {
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
        let input = DiagnosticsReportInput(
            generatedAt: now,
            reportID: DiagnosticsReport.makeReportID(now: now, suffix: Self.freshSuffix()),
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info?["CFBundleVersion"] as? String ?? "unknown",
            osVersion: UIDevice.current.systemVersion,
            deviceModel: Self.deviceModelIdentifier(),
            surfaceContext: "Settings · Report a Problem",
            gateways: sections,
            recentEvents: events)
        return DiagnosticsReport.render(input)
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
