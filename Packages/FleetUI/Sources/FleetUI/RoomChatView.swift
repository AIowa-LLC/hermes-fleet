import SwiftUI
import Observation
import FleetCore

/// TRUE BOTS MODE slice 4 (D15/D16/D18) — observable state for one room's
/// interactive chat screen.
///
/// Rules enforced here (not in view code):
/// - Generation-agnostic: the VM reads `FleetRoom.capabilities` /
///   `isManagedByDesktop` and NEVER branches on provenance itself — hosted
///   and legacy rooms take the same code path; capabilities are the truth.
/// - Capability-disabled mutations NEVER issue writes: every command checks
///   its capability first and records an honest disabledExplanation instead.
/// - Replay-first: on start, the durable cache projects what it holds and a
///   `groups.log` replay (since cursor) refreshes it — the transcript
///   survives navigation/reconnect through the provider (gateway owns the
///   durable log; the VM only merges pages).
/// - D16: stop/retry/approve ride the command seam when capable; retryable +
///   indeterminate failure states come from the typed-failure projection.
@MainActor
@Observable
public final class RoomChatViewModel {

    // MARK: Observable state

    /// Merged durable-log projection (transcript rows).
    public private(set) var transcript: [RoomTranscriptEntry] = []
    /// Latest typed failure (retryable-failure surface).
    public private(set) var latestFailure: TypedBotFailure?
    /// Honest indeterminate task (outcome unknown).
    public private(set) var indeterminateTaskID: String?
    public private(set) var isLoading = false
    public private(set) var isSending = false
    /// True while a mutation (rename/disband/stop/retry/approve) is in flight.
    public private(set) var isMutating = false
    public private(set) var errorMessage: String?
    /// Honest informational notice (non-error outcomes).
    public private(set) var notice: String?
    /// Room-level D16 attention state from driver status.
    public private(set) var driverWorking = false
    public private(set) var driverBlocked = false
    public private(set) var pendingApprovals: [RoomPendingApproval] = []
    public private(set) var pendingRetries: [RoomPendingRetry] = []
    /// Room was disbanded through this screen (navigable-away tombstone).
    public private(set) var isDisbanded = false
    public private(set) var roomName: String

    // MARK: Test observability

    /// Count of writes ATTEMPTED through the command seam (tests assert this
    /// stays 0 when capabilities are disabled).
    public private(set) var attemptedWriteCount = 0
    /// Explanation recorded when a mutation was blocked by capabilities.
    public private(set) var disabledExplanation: String?

    // MARK: Dependencies

    public let room: FleetRoom
    private let commands: (any RoomChatCommanding)?
    private let driverStatus: (any RoomDriverStatusProviding)?
    private var cache = RoomTranscriptCache()

    public init(
        room: FleetRoom,
        commands: (any RoomChatCommanding)? = nil,
        driverStatus: (any RoomDriverStatusProviding)? = nil
    ) {
        self.room = room
        self.commands = commands
        self.driverStatus = driverStatus
        self.roomName = room.name
        self.isDisbanded = room.id.provenance == .hosted && room.hosted?.disbandedAt != nil
    }

    /// Capabilities for this room (hosted: advertised methods; legacy:
    /// observational-only). Views render affordances from THIS.
    public var capabilities: RoomCapabilities { room.capabilities }

    public var isManagedByDesktop: Bool { room.isManagedByDesktop }

    /// Member rows, source-qualified (gateway label rides alongside —
    /// cross-machine identity never collapses).
    public func memberRows(gatewayLabel: String) -> [(member: FleetRoomMember, source: String)] {
        room.members.map { ($0, RoomMemberDisplay.sourceQualifier(for: $0, gatewayLabel: gatewayLabel)) }
    }

    // MARK: Lifecycle

    public func start() async {
        await refresh()
    }

