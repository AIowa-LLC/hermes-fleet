import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
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
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingTimeline = false
    @State private var followingLatest = true
    private let environment: AppEnvironment
    private let route: Route
    private let sessionID: String?

    /// D03 (design acceptance finding): a conversation opened through the
    /// canonical Bot Chat path must be TITLED exactly "Bot Chat" — the title
    /// is identity, not decoration. The profile context stays available in
    /// the row/detail trail; the raw slug title is kept only for non-
    /// canonical sessions.
    private var screenTitle: String {
        guard let sessionID else { return route.profileSlug.rawValue }
        return environment.isCanonicalBotChat(route: route, sessionID: sessionID)
            ? BotModeContract.canonicalChatTitle
            : route.profileSlug.rawValue
    }

    @State private var viewModel: ConversationViewModel?
    @State private var composerText = ""
    /// V4 motion: bumped on every composer submit so `.sensoryFeedback`
    /// fires the send haptic (trigger-based; not on initial appearance).
    @State private var sendPulse = 0
    /// R9-T2: model picker sheet presentation.
    @State private var showingModelPicker = false
    /// R9-T3: context breakdown sheet presentation.
    @State private var showingContextBreakdown = false
    /// R9-T4: fork navigation — the new session id to route to.
    @State private var forkTargetSessionID: String?
    /// R10-T1: composer attachment pickers.
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingFileImporter = false
    /// R10-T4: voice transcript review confirmation (sheet). Presented when a
    /// transcript lands for review (submit-on-silence OFF).
    @State private var showingTranscriptReview = false

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
        .navigationTitle(screenTitle)
        .task {
            if viewModel == nil {
                viewModel = environment.makeConversationViewModel(route: route, sessionID: sessionID)
            }
            await viewModel?.start()
            // R10-T1 demo hook (simulator only): `HERMES_FLEET_ATTACHMENT_PICK=1`
            // stages a fixture markdown file through the seam once the session
            // is open — the deterministic UI-test stand-in for the system
            // photo/document pickers (which cannot be driven deterministically
            // on the simulator).
            if ProcessInfo.processInfo.environment["HERMES_FLEET_ATTACHMENT_PICK"] == "1",
               viewModel?.pendingAttachments.isEmpty == true {
                let fixture = Data("# fixture notes\nR10-T1 scripted attachment.\n".utf8)
                await viewModel?.stageAttachment(
                    name: "notes.md",
                    mime: "text/markdown",
                    byteCount: fixture.count,
                    loadBytes: { fixture })
            }
        }
        .onDisappear {
            viewModel?.teardown()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sendPulse)
        .background(FleetTheme.background.ignoresSafeArea())
    }

    // MARK: Canvas

    private func canvas(_ model: ConversationViewModel) -> some View {
        VStack(spacing: 0) {
            botHeader(model)
            bannerArea(model)
            // R9-T4: transient tooling notices (fork/rename failures).
            if let toolingModel = model.toolingViewModel {
                ToolingNoticeBanner(model: toolingModel)
            }
            // R9-T1: the mid-session approval banner (danger surface) sits
            // above the transcript; nil model → nothing renders.
            if let approvalModel = model.approvalViewModel {
                ApprovalBanner(model: approvalModel) {
                    Task { await approvalModel.deny() }
                }
            }
            transcriptList(model)
            composer(model)
        }
        // R9-T2/T3/T4 sheets.
        .sheet(isPresented: $showingModelPicker) {
            if let toolingModel = model.toolingViewModel {
                ModelPickerSheet(model: toolingModel) { _ in
                    // The pick is sticky in the tooling VM; a NEW chat (next
                    // conversation open) rides it on session.create.
                }
            }
        }
        .sheet(isPresented: $showingContextBreakdown) {
            if let toolingModel = model.toolingViewModel {
                ContextBreakdownSheet(model: toolingModel)
            }
        }
        // R9-T4: navigate to a successfully forked session.
        .onChange(of: model.forkedSession?.sessionID) { _, newID in
            guard let newID, newID != forkTargetSessionID else { return }
            forkTargetSessionID = newID
            model.consumeForkedSession()
        }
        .navigationDestination(isPresented: forkNavigationBinding) {
            ConversationView(
                environment: environment,
                route: route,
                sessionID: forkTargetSessionID
            )
        }
    }

    /// Two-way binding for the fork push: entering pushes the forked
    /// conversation; popping clears the target so a SECOND fork can push
    /// again (same-session forks dedupe via forkTargetSessionID).
    private var forkNavigationBinding: Binding<Bool> {
        Binding(
            get: { forkTargetSessionID != nil },
            set: { shown in
                if !shown { forkTargetSessionID = nil }
            }
        )
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
        return VStack(spacing: 0) {
            HStack(spacing: FleetTheme.spacingMd) {
                BotAvatar(displayName: name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                        .lineLimit(1)
                    Text(model.sessionTitle ?? route.id)
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                // R9-T4: steer/rename/fork menu.
                if let toolingModel = model.toolingViewModel {
                    SessionSteerControls(
                        model: toolingModel,
                        isStreaming: model.isStreaming,
                        sessionTitle: model.sessionTitle
                    ) { forked in
                        // The fork result lands on the conversation VM
                        // (forkedSession) — navigated by the canvas binding.
                    }
                }
                // R9-T3: per-session YOLO toggle (session-scoped only, confirmed
                // on enable). Hidden when the session has no approvals seam.
                if let approvalModel = model.approvalViewModel {
                    SessionYoloToggle(model: approvalModel)
                }
                StatusPill(status: headerPillStatus(bot: bot, model: model))
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingSm)
            // R9-T2/T3: model chip + live context meter sub-row. The chip
            // shows the sticky pick (or the session's model readback); the
            // meter renders only with tooling (absent data → hidden).
            if model.toolingViewModel != nil {
                HStack(spacing: FleetTheme.spacingSm) {
                    Button {
                        showingModelPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "cpu")
                                .font(.caption2)
                                .foregroundStyle(FleetTheme.textSecondary)
                            Text(model.toolingViewModel?.selectedModel?.shortName
                                 ?? model.sessionModel?.split(separator: "·").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
                                 ?? "model")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(
                                    model.toolingViewModel?.selectedModel != nil
                                        ? FleetTheme.accent
                                        : FleetTheme.textSecondary
                                )
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(FleetTheme.background, in: Capsule())
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityLabel("Model picker")
                    .accessibilityValue(model.toolingViewModel?.selectedModel?.model ?? "profile default")
                    .accessibilityHint("Choose the model for new chats on this device")
                    .accessibilityIdentifier("model.chip")
                    Spacer()
                    if let toolingModel = model.toolingViewModel {
                        ContextMeterView(model: toolingModel) {
                            showingContextBreakdown = true
                        }
                    }
                }
                .padding(.horizontal, FleetTheme.spacingLg)
                .padding(.vertical, 6)
            }
        }
        .background(FleetTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast))
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
                    .tint(FleetTheme.accent)
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
                        ConversationBubbleView(row: row) { emoji in
                            Task { await model.react(rowID: row.rowID, kind: row.kind, emoji: emoji) }
                        } clear: {
                            Task { await model.clearReaction(rowID: row.rowID, kind: row.kind) }
                        }
                        .id(row.id)
                        // R10-T3: `@file:`/`@folder:` refs tap through into
                        // the Projects browser. Rendered OUTSIDE the bubble
                        // (the bubble combines its children for a11y — the
                        // R9-T6 lesson: .combine hides descendant buttons).
                        // D-2: rendered under USER rows only — the assistant
                        // bubble's raw @file: text is what wedged iOS 26 AX
                        // snapshots (see FleetSimulator D-2 fix note); the
                        // user row's own refs (the ones the sender attached)
                        // keep the tap-through affordance.
                        if row.kind == .user {
                            fileRefChips(row)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // V4 motion: gives the user-bubble entrance transition its
                // ease-out context. Keyed to the LAST ROW IDENTITY (not
                // count — the display window caps, P2-8) so it only fires
                // when rows actually arrive.
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.transcript.last?.id)
            }
            .accessibilityIdentifier("fleet.conversation.transcript")
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.transcript.contains(where: { $0.kind == .user }) {
                    HStack {
                        Button("Conversation timeline", systemImage: "list.bullet.indent") { showingTimeline = true }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("fleet.conversation.timeline.open")
                        Spacer()
                        if !followingLatest {
                            Button("Latest", systemImage: "arrow.down") {
                                followingLatest = true
                                if let last = model.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
                            }.accessibilityIdentifier("fleet.conversation.timeline.latest")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .background(FleetTheme.surface)
                }
            }
            .sheet(isPresented: $showingTimeline) {
                NavigationStack {
                    List {
                        Section("Loaded turns") {
                            ForEach(model.transcript.filter { $0.kind == .user }) { row in
                                Button {
                                    showingTimeline = false
                                    followingLatest = false
                                    if reduceMotion { proxy.scrollTo(row.id, anchor: .top) }
                                    else { withAnimation(.snappy) { proxy.scrollTo(row.id, anchor: .top) } }
                                } label: {
                                    Text(row.text).font(.body).lineLimit(3)
                                        .foregroundStyle(FleetTheme.textPrimary).padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .navigationTitle("Timeline").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingTimeline = false } } }
                }
                .presentationDetents([.medium, .large])
                .accessibilityIdentifier("fleet.conversation.timeline")
            }
            // P2-8: key auto-scroll off the last row's identity, not the count —
            // the display window is capped, so count stops changing once full
            // while new rows keep arriving at the bottom.
            .onChange(of: model.transcript.last?.id) {
                if followingLatest, let last = model.transcript.last {
                    if reduceMotion { proxy.scrollTo(last.id, anchor: .bottom) }
                    else { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Composer (V2 — surface bar, flat pale-cyan circular send button)

    /// R10-T3 — `@file:`/`@folder:` reference chips under a transcript
    /// row. Each chip deep-links into the Projects browser. The chips
    /// live OUTSIDE the combined bubble element (a11y discipline).
    @ViewBuilder
    private func fileRefChips(_ row: ConversationRow) -> some View {
        let refs = Self.fileRefs(in: row.text)
        if !refs.isEmpty {
            HStack(spacing: 6) {
                ForEach(refs, id: \.self) { ref in
                    fileRefChip(ref, row: row)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 420, alignment: row.kind == .user ? .trailing : .leading)
            .padding(.top, 2)
        }
    }

    /// One tap-through `@file:` chip under a user transcript row.
    @ViewBuilder
    private func fileRefChip(_ ref: FileRef, row: ConversationRow) -> some View {
        NavigationLink(value: FleetScreen.projects(route.gatewayID, focusPath: ref.displayPath)) {
            chipLabelBody(ref)
        }
        .buttonStyle(.fleetPressable)
        .accessibilityLabel("Browse \(ref.displayPath)")
        .accessibilityIdentifier("fleet.conversation.fileref.\(ref.index)")
    }

    /// The chip capsule label body.
    private func chipLabelBody(_ ref: FileRef) -> some View {
        Label(ref.displayPath, systemImage: "doc")
            .font(FleetTheme.monoCaptionFont)
            .foregroundStyle(FleetTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(FleetTheme.surfaceElevated, in: Capsule())
            .overlay(
                Capsule().strokeBorder(FleetTheme.accent.opacity(0.35), lineWidth: 1))
    }

    /// One `@file:` / `@folder:` reference found in message text.
    struct FileRef: Hashable {
        let ref: String
        let displayPath: String
        let index: Int
    }

    /// Extract `@file:` / `@folder:` refs from message text (the T1
    /// attachment vocabulary; `@url:`/`@git:` etc. are not paths).
    static func fileRefs(in text: String) -> [FileRef] {
        var results: [FileRef] = []
        var scanner = Substring(text)
        while let atRange = scanner.range(of: "@") {
            let tail = scanner[atRange.upperBound...]
            guard let colon = tail.firstIndex(of: ":") else { break }
            let kind = String(tail[..<colon])
            guard kind == "file" || kind == "folder" else {
                scanner = tail
                continue
            }
            let path = tail[tail.index(after: colon)...]
            let pathEnd = path.firstIndex(where: { $0.isWhitespace || $0 == ")" || $0 == "]" }) ?? path.endIndex
            let value = String(path[..<pathEnd])
            guard !value.isEmpty else {
                scanner = path
                continue
            }
            results.append(FileRef(ref: "@\(kind):\(value)", displayPath: value, index: results.count))
            scanner = path[pathEnd...]
        }
        return results
    }

    private func composer(_ model: ConversationViewModel) -> some View {
        VStack(spacing: 0) {
            // R10-T1: pending-attachment chips (name + size, removable) and
            // the never-silent error banner sit directly above the input row.
            if !model.pendingAttachments.isEmpty || model.isUploadingAttachment {
                attachmentTray(model)
            }
            if let attachmentError = model.attachmentError {
                attachmentErrorBanner(model, message: attachmentError)
            }
            // R10-T2: reaction error banner — never silent.
            if let reactionError = model.reactionError {
                reactionErrorBanner(model, message: reactionError)
            }
            // R10-T4: voice banners — honest authorization-denied gate +
            // never-silent capture/synthesis failure.
            if model.isVoiceDenied {
                voiceDeniedBanner(model)
            }
            if let voiceError = model.voiceError {
                voiceErrorBanner(model, message: voiceError)
            }
            // R10-T4: transcript review chip — the recognized text lands for
            // review before any submit (review-first; never auto-sent unless
            // the user opted into submit-on-silence).
            if let transcript = model.latestVoiceTranscript,
               !model.isListening {
                transcriptReviewChip(model, transcript: transcript)
            }
            HStack(spacing: FleetTheme.spacingSm) {
                // R10-T1: "+" affordance — Photos picker (images) + Files
                // importer (PDF/any). Hidden while a turn streams (the
                // gateway queues attaches for the NEXT submit; allowing
                // mid-stream picks invites orphaned uploads).
                if model.phase == .ready {
                    Menu {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Photo…", systemImage: "photo")
                        }
                        Button {
                            showingFileImporter = true
                        } label: {
                            Label("File or PDF…", systemImage: "doc")
                        }
                        let previousPrompts = model.transcript.filter { $0.kind == .user && !$0.text.isEmpty }.suffix(10)
                        if !previousPrompts.isEmpty {
                            Menu("Reuse a prompt", systemImage: "clock.arrow.circlepath") {
                                ForEach(previousPrompts.reversed()) { row in
                                    Button(String(row.text.prefix(80))) { composerText = row.text }
                                }
                            }
                        }
                        // R10-T4: voice-mode toggle rides the "+" menu. ON =
                        // assistant replies spoken via local TTS; turning
                        // OFF cuts speech immediately.
                        Button {
                            Task { await model.setVoiceMode(!model.isVoiceModeEnabled) }
                        } label: {
                            Label(
                                model.isVoiceModeEnabled ? "Speak Replies: On" : "Speak Replies: Off",
                                systemImage: model.isVoiceModeEnabled ? "speaker.wave.2.fill" : "speaker.wave.2"
                            )
                        }
                        .accessibilityIdentifier("fleet.conversation.voiceMode.toggle")
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(FleetTheme.accent)
                            .frame(width: Self.sendButtonSide, height: Self.sendButtonSide)
                            .background(Circle().fill(FleetTheme.surfaceElevated))
                            .overlay(Circle().strokeBorder(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast), lineWidth: 1))
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityLabel("Attach")
                    .accessibilityIdentifier("fleet.conversation.attach")
                }

                // R10-T4: mic button — on-device transcription (Speech
                // framework) into the composer. Hidden entirely when no
                // voice engine is wired (fail-closed). While listening, the
                // button becomes a stop control (best-partial capture).
                if model.isVoiceAvailable {
                    Button {
                        Task { await model.toggleMic() }
                    } label: {
                        Image(systemName: model.isListening ? "stop.circle.fill" : "mic.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(model.isListening ? AnyShapeStyle(FleetTheme.statusDegraded) : AnyShapeStyle(FleetTheme.accent))
                            .frame(width: Self.sendButtonSide, height: Self.sendButtonSide)
                            .background(Circle().fill(FleetTheme.surfaceElevated))
                            .overlay(Circle().strokeBorder(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast), lineWidth: 1))
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityLabel(model.isListening ? "Stop Listening" : "Transcribe Voice")
                    .accessibilityIdentifier("fleet.conversation.mic")
                }

                TextField("Message", text: $composerText, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.body)
                    .foregroundStyle(FleetTheme.textPrimary)
                    .tint(FleetTheme.accent)
                    .padding(.horizontal, FleetTheme.spacingMd)
                    .padding(.vertical, FleetTheme.spacingSm)
                    .background(
                        RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                            .fill(FleetTheme.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                            .strokeBorder(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast), lineWidth: 1)
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
                            .foregroundStyle(FleetTheme.textPrimary)
                            .frame(width: Self.sendButtonSide, height: Self.sendButtonSide)
                            .background(Circle().fill(FleetTheme.surfaceElevated))
                            .overlay(Circle().strokeBorder(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast), lineWidth: 1))
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("fleet.conversation.stop")
                } else {
                    Button {
                        Task { await submit(model) }
                    } label: {
                        // V2 (Nous Direction A): FLAT pale-cyan circle, dark
                        // glyph — the one accent, no glow, no gradient.
                        Image(systemName: "arrow.up")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(FleetTheme.background)
                            .frame(width: Self.sendButtonSide, height: Self.sendButtonSide)
                            .background(Circle().fill(FleetTheme.accent))
                    }
                    .buttonStyle(.fleetPressable)
                    .disabled(model.phase != .ready || (composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty))
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("fleet.conversation.send")
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingSm)
        }
        .background(FleetTheme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast))
                .frame(height: 1)
        }
        // R10-T1: pickers.
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            Task { await loadPickedPhoto(item, model: model) }
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.pdf, .item]) { result in
            guard case .success(let url) = result else {
                // User-cancelled picker: not an error.
                return
            }
            Task { await loadPickedFile(url, model: model) }
        }
    }

    // MARK: R10-T1 — attachment tray + pickers

    /// Pending-attachment chips: name + human-readable size, removable with
    /// the X button; a spinner chip while an upload is in flight.
    private func attachmentTray(_ model: ConversationViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FleetTheme.spacingSm) {
                if model.isUploadingAttachment {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Uploading…")
                            .font(.caption)
                            .foregroundStyle(FleetTheme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                            .fill(FleetTheme.surfaceElevated))
                    .accessibilityIdentifier("fleet.conversation.attachment.uploading")
                }
                ForEach(model.pendingAttachments) { chip in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(FleetTheme.accent)
                        Text(chip.caption)
                            .font(.caption)
                            .foregroundStyle(FleetTheme.textPrimary)
                            .lineLimit(1)
                        Button {
                            model.removePendingAttachment(chip.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(FleetTheme.textSecondary)
                        }
                        .accessibilityLabel("Remove attachment \(chip.displayName)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                            .fill(FleetTheme.surfaceElevated))
                    .overlay(
                        RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                            .strokeBorder(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast), lineWidth: 1))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("fleet.conversation.attachment.chip.\(chip.displayName)")
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.top, FleetTheme.spacingSm)
        }
    }

    /// Composer attachment error banner — never silent (R10-T1 mandate).
    private func attachmentErrorBanner(_ model: ConversationViewModel, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(FleetTheme.statusDegraded)
            Text(message)
                .font(.caption)
                .foregroundStyle(FleetTheme.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                model.clearAttachmentError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(FleetTheme.textSecondary)
            }
            .accessibilityLabel("Dismiss attachment error")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(FleetTheme.surfaceElevated)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.attachment.error")
    }

    /// R10-T2: reaction error banner — never silent (same mandate).
    private func reactionErrorBanner(_ model: ConversationViewModel, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(FleetTheme.statusDegraded)
            Text(message)
                .font(.caption)
                .foregroundStyle(FleetTheme.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                model.clearReactionError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(FleetTheme.textSecondary)
            }
            .accessibilityLabel("Dismiss reaction error")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(FleetTheme.surfaceElevated)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.reaction.error")
    }

    // MARK: R10-T4 — voice banners + transcript review chip

    /// Honest authorization-denied gate: mic/speech permission refused — the
    /// ONLY action offered is opening Settings (never a fake retry).
    private func voiceDeniedBanner(_ model: ConversationViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash")
                .foregroundStyle(FleetTheme.statusDegraded)
            Text("Voice needs microphone + speech recognition access. Enable them in Settings to transcribe.")
                .font(.caption)
                .foregroundStyle(FleetTheme.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Settings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FleetTheme.accent)
            }
            .accessibilityIdentifier("fleet.conversation.voice.denied.settings")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(FleetTheme.surfaceElevated)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.voice.denied")
    }

    /// Never-silent voice failure banner (capture/synthesis errors).
    private func voiceErrorBanner(_ model: ConversationViewModel, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(FleetTheme.statusDegraded)
            Text(message)
                .font(.caption)
                .foregroundStyle(FleetTheme.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                model.clearVoiceError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(FleetTheme.textSecondary)
            }
            .accessibilityLabel("Dismiss voice error")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(FleetTheme.surfaceElevated)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.voice.error")
    }

    /// Transcript review chip: the recognized text lands above the composer
    /// for review. "Use" drops it into the composer field for editing;
    /// "Send" submits it as-is; "Discard" clears it. A partial (manual-stop)
    /// transcript is labeled honestly.
    private func transcriptReviewChip(_ model: ConversationViewModel, transcript: VoiceTranscript) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(FleetTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.text)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.textPrimary)
                    .lineLimit(3)
                if !transcript.isFinal {
                    Text("Partial — stopped early. Edit before sending.")
                        .font(.caption2)
                        .foregroundStyle(FleetTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                composerText = transcript.text
                model.discardTranscript()
            } label: {
                Text("Use")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FleetTheme.accent)
            }
            .accessibilityIdentifier("fleet.conversation.voice.transcript.use")
            Button {
                Task {
                    model.discardTranscript()
                    await model.send(transcript.text)
                }
            } label: {
                Text("Send")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FleetTheme.accent)
            }
            .accessibilityIdentifier("fleet.conversation.voice.transcript.send")
            Button {
                model.discardTranscript()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(FleetTheme.textSecondary)
            }
            .accessibilityLabel("Discard transcript")
            .accessibilityIdentifier("fleet.conversation.voice.transcript.discard")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(FleetTheme.surfaceElevated)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.conversation.voice.transcript")
    }

    /// Load picked photo bytes (the gateway image allowlist: PNG/JPEG/GIF/
    /// WebP/BMP) and stage them. HEIC/other camera formats convert to JPEG
    /// via ImageIO first (the vision pipeline can't read them, cli.py:3954);
    /// unconvertible data fails honestly pre-upload.
    private func loadPickedPhoto(_ item: PhotosPickerItem, model: ConversationViewModel) async {
        let data: Data
        do {
            guard let loaded = try await item.loadTransferable(type: Data.self), !loaded.isEmpty else {
                return // user-cancelled / empty pick — not an error
            }
            data = loaded
        } catch {
            await model.stageAttachment(
                name: "photo.bin", mime: nil, byteCount: 0,
                loadBytes: { throw error })
            return
        }
        if let ext = AttachmentStagingRules.sniffedImageExtension(bytes: data) {
            let stamp = Int(Date.now.timeIntervalSince1970)
            await model.stageAttachment(
                name: "photo_\(stamp).\(ext)",
                mime: nil,
                byteCount: data.count,
                loadBytes: { data })
        } else if let jpeg = Self.cameraDataAsJPEG(data) {
            let stamp = Int(Date.now.timeIntervalSince1970)
            await model.stageAttachment(
                name: "photo_\(stamp).jpg",
                mime: nil,
                byteCount: jpeg.count,
                loadBytes: { jpeg })
        } else {
            await model.stageAttachment(
                name: "photo.unsupported", mime: nil, byteCount: data.count,
                loadBytes: { throw AttachmentStagingError.unsupportedImageFormat(name: "photo") })
        }
    }

    /// HEIC/RAW → JPEG via ImageIO (device photos default to HEIC; the
    /// gateway's image pipeline accepts PNG/JPEG/GIF/WebP/BMP only).
    private static func cameraDataAsJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Load a picked file URL (PDF or any type) via security-scoped access.
    private func loadPickedFile(_ url: URL, model: ConversationViewModel) async {
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        do {
            // Pre-upload guard on the real size before reading the bytes.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            await model.stageAttachment(
                name: name,
                mime: mime,
                byteCount: size,
                loadBytes: { try Data(contentsOf: url) })
        } catch {
            await model.stageAttachment(
                name: name, mime: mime, byteCount: 0,
                loadBytes: { throw error })
        }
    }

    /// Send/stop button side length (pt) — circular, per the hero mock.
    private static let sendButtonSide: CGFloat = 44

    private func submit(_ model: ConversationViewModel) async {
        guard model.phase == .ready,
              !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pendingAttachments.isEmpty else { return }
        followingLatest = true
        let text = composerText
        composerText = ""
        sendPulse += 1
        await model.send(text)
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label {
                Text("Conversation Unavailable")
            } icon: {
                Image(systemName: "text.bubble")
                    .foregroundStyle(FleetTheme.textSecondary)
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
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let row: ConversationRow
    /// R10-T2: reaction handlers from the owning view (the bubble owns no
    /// model reference).
    var react: (String) -> Void = { _ in }
    var clear: () -> Void = {}

    /// V4 motion budget: subtle entrance for user bubbles — opacity + a
    /// 0.97 scale settle, ease-out 0.18s. Under Reduce Motion the scale is
    /// dropped (plain opacity cross-fade). Assistant rows stream in text
    /// (their content animates already) — no extra entrance.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var entrance: AnyTransition {
        if reduceMotion {
            AnyTransition.opacity
        } else {
            AnyTransition.opacity.combined(with: .scale(scale: 0.97))
        }
    }

    var body: some View {
        HStack {
            if row.kind == .user { Spacer(minLength: 60) }
            VStack(alignment: row.kind == .user ? .trailing : .leading, spacing: FleetTheme.spacingXs) {
                bubbleContent
                    .frame(maxWidth: 420, alignment: row.kind == .user ? .trailing : .leading)
                if let reactions = row.reactions, !reactions.isEmpty {
                    reactionChips(reactions)
                }
                if let timestampText {
                    // V3: timestamps are telemetry — mono caption.
                    Text(timestampText)
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                }
            }
            if row.kind != .user { Spacer(minLength: 60) }
        }
        .transition(row.kind == .user ? entrance : .identity)
        // R10-T2: long-press Tapback menu — small palette + Clear. Only
        // user/assistant rows are reactable (tool/status/system rows are
        // not addressable on the wire).
        .contextMenu { reactionMenu }
        .accessibilityElement(children: row.kind == .tool ? .contain : .combine)
        // P2-7: expose speaker + content semantics and live turn state to
        // assistive tech — the combined bubble text alone hides who spoke.
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityIdentifier("fleet.conversation.row.\(row.id)")
    }

    /// R10-T2: the long-press context menu (palette + Clear reaction).
    @ViewBuilder
    private var reactionMenu: some View {
        if row.kind == .user || row.kind == .assistant {
            ForEach(MessageReactionPalette.standard.emojis, id: \.self) { emoji in
                Button {
                    react(emoji)
                } label: {
                    Text(emoji)
                }
                .accessibilityLabel("React \(emoji)")
                .accessibilityIdentifier("fleet.conversation.reaction.palette.\(emoji)")
            }
            if row.reactions?.contains(where: { $0.author == "user" }) == true {
                Button(role: .destructive) {
                    clear()
                } label: {
                    Label("Clear Reaction", systemImage: "xmark.circle")
                }
                .accessibilityIdentifier("fleet.conversation.reaction.clear")
            }
        }
    }

    /// R10-T2: reactions rendered under the bubble — one chip per author
    /// (the per-author single-reaction semantics), own emoji emphasized.
    private func reactionChips(_ reactions: [MessageReaction]) -> some View {
        HStack(spacing: 4) {
            ForEach(reactions) { reaction in
                Text(reaction.emoji)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        FleetTheme.surfaceElevated,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            reaction.author == "user"
                                ? FleetTheme.accent.opacity(0.5)
                                : FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast),
                            lineWidth: 1)
                    )
                    .accessibilityLabel(
                        reaction.author == "user"
                            ? "Your reaction \(reaction.emoji)"
                            : "Reaction \(reaction.emoji)")
                    .accessibilityIdentifier("fleet.conversation.reaction.chip.\(reaction.emoji)")
            }
        }
        .accessibilityElement(children: .contain)
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
            // V3 (Nous Direction A): FLAT elevated-surface capsule with the
            // pale-cyan accent text — right-aligned, hairline-bordered, no
            // gradient (accent discipline: one pale-cyan accent).
            Text(row.text)
                .font(.body)
                .foregroundStyle(FleetTheme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    FleetTheme.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: FleetTheme.radiusBubble)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FleetTheme.radiusBubble)
                        .strokeBorder(FleetTheme.accent.opacity(0.35), lineWidth: 1)
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
                                .fill(FleetTheme.accent)
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
                    .strokeBorder(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast), lineWidth: 1)
            )
        case .tool:
            FleetToolActivityView(title: row.text, detail: row.detail)
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
                gatewayID: GatewayID(rawValue: "workstation"),
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
