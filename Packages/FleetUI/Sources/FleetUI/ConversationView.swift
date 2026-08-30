import SwiftUI
import FleetCore
import FleetPersistence

/// Conversation canvas (U3) — the full streaming/replay/reconnect screen.
///
/// Drives a `ConversationViewModel` (observable) built by the composition root
/// over the FleetCore `ConversationSessionProviding` seam. Renders:
/// - the transcript (user/assistant/tool/status/system/error rows),
/// - a composer (send; Stop while a turn is streaming → interrupt),
/// - reconnect / replay-hydration banner (M6),
/// - 4401 re-auth UX (M11 — explicit re-authenticate, never a silent retry),
/// - cold-start persisted history indicator (M10).
///
/// FleetUI depends only on FleetCore seams; the transport module is wired by
/// the app composition root (M0 hard guard).
public struct ConversationView: View {
    private let environment: AppEnvironment
    private let route: Route
    private let sessionID: String?

    @State private var viewModel: ConversationViewModel?
    @State private var composerText = ""

    public init(environment: AppEnvironment, route: Route, sessionID: String?) {
        self.environment = environment
        self.route = route
        self.sessionID = sessionID
    }

    public var body: some View {
        Group {
            if let viewModel {
                canvas(viewModel)
            } else {
                unavailable
            }
        }
        .navigationTitle(route.profileSlug.rawValue)
        .task {
            if viewModel == nil {
                viewModel = environment.makeConversationViewModel(route: route, sessionID: sessionID)
            }
            await viewModel?.start()
        }
        .onDisappear {
            viewModel?.teardown()
        }
        .background(FleetTheme.background.ignoresSafeArea())
    }

    // MARK: Canvas

    private func canvas(_ model: ConversationViewModel) -> some View {
        VStack(spacing: 0) {
            bannerArea(model)
            transcriptList(model)
            composer(model)
        }
    }

    // MARK: Status / reconnect / replay / auth banners