    /// Replay the durable log since the merged cursor + refresh driver
    /// status. The cache projection renders FIRST so re-entry shows the
    /// surviving transcript immediately.
    public func refresh() async {
        errorMessage = nil
        if !capabilities.canReplay {
            // Honest: no replay path (legacy projection already carries its
            // bounded window in room.recentLog — project it once).
            if transcript.isEmpty {
                let projection = Self.projectLegacyWindow(room.recentLog)
                transcript = projection.entries
                latestFailure = projection.latestFailure
            }
            await loadDriverStatus()
            return
        }
        guard let commands else {
            disabledExplanation = "No room connection is available on this gateway."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await commands.replay(
                roomID: room.id.key, sinceSeq: cache.nextSinceSeq, limit: 100)
            cache.merge(page)
            applyProjection()
        } catch {
            errorMessage = Self.explain(error)
        }
        await loadDriverStatus()
    }

    private func applyProjection() {
        let projection = RoomTranscriptProjection.project(cache.orderedEvents)
        transcript = projection.entries
        latestFailure = projection.latestFailure
        indeterminateTaskID = projection.indeterminateTaskID
    }

    private func loadDriverStatus() async {
        guard let driverStatus, capabilities.canStop || capabilities.canRetry || capabilities.canApprove else {
            return
        }
        if let status = try? await driverStatus.driverStatus(roomID: room.id.key) {
            driverWorking = status.working
            driverBlocked = status.blocked
            pendingApprovals = status.pendingApprovals
            pendingRetries = status.pendingRetries
        }
    }

    // MARK: - D15 mutations (capability-gated; disabled never writes)

