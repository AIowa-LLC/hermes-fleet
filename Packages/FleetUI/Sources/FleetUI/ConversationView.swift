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
            botHeader(model)
            bannerArea(model)
            transcriptList(model)
            composer(model)
        }
    }

    // MARK: Bot header (U6 — hero mock screen 2)

    /// Bot identity header: avatar, display name, canonical route, and a
    /// status pill, on the surface color with a hairline bottom border.
    /// The pill shows the roster bot's live activity when the route resolves;
    /// otherwise it projects the conversation phase onto the four pill states
    /// (never fabricates a livelier state than the connection has).
    private func botHeader(_ model: ConversationViewModel) -> some View {
        let bot = environment.bot(for: route)
        let name = bot?.displayName ?? route.profileSlug.rawValue
        return HStack(spacing: FleetTheme.spacingMd) {
            BotAvatar(displayName: name)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                    .lineLimit(1)
                Text(route.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(FleetTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            StatusPill(status: headerPillStatus(bot: bot, model: model))
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, FleetTheme.spacingSm)
        .background(FleetTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FleetTheme.border)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.header")
    }

    private func headerPillStatus(bot: FleetBot?, model: ConversationViewModel) -> FleetStatus {
        if let bot {
            // P0-7: presence (owning gateway's roster outcome) is the primary
            // signal; live conversation phase refines only when no roster bot.
            return FleetStatus(
                activity: bot.activity,
                presence: environment.botPresence(for: bot.route)
            )
        }
        switch model.phase {
        case .ready, .streaming:
            return .online
        case .idle, .opening, .connecting, .reconnecting:
            return .idle
        case .authRequired, .failed:
            return .degraded
        case .disconnected:
            return .offline
        }
    }

    // MARK: Status / reconnect / replay / auth banners

    @ViewBuilder
    private func bannerArea(_ model: ConversationViewModel) -> some View {
        VStack(spacing: 0) {
            if let integrityNotice = model.integrityNotice, model.phase != .streaming {
                banner(text: integrityNotice, symbol: "checkmark.shield", tint: FleetTheme.statusDegraded)
            }
            if let replayNotice = model.replayNotice, model.phase != .streaming {
                banner(text: replayNotice, symbol: "arrow.triangle.2.circlepath", tint: FleetTheme.accent)
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
                           symbol: "wifi.slash", tint: FleetTheme.statusDegraded)
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
                           symbol: "exclamationmark.lock", tint: FleetTheme.statusDegraded)
                    Button("Re-authenticate") {
                        Task { await model.reauthenticate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FleetTheme.accentMagenta)
                    .controlSize(.small)
                    .accessibilityIdentifier("fleet.conversation.reauthenticate")
                }
            case .failed(let detail):
                banner(text: detail, symbol: "exclamationmark.triangle", tint: FleetTheme.statusDegraded)
            case .ready, .streaming:
                if model.hydratedFromCache {
                    banner(text: "Showing saved history — connecting for live updates.",
                           symbol: "internaldrive", tint: FleetTheme.textSecondary)
                } else if let errorMessage = model.errorMessage {
                    banner(text: errorMessage, symbol: "exclamationmark.triangle", tint: FleetTheme.statusDegraded)
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
            // P2-8: key auto-scroll off the last row's identity, not the count —
            // the display window is capped, so count stops changing once full
            // while new rows keep arriving at the bottom.
            .onChange(of: model.transcript.last?.id) {
                if let last = model.transcript.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("fleet.conversation.transcript")
    }

    // MARK: Composer (U6 — surface bar, magenta circular send button)

    private func composer(_ model: ConversationViewModel) -> some View {
        HStack(spacing: FleetTheme.spacingSm) {
            TextField("Message", text: $composerText, axis: .vertical)
                .lineLimit(1...4)
                .font(.body)
                .foregroundStyle(FleetTheme.textPrimary)
                .tint(FleetTheme.accentMagenta)
                .padding(.horizontal, FleetTheme.spacingMd)
                .padding(.vertical, FleetTheme.spacingSm)
                .background(
                    RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                        .fill(FleetTheme.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                        .strokeBorder(FleetTheme.border, lineWidth: 1)
                )
                .disabled(model.phase != .ready && model.phase != .streaming)
                .accessibilityIdentifier("fleet.conversation.composer")
                .onSubmit {
                    Task { await submit(model) }
                }

            if model.phase == .streaming || model.isStreaming {
                Button {
                    Task { await model.interrupt() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: Self.sendButtonSide, height: Self.sendButtonSide)
                        .background(Circle().fill(FleetTheme.surfaceElevated))
                        .overlay(Circle().strokeBorder(FleetTheme.border, lineWidth: 1))
                }
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("fleet.conversation.stop")
            } else {
                Button {
                    Task { await submit(model) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: Self.sendButtonSide, height: Self.sendButtonSide)
                        .background(Circle().fill(FleetTheme.accentMagentaGradient))
                }
                .disabled(model.phase != .ready || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("fleet.conversation.send")
            }
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, FleetTheme.spacingSm)
        .background(FleetTheme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(FleetTheme.border)
                .frame(height: 1)
        }
    }

    /// Send/stop button side length (pt) — circular, per the hero mock.
    private static let sendButtonSide: CGFloat = 40

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
                    .foregroundStyle(FleetTheme.accentMagenta)
            }
        } description: {
            Text("This gateway has no conversation session wired.")
        }
        .accessibilityIdentifier("fleet.conversation.unavailable")
    }
}

/// P0-8: collapsible, dimmed reasoning block for assistant rows. The summary
/// header (chevron + "Reasoning") is always visible; the reasoning text is
/// expanded while its turn is streaming so live reasoning stays visible, and
/// collapsed by default for completed turns (it is auxiliary, not the reply).
private struct ReasoningDisclosure: View {
    let text: String
    let isStreaming: Bool

    init(text: String, isStreaming: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
    }

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FleetTheme.textSecondary)
                    Text("Reasoning")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FleetTheme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reasoning, \(expanded ? "expanded" : "collapsed")")
            .accessibilityHint("Double tap to \(expanded ? "collapse" : "expand") reasoning")
            .accessibilityIdentifier("fleet.conversation.reasoning.toggle")
            if expanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(FleetTheme.background, in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
        .onChange(of: isStreaming) { _, nowStreaming in
            // Keep live reasoning visible while the turn streams; auto-
            // collapse when the turn completes.
            expanded = nowStreaming
        }
        .onAppear {
            expanded = isStreaming
        }
    }
}

/// One transcript row (U6 Gold Fleet re-skin): user bubbles are right-aligned
/// magenta-gradient capsules; assistant replies are left-aligned surface
/// cards; timestamps render under each bubble (caption2 secondary) whenever
/// the row carries one.
private struct ConversationBubbleView: View {
    let row: ConversationRow

    var body: some View {
        HStack {
            if row.kind == .user { Spacer(minLength: 60) }
            VStack(alignment: row.kind == .user ? .trailing : .leading, spacing: FleetTheme.spacingXs) {
                bubbleContent
                    .frame(maxWidth: 420, alignment: row.kind == .user ? .trailing : .leading)
                if let timestampText {
                    Text(timestampText)
                        .font(.caption2)
                        .foregroundStyle(FleetTheme.textSecondary)
                }
            }
            if row.kind != .user { Spacer(minLength: 60) }
        }
        .accessibilityElement(children: .combine)
        // P2-7: expose speaker + content semantics and live turn state to
        // assistive tech — the combined bubble text alone hides who spoke.
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityIdentifier("fleet.conversation.row.\(row.id)")
    }

    /// U6: timestamp under the bubble — rendered only when the gateway
    /// stamped the row (persisted history); live unstamped rows omit it
    /// rather than fabricate a time.
    private var timestampText: String? {
        guard row.kind == .user || row.kind == .assistant,
              let timestamp = row.timestamp else { return nil }
        return FleetSessionDateText.text(timestamp)
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch row.kind {
        case .user:
            // U6: magenta-gradient capsule, right-aligned (hero mock screen 2).
            Text(row.text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    FleetTheme.accentMagentaGradient,
                    in: RoundedRectangle(cornerRadius: FleetTheme.radiusBubble)
                )
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                if let detail = row.detail, !detail.isEmpty {
                    // P0-8: reasoning renders as a DISTINCT collapsible,
                    // dimmed block — never merged into the assistant text.
                    ReasoningDisclosure(text: detail, isStreaming: row.isStreaming)
                }
                Text(row.text.isEmpty ? (row.isStreaming ? "…" : "") : row.text)
                    .font(.body)
                    .foregroundStyle(row.isFailed ? FleetTheme.statusDegraded : FleetTheme.textPrimary)
                    .textSelection(.enabled)
                if row.isStreaming {
                    // P2-7: decorative streaming dots — hidden from assistive
                    // tech (the row's accessibilityValue already announces
                    // "Streaming").
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(FleetTheme.accentMagenta)
                                .frame(width: 5, height: 5)
                                .opacity(0.6)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(FleetTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: FleetTheme.radiusBubble))
            .overlay(
                RoundedRectangle(cornerRadius: FleetTheme.radiusBubble)
                    .strokeBorder(FleetTheme.border, lineWidth: 1)
            )
        case .tool:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.text).font(.caption.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                    if let detail = row.detail, !detail.isEmpty {
                        Text(detail).font(.caption2).foregroundStyle(FleetTheme.textSecondary)
                    }
                }
            } icon: {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(FleetTheme.accent)
            }
            .padding(10)
            .background(FleetTheme.surface, in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
        case .status, .system:
            Text(row.text)
                .font(.caption)
                .foregroundStyle(FleetTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Label(row.text, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(FleetTheme.statusDegraded)
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
                conversationFactory: { gateway, _ in PreviewConversationSession(gatewayID: gateway.id) },
                health: PreviewHealthAccumulator()
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

/// H2 preview seam: inert health accumulator (no transport, no persistence).
private struct PreviewHealthAccumulator: ConnectionHealthAccumulating {
    func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
    func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
    func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
    func rehydrate(gatewayIDs: [GatewayID]) async {}
    func forget(gatewayID: GatewayID) async {}
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
    func resumeSession(sessionID: String, lastEventID: Int? = nil) async throws -> ConversationSession {
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
    func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] {
        [] // preview never gaps
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