    @ViewBuilder
    private func bannerArea(_ model: ConversationViewModel) -> some View {
        VStack(spacing: 0) {
            if let replayNotice = model.replayNotice, model.phase != .streaming {
                banner(text: replayNotice, symbol: "arrow.triangle.2.circlepath", tint: FleetTheme.accentColdBlue)
            }
            switch model.phase {
            case .idle, .opening:
                banner(text: "Opening conversation…", symbol: "hourglass", tint: FleetTheme.textSecondary, spinner: true)
            case .connecting:
                banner(text: "Connecting…", symbol: "bolt.horizontal", tint: FleetTheme.textSecondary, spinner: true)
            case .reconnecting:
                banner(text: "Reconnecting…", symbol: "arrow.clockwise", tint: FleetTheme.textSecondary, spinner: true)
            case .disconnected:
                HStack(spacing: 12) {
                    banner(text: "Connection lost — replayed history is shown. Reconnect to continue.",
                           symbol: "wifi.slash", tint: FleetTheme.accent)
                    Button("Reconnect") {
                        Task { await model.reconnect() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("fleet.conversation.reconnect")
                }
            case .authRequired:
                HStack(spacing: 12) {
                    banner(text: model.errorMessage ?? "Authentication required.",
                           symbol: "exclamationmark.lock", tint: FleetTheme.accent)
                    Button("Re-authenticate") {
                        Task { await model.reauthenticate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FleetTheme.accent)
                    .controlSize(.small)
                    .accessibilityIdentifier("fleet.conversation.reauthenticate")
                }
            case .failed(let detail):
                banner(text: detail, symbol: "exclamationmark.triangle", tint: FleetTheme.accent)
            case .ready, .streaming:
                if model.hydratedFromCache {
                    banner(text: "Showing saved history — connecting for live updates.",
                           symbol: "internaldrive", tint: FleetTheme.textSecondary)
                } else if let errorMessage = model.errorMessage {
                    banner(text: errorMessage, symbol: "exclamationmark.triangle", tint: FleetTheme.accent)
                }
            }
        }
        .animation(.default, value: model.phase)
    }

    private func banner(
        text: String,
        symbol: String,
        tint: Color,
        spinner: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            if spinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(FleetTheme.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(FleetTheme.surface)
        .accessibilityElement(children: .combine)
    }

    // MARK: Transcript

    private func transcriptList(_ model: ConversationViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.transcript) { row in
                        ConversationBubbleView(row: row)
                            .id(row.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: model.transcript.count) {
                if let last = model.transcript.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("fleet.conversation.transcript")
    }

    // MARK: Composer

    private func composer(_ model: ConversationViewModel) -> some View {
        HStack(spacing: 8) {
            TextField("Message", text: $composerText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(model.phase != .ready && model.phase != .streaming)
                .accessibilityIdentifier("fleet.conversation.composer")
                .onSubmit {
                    Task { await submit(model) }
                }

            if model.phase == .streaming || model.isStreaming {
                Button {
                    Task { await model.interrupt() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(FleetTheme.accent)
                .accessibilityIdentifier("fleet.conversation.stop")
            } else {
                Button {
                    Task { await submit(model) }
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(FleetTheme.accent)
                .disabled(model.phase != .ready)
                .accessibilityIdentifier("fleet.conversation.send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(FleetTheme.surface)
    }

    private func submit(_ model: ConversationViewModel) async {
        let text = composerText
        composerText = ""
        await model.send(text)
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label {
                Text("Conversation Unavailable")
            } icon: {
                Image(systemName: "text.bubble")
                    .foregroundStyle(FleetTheme.accent)
            }
        } description: {
            Text("This gateway has no conversation session wired.")
        }
        .accessibilityIdentifier("fleet.conversation.unavailable")
    }
}

/// One transcript row: user/assistant/tool/status/system/error bubble.
private struct ConversationBubbleView: View {
    let row: ConversationRow

    var body: some View {
        HStack {
            if row.kind == .user { Spacer(minLength: 60) }
            VStack(alignment: row.kind == .user ? .trailing : .leading, spacing: 4) {
                bubbleContent
                    .frame(maxWidth: 420, alignment: row.kind == .user ? .trailing : .leading)
            }
            if row.kind != .user { Spacer(minLength: 60) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.row.\(row.id)")
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch row.kind {
        case .user:
            Text(row.text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(FleetTheme.accent, in: RoundedRectangle(cornerRadius: 18))
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .textSelection(.enabled)
                }
                Text(row.text.isEmpty ? (row.isStreaming ? "…" : "") : row.text)
                    .font(.body)
                    .foregroundStyle(row.isFailed ? FleetTheme.accent : FleetTheme.textPrimary)
                    .textSelection(.enabled)
                if row.isStreaming {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(FleetTheme.textSecondary)
                                .frame(width: 5, height: 5)
                                .opacity(0.6)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(FleetTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18))
        case .tool:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.text).font(.caption.weight(.semibold))
                    if let detail = row.detail, !detail.isEmpty {
                        Text(detail).font(.caption2).foregroundStyle(FleetTheme.textSecondary)
                    }
                }
            } icon: {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(FleetTheme.accentColdBlue)
            }
            .padding(10)
            .background(FleetTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        case .status, .system:
            Text(row.text)
                .font(.caption)
                .foregroundStyle(FleetTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Label(row.text, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(FleetTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
#Preview("Empty conversation") {
    NavigationStack {
        ConversationView(
            environment: AppEnvironment(
                registry: PreviewRegistry(),
                roster: PreviewRoster(),
                cache: try! SwiftDataCacheStore.makeInMemory(),
                sessionList: PreviewSessionList(),
                connectionFactory: { gateway, _ in PreviewConnection(gatewayID: gateway.id) },
                conversationFactory: { gateway, _ in PreviewConversationSession(gatewayID: gateway.id) }
            ),
            route: Route(
                gatewayID: GatewayID(rawValue: "<dev-workstation>"),
                profileSlug: ProfileSlug(rawValue: "default")
            ),
            sessionID: nil
        )
    }
}

// MARK: - Preview seams (DEBUG only, no transport import)

private struct PreviewConnection: GatewayConnectivityProviding {
    let gatewayID: GatewayID
    var status: GatewayStatus { .offline }
    func adoptedReady() async -> GatewayReadyAdoption? { nil }
    func connect() async throws {}
    func disconnect() async {}
    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }
}

private struct PreviewRegistry: GatewayRegistryManaging {
    func allGateways() async -> [FleetGateway] { [] }
    func gateway(for id: GatewayID) async -> FleetGateway? { nil }
    func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway {
        // The registration id is optional (derived from endpoint in the real
        // service); for the DEBUG preview, synthesize a stable display key.
        FleetGateway(
            id: registration.id ?? GatewayID(rawValue: "preview-\(registration.displayName)"),
            displayName: registration.displayName,
            endpoint: registration.endpoint
        )
    }
    func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
        FleetGateway(id: id, displayName: "preview", endpoint: nil)
    }
    func removeGateway(_ id: GatewayID) async throws {}
    func testConnection(to id: GatewayID) async throws -> GatewayTestResult {
        GatewayTestResult(status: .offline)
    }
    func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {}
    func clearCredential(for id: GatewayID) async throws {}
    func hasCredential(for id: GatewayID) async -> Bool { false }
}

private struct PreviewRoster: FleetRosterProviding {
    func refreshRoster() async -> FleetRosterSnapshot {
        FleetRosterSnapshot()
    }
}

private struct PreviewSessionList: SessionListProviding {
    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
}

private struct PreviewConversationSession: ConversationSessionProviding {
    let gatewayID: GatewayID
    var status: GatewayStatus { .offline }
    func adoptedReady() async -> GatewayReadyAdoption? { nil }
    func connect() async throws {}
    func disconnect() async {}
    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }
    func reauthenticate() async throws {}
    var conversation: any ConversationProviding {
        PreviewConversation()
    }
    var replay: any ReplayProviding { PreviewReplay(gatewayID: gatewayID) }
    var history: any SessionHistoryProviding { PreviewHistory(gatewayID: gatewayID) }
}

private struct PreviewConversation: ConversationProviding {
    func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
        ConversationSession(sessionID: "preview")
    }
    func resumeSession(sessionID: String) async throws -> ConversationSession {
        ConversationSession(sessionID: sessionID)
    }
    func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
        PromptSubmission(status: "streaming")
    }
    func interrupt(sessionID: String) async throws -> InterruptResult {
        InterruptResult(status: "interrupted")
    }
    var events: AsyncStream<ConversationEvent> {
        AsyncStream { _ in }
    }
}

private struct PreviewReplay: ReplayProviding {
    let gatewayID: GatewayID
    func watermarks() async -> [SessionEventWatermark] { [] }
    func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }
}

private struct PreviewHistory: SessionHistoryProviding {
    let gatewayID: GatewayID
    func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
        SessionHistory(sessionID: sessionID, count: 0, messages: [])
    }
    func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
        SessionStatus.parse(output: "Session ID: \(sessionID)")
    }
}
#endif