    /// Send a chat message. Returns true when a write was issued.
    @discardableResult
    public func send(_ rawText: String) async -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard capabilities.canSend else {
            disabledExplanation = isManagedByDesktop
                ? "Managed by Hermes Desktop — read only."
                : "This gateway doesn't support sending in this room."
            return false
        }
        guard let commands else {
            disabledExplanation = "No room connection is available on this gateway."
            return false
        }
        isSending = true
        defer { isSending = false }
        attemptedWriteCount += 1
        do {
            // Upstream `groups.send` requires the exact user payload
            // {text, thread_id} (hosted_room_discussion.py
            // _USER_PAYLOAD_FIELDS). A nil thread id is REJECTED on the live
            // wire — the room's main thread id is stable per room.
            _ = try await commands.send(
                roomID: room.id.key, text: text,
                threadID: Self.mainThreadID(for: room.id.key))
            errorMessage = nil
            await refresh()
            return true
        } catch {
            errorMessage = Self.explain(error)
            return false
        }
    }

    /// Deterministic main-thread id for one room (upstream identifier
    /// charset; stable across sessions so events land on one thread).
    static func mainThreadID(for roomKey: String) -> String {
        "room-" + MentionResolution.slugify(roomKey.lowercased()) + "-main"
    }

    @discardableResult
    public func rename(_ rawName: String) async -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        guard capabilities.canRename else {
            disabledExplanation = isManagedByDesktop
                ? "Managed by Hermes Desktop — read only."
                : "This gateway doesn't support renaming this room."
            return false
        }
        guard let commands else { return false }
        isMutating = true
        defer { isMutating = false }
        attemptedWriteCount += 1
        do {
            try await commands.rename(roomID: room.id.key, name: name)
            roomName = name
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.explain(error)
            return false
        }
    }

    @discardableResult
    public func disband() async -> Bool {
        guard capabilities.canDisband else {
            disabledExplanation = "This room can't be disbanded from Fleet."
            return false
        }
        guard let commands else { return false }
        isMutating = true
        defer { isMutating = false }
        attemptedWriteCount += 1
        do {
            try await commands.disband(roomID: room.id.key)
            isDisbanded = true
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.explain(error)
            return false
        }
    }

    // MARK: - D16 controls

    @discardableResult
    public func stopWorking() async -> Bool {
        guard capabilities.canStop else {
            disabledExplanation = "Stopping work isn't available for this room."
            return false
        }
        guard let commands else { return false }
        isMutating = true
        defer { isMutating = false }
        attemptedWriteCount += 1
        do {
            let cancelled = try await commands.stop(roomID: room.id.key)
            notice = cancelled > 0
                ? "Stopped \(cancelled) running task\(cancelled == 1 ? "" : "s")."
                : "No running tasks to stop."
            errorMessage = nil
            await refresh()
            return true
        } catch {
            errorMessage = Self.explain(error)
            return false
        }
    }

    @discardableResult
    public func retry(taskID: String) async -> Bool {
        guard capabilities.canRetry else {
            disabledExplanation = "Retrying isn't available for this room."
            return false
        }
        guard let commands else { return false }
        isMutating = true
        defer { isMutating = false }
        attemptedWriteCount += 1
        do {
            try await commands.retry(roomID: room.id.key, taskID: taskID)
            notice = "Retrying task \(taskID)."
            errorMessage = nil
            await refresh()
            return true
        } catch {
            errorMessage = Self.explain(error)
            return false
        }
    }

    /// Approve (choice "once" | "deny") a needs-you approval.
    @discardableResult
    public func approve(_ action: RoomPendingApproval, choice: String) async -> Bool {
        guard capabilities.canApprove else {
            disabledExplanation = "Approvals aren't available for this room."
            return false
        }
        guard let commands else { return false }
        isMutating = true
        defer { isMutating = false }
        attemptedWriteCount += 1
        do {
            try await commands.approve(roomID: room.id.key, action: action, choice: choice)
            notice = choice == "deny" ? "Denied." : "Approved."
            errorMessage = nil
            await refresh()
            return true
        } catch {
            errorMessage = Self.explain(error)
            return false
        }
    }

    /// Retry affordance for the projection's latest typed failure.
    public var canRetryLatestFailure: Bool {
        capabilities.canRetry && latestFailure != nil
    }

    // MARK: - Errors

    static func explain(_ error: Error) -> String {
        if let failure = error as? RoomCommandFailure {
            return failure.explanation
        }
        return error.localizedDescription
    }

    /// Project a legacy room's bounded recentLog window (display-only).
    static func projectLegacyWindow(_ log: [FleetRoomMessage]) -> RoomTranscriptProjection {
        let events = log.map { message in
            HostedRoomEventValue(
                roomID: "", seq: 0, eventID: message.id,
                kind: message.from.kind == .user ? "message.user" : "message.member",
                actorKind: message.from.kind == .user ? "user" : "member",
                actorID: message.from.name, actorProfile: message.from.name,
                payloadText: message.text, createdAt: message.at / 1000)
        }
        return RoomTranscriptProjection.project(events)
    }
}

// MARK: - Screen

/// One room, generation-agnostic: hosted rooms render interactive (per
/// capabilities), legacy rooms render observational with the "Managed by
/// Hermes Desktop" label. Fleet visual language: dark cards, bold headers,
/// mono metadata — no generic grouped Forms.
public struct RoomChatView: View {
    @State private var viewModel: RoomChatViewModel
    private let environment: AppEnvironment
    @State private var draft = ""
    @State private var showingRename = false
    @State private var renameDraft = ""
    @State private var showingDisbandConfirm = false
    @State private var showingRoomLink = false
    @FocusState private var composing: Bool

    public init(room: FleetRoom, environment: AppEnvironment) {
        self.environment = environment
        _viewModel = State(initialValue: environment.makeRoomChatViewModel(room: room))
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    header
                    if viewModel.isDisbanded {
                        disbandedBanner
                    }
                    if viewModel.isManagedByDesktop {
                        managedByDesktopBanner
                    }
                    failureSurfaces
                    approvalSurfaces
                    transcriptRows
                    if viewModel.transcript.isEmpty && !viewModel.isLoading {
                        emptyTranscript
                    }
                }
                .padding(.horizontal, FleetTheme.spacingLg)
                .padding(.vertical, FleetTheme.spacingMd)
            }
            .overlay(alignment: .bottom) { composer }
            .background(FleetTheme.background.ignoresSafeArea())
            .navigationTitle(viewModel.roomName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarControls }
            .task { await viewModel.start() }
            .refreshable { await viewModel.refresh() }
            .sheet(isPresented: $showingRename) { renameSheet }
            .sheet(isPresented: $showingRoomLink) {
                NavigationStack {
                    RoomLinkView(room: viewModel.room, environment: environment)
                }
            }
            .alert("Disband this room?", isPresented: $showingDisbandConfirm) {
                Button("Disband", role: .destructive) {
                    Task { await viewModel.disband() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The gateway tombstones the room permanently. This can't be undone.")
            }
            .onChange(of: viewModel.transcript.count) { _, _ in
                if let last = viewModel.transcript.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .accessibilityIdentifier("fleet.room.chat")
    }

    // MARK: Header (member strip, D18)

    private var header: some View {
        let label = environment.gateway(for: viewModel.room.id.gatewayID)?.displayName
            ?? viewModel.room.id.gatewayID.rawValue
        return VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            HStack(spacing: 6) {
                Image(systemName: viewModel.isManagedByDesktop ? "lock.fill" : "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(viewModel.isManagedByDesktop ? FleetTheme.textSecondary : FleetTheme.accent)
                Text(viewModel.roomName)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(FleetTheme.textPrimary)
                if viewModel.driverWorking {
                    StatusPill(status: FleetStatus(activity: .working, presence: .reachable))
                }
            }
            // Source-qualified member chips: gateway label always present so
            // cross-machine members never collapse.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FleetTheme.spacingXs) {
                    ForEach(viewModel.memberRows(gatewayLabel: label), id: \.member.name) { row in
                        HStack(spacing: 4) {
                            Text(row.member.name)
                                .font(.caption.weight(.semibold))
                            Text(row.source)
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(FleetTheme.textSecondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(FleetTheme.surfaceElevated))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("fleet.room.member.\(row.member.name)")
                    }
                }
            }
        }
        .padding(.bottom, FleetTheme.spacingXs)
    }

    private var managedByDesktopBanner: some View {
        FleetCard {
            Label(
                "Managed by Hermes Desktop — read only. Fields update when Desktop syncs.",
                systemImage: "lock.fill")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.textSecondary)
        }
        .accessibilityIdentifier("fleet.room.legacy.banner")
    }

    private var disbandedBanner: some View {
        FleetCard {
            Label("This room was disbanded. Its log is preserved until the gateway prunes it.", systemImage: "trash")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.textSecondary)
        }
        .accessibilityIdentifier("fleet.room.disbanded.banner")
    }

    // MARK: D16 failure / attention surfaces

    @ViewBuilder
    private var failureSurfaces: some View {
        if let failure = viewModel.latestFailure {
            let surface = BotFailureCopy.Surface(failure.reason)
            FleetCard {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                    Label(
                        surface.requiresAttention ? "Needs attention — \(surface.title)" : surface.title,
                        systemImage: surface.requiresAttention ? "exclamationmark.triangle.fill" : "xmark.octagon")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                    Text(failure.message ?? surface.message)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                    // D22: the wire spelling rides along (mono badge) —
                    // honest typed identity, never a generic "failed".
                    Text(surface.wireBadge)
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .accessibilityIdentifier("fleet.room.failure.wire-badge")
                    HStack(spacing: FleetTheme.spacingSm) {
                        ForEach(surface.actions) { action in
                            Button {
                                Task { await perform(action) }
                            } label: {
                                Label(action.title, systemImage: action.symbol)
                            }
                            .buttonStyle(.fleetPressable)
                            .accessibilityIdentifier("fleet.room.failure.action.\(action.id)")
                        }
                        if viewModel.capabilities.canStop {
                            Button(role: .destructive) {
                                Task { await viewModel.stopWorking() }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .buttonStyle(.fleetPressable)
                            .accessibilityIdentifier("fleet.room.stop")
                        }
                    }
                }
            }
            // (card identifier intentionally absent — a card-level identifier
            // overrides every child identifier in the AX tree; the D22
            // action buttons must keep their own.)
        } else if let taskID = viewModel.indeterminateTaskID, viewModel.capabilities.canRetry {
            FleetCard {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                    Label("Outcome unknown", systemImage: "questionmark.diamond")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                    Text("Task \(taskID) ended without a settled result.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                    Button {
                        Task { await viewModel.retry(taskID: taskID) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityIdentifier("fleet.room.retry-indeterminate")
                }
            }
        } else if viewModel.driverWorking && viewModel.capabilities.canStop {
            FleetCard {
                HStack {
                    Label("Working…", systemImage: "gearshape.2")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                    Spacer()
                    Button(role: .destructive) {
                        Task { await viewModel.stopWorking() }
                    } label: {
                        Text("Stop")
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityIdentifier("fleet.room.stop")
                }
            }
        }
        if let explanation = viewModel.disabledExplanation {
            Text(explanation)
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(FleetTheme.statusDegraded)
                .accessibilityIdentifier("fleet.room.disabled-explanation")
        }
        if let error = viewModel.errorMessage {
            Text(error)
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.statusDegraded)
                .accessibilityIdentifier("fleet.room.error")
        }
        if let notice = viewModel.notice {
            Text(notice)
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.textSecondary)
                .accessibilityIdentifier("fleet.room.notice")
        }
    }

    /// Needs-you approvals surface (driver pending_actions).
    @ViewBuilder
    private var approvalSurfaces: some View {
        ForEach(viewModel.pendingApprovals) { approval in
            FleetCard {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                    Label("Needs you", systemImage: "hand.raised.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FleetTheme.accent)
                    if let prompt = approval.approval["prompt"]?.stringValue ?? approval.approval["summary"]?.stringValue, !prompt.isEmpty {
                        Text(prompt)
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(FleetTheme.textPrimary)
                    }
                    HStack(spacing: FleetTheme.spacingSm) {
                        Button {
                            Task { await viewModel.approve(approval, choice: "once") }
                        } label: {
                            Label("Approve once", systemImage: "checkmark")
                        }
                        .buttonStyle(.fleetPressable)
                        .accessibilityIdentifier("fleet.room.approve.once")
                        Button(role: .destructive) {
                            Task { await viewModel.approve(approval, choice: "deny") }
                        } label: {
                            Label("Deny", systemImage: "xmark")
                        }
                        .buttonStyle(.fleetPressable)
                        .accessibilityIdentifier("fleet.room.approve.deny")
                    }
                }
            }
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcriptRows: some View {
        ForEach(viewModel.transcript) { entry in
            FleetCard {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.speaker)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(entry.flavor == .message(isUser: true) ? FleetTheme.accent : FleetTheme.textSecondary)
                        Text(BotRowView.relativeTime(entry.createdAt))
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                    }
                    switch entry.flavor {
                    case .message:
                        Text(entry.text ?? "")
                            .font(.body)
                            .foregroundStyle(FleetTheme.textPrimary)
                    case .failure:
                        Label(entry.text ?? "Turn failed", systemImage: "xmark.octagon")
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(FleetTheme.statusDegraded)
                    }
                }
            }
            .id(entry.id)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("fleet.room.entry.\(entry.seq)")
        }
    }

    private var emptyTranscript: some View {
        Text(viewModel.isManagedByDesktop ? "No recent activity synced." : "No messages yet.")
            .font(FleetTheme.secondaryFont)
            .foregroundStyle(FleetTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, FleetTheme.spacingLg)
            .accessibilityIdentifier("fleet.room.empty")
    }

    // MARK: Composer (capability-gated; @mention autocomplete when capable)

    @ViewBuilder
    private var composer: some View {
        if !viewModel.isDisbanded {
            VStack(spacing: 0) {
                // D20: @mention autocomplete over the live fleet roster.
                // Renders only while an active "@fragment" is being typed;
                // inserted text is plain text — delivery is room policy and
                // is never presented as a completed ping.
                MentionAutocomplete(
                    draft: $draft,
                    candidates: environment.mentionCandidates(),
                    gatewayLabel: { [weak environment] id in
                        environment?.gateway(for: id)?.displayName ?? id.rawValue
                    })
                HStack(spacing: FleetTheme.spacingSm) {
                    Image(systemName: "chevron.up.forward")
                        .foregroundStyle(FleetTheme.textSecondary)
                    TextField(
                        viewModel.capabilities.canSend ? "Message the room (@ to mention)" : "Read only",
                        text: $draft
                    )
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($composing)
                    .disabled(!viewModel.capabilities.canSend)
                    .accessibilityIdentifier("fleet.room.composer.field")
                    .onSubmit { Task { await submit() } }
                    if viewModel.capabilities.canSend {
                        Button {
                            Task { await submit() }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSending)
                        .accessibilityIdentifier("fleet.room.send")
                    }
                }
                .padding(.horizontal, FleetTheme.spacingMd)
                .padding(.vertical, 10)
                .background(FleetTheme.surfaceElevated)
                .clipShape(Capsule())
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.bottom, FleetTheme.spacingSm)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("fleet.room.composer")
        }
    }

    private func submit() async {
        let text = draft
        guard await viewModel.send(text) else { return }
        draft = ""
        composing = false
    }

    /// D22: map a typed recovery action to its behavior. Retry-class actions
    /// ride the room command seam; the others explain the honest next step
    /// (this client cannot re-authenticate a provider or edit gateway config
    /// — the copy says where to do it).
    private func perform(_ action: BotFailureCopy.Action) async {
        switch action {
        case .retry:
            _ = await viewModel.retry(taskID: viewModel.indeterminateTaskID ?? "latest")
        case .compressThenResume:
            // context_overflow recovery: the gateway compresses on resume —
            // retry carries the compress-then-resume semantics upstream.
            _ = await viewModel.retry(taskID: viewModel.indeterminateTaskID ?? "latest")
        case .waitAndAutoRetry:
            // Rate limit / server error auto-retry upstream; nothing to fire.
            break
        case .reauthenticate, .openSettings, .checkQuota, .pickModel, .reconnectRuntime:
            // Honest no-op from this surface: these live in gateway/bot
            // settings, not the room. The copy already says where to go.
            break
        }
    }

    // MARK: Toolbar (rename / disband, capability-gated)

    @ToolbarContentBuilder
    private var toolbarControls: some ToolbarContent {
        // Slice 5 (D19): RoomLink management for hosted rooms (negotiation,
        // grants, routes, replay, takeover) — legacy rooms never offer it.
        if viewModel.room.id.provenance == .hosted && !viewModel.isDisbanded {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingRoomLink = true
                } label: {
                    Label("RoomLink", systemImage: "link")
                }
                .accessibilityIdentifier("fleet.room.roomlink")
            }
        }
        if viewModel.capabilities.canRename {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    renameDraft = viewModel.roomName
                    showingRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .accessibilityIdentifier("fleet.room.rename")
            }
        }
        if viewModel.capabilities.canDisband && !viewModel.isDisbanded {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    showingDisbandConfirm = true
                } label: {
                    Label("Disband", systemImage: "trash")
                }
                .accessibilityIdentifier("fleet.room.disband")
            }
        }
    }

    private var renameSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                TextField("Room name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("fleet.room.rename.field")
                Button {
                    showingRename = false
                    Task { await viewModel.rename(renameDraft) }
                } label: {
                    Text("Rename")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("fleet.room.rename.submit")
            }
            .padding(FleetTheme.spacingLg)
            .navigationTitle("Rename Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingRename = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
