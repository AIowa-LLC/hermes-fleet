import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import FleetCore
import FleetPersistence

/// B87 follow-up ("Cannot open chat"): what `ConversationView.body` should
/// render for a given (VM presence, fleet hydration, gateway registration)
/// snapshot. Before this, `viewModel == nil` always meant `.unavailable` —
/// including while the fleet was still hydrating on cold launch, or (with a
/// persisted navigation path) for a route whose gateway hadn't answered
/// yet. Pure and testable so the loading/unavailable split doesn't depend on
/// a live `AppEnvironment`.
public enum ConversationOpenState: Equatable, Sendable {
    /// A `ConversationViewModel` exists — render the canvas.
    case ready
    /// No VM yet, but there is something to wait on (the fleet is still
    /// hydrating, or this route's gateway has not answered yet) — show a
    /// loading placeholder and retry, never the dead-end unavailable state.
    case loading
    /// Hydration has settled and this route has nothing left to wait on
    /// (its gateway was removed, or the gateway has no conversation seam
    /// wired) — nothing to retry; show the honest unavailable state.
    case unavailable
}

/// Pure decision the view's `.task(id:)` and `body` both read from.
public enum ConversationOpenPolicy {
    /// - Parameters:
    ///   - hasViewModel: `ConversationView.viewModel != nil`.
    ///   - hydrationPhase: `AppEnvironment.hydrationPhase` at render time.
    ///   - attemptedOpen: whether VM creation has been attempted against
    ///     the CURRENT (hydration, gateway-registration) snapshot. Reset on
    ///     every `openTrigger` change so a gateway appearing re-arms loading.
    public static func resolve(
        hasViewModel: Bool,
        hydrationPhase: AppEnvironment.HydrationPhase,
        attemptedOpen: Bool
    ) -> ConversationOpenState {
        if hasViewModel { return .ready }
        // Fleet-wide restore hasn't settled yet (cold launch, or a restored
        // navigation path racing the durable gateway read) — the registry is
        // not authoritative yet, so a missing gateway right now proves
        // nothing. Keep waiting.
        if hydrationPhase == .loading { return .loading }
        // Settled, but this snapshot has not been tried yet (first frame
        // before `.task` runs, or a trigger change mid-flight): show loading,
        // never a flash of the dead-end state.
        if !attemptedOpen { return .loading }
        // Settled AND tried against this exact snapshot with no VM: the
        // gateway is gone or has no conversation seam — terminal until the
        // snapshot changes (which re-arms `attemptedOpen`). Never an endless
        // spinner.
        return .unavailable
    }
}

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
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openFleetDrawer) private var openDrawer
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingTimeline = false
    @State private var followingLatest = true
    /// Dogfood top-space fix: bumped by the toolbar/menu "Latest" action;
    /// the transcript scrolls to the live bottom on change (the toolbar
    /// cannot reach the ScrollViewReader proxy directly).
    @State private var scrollPulse = 0
    /// B87 round 2 (ported from `RoomChatView`'s FOS-8 follow pattern,
    /// simplified — no lazy-history frame convergence loop; this transcript
    /// scrolls a single known row via `ScrollViewProxy` directly).
    /// True once the transcript's own scroll geometry reports the live
    /// bottom is on-screen (tolerance-based). This only CONFIRMS arrival —
    /// it never itself unfollows; see `isUserInteractingWithScroll` below.
    @State private var isAtBottomLatest = true
    /// True only while a REAL finger drag is in progress
    /// (`onScrollPhaseChange` reports `.interacting`). Combined with
    /// `isAtBottomLatest`, this is the ONLY thing allowed to flip
    /// `followingLatest` to false — a brand-new row, a growing streamed
    /// reply/reasoning block, or this view's own `scrollToLive` calls must
    /// never unfollow the user.
    @State private var isUserInteractingWithScroll = false
    /// Set for the duration of every scroll this view issues itself
    /// (`scrollToLive`) so the geometry/phase observers below never mistake
    /// a programmatic scroll for the user's own drag.
    @State private var isProgrammaticFollow = false
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
            ? environment.bot(for: route).map { BotRosterPresentation.displayTitle(for: $0) } ?? route.profileSlug.rawValue
            : route.profileSlug.rawValue
    }

    @State private var viewModel: ConversationViewModel?
    @State private var composerText = ""
    /// V4 motion: bumped on every composer submit so `.sensoryFeedback`
    /// fires the send haptic (trigger-based; not on initial appearance).
    @State private var sendPulse = 0
    /// R9-T2: model picker sheet presentation.
    @State private var showingModelPicker = false

    /// Dogfood r8: thinking-level overlay presentation.
    @State private var showingReasoningSlider = false
    /// R9-T3: context breakdown sheet presentation.
    @State private var showingContextBreakdown = false
    @State private var showingFolderPath = false
    // r9 toolbelt sheet state.
    @State private var showingWorkingFolder = false
    @State private var showingDossier = false
    /// R9-T4: fork navigation — the new session id to route to.
    @State private var forkTargetSessionID: String?
    /// Slash parity: pending command-driven navigation (new chat / model
    /// picker / sessions list) and composer prefill adoption, each fired once.
    @State private var newChatTargetSessionID: String?
    /// R10-T1: composer attachment pickers.
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingFileImporter = false
    @FocusState private var composerFocused: Bool
    /// Dogfood r6 (G1): the focus signal driving the pill→card morph. (The
    /// composer's adaptive glass + shadow no longer read the color scheme
    /// directly — the shadow is a theme token, `theme.shadow`.)

    /// The composer morphs: stadium when idle (fully-rounded pill), a soft
    /// 26pt card when focused/expanding — ChatGPT/Hermex's presentation
    /// recipe. Driven by focus (the honest signal the keyboard is up).
    private var composerPillRadius: CGFloat {
        composerFocused ? 26 : 22
    }
    /// R10-T4: voice transcript review confirmation (sheet). Presented when a
    /// transcript lands for review (submit-on-silence OFF).
    @State private var showingTranscriptReview = false

    // P0-B (RC-84): Find in Conversation — view-local search over the
    // loaded transcript. Purely additive: never mutates conversation state.
    @State private var findActive = false
    @State private var findQuery = ""
    @State private var findMatches: [ConversationFindPolicy.Match] = []
    @State private var findIndex = 0
    /// Bumped to ask the transcript's ScrollViewReader to scroll to the
    /// active match (the find bar cannot reach the proxy directly — same
    /// pulse pattern as `scrollPulse`).
    @State private var findScrollPulse = 0
    @State private var findTargetRowID: String?
    @FocusState private var findFieldFocused: Bool

    public init(environment: AppEnvironment, route: Route, sessionID: String?) {
        self.environment = environment
        self.route = route
        self.sessionID = sessionID
    }

    /// B87 follow-up: whether this route's gateway is registered right now.
    /// Read fresh on every access (never cached) — it is the live signal
    /// both the render decision and the retry trigger key off of.
    private var isGatewayPresent: Bool {
        environment.gateway(for: route.gatewayID) != nil
    }

    /// The retry key for `.task(id:)`: VM creation is re-attempted whenever
    /// the fleet's hydration settles or this route's gateway registration
    /// changes, instead of freezing forever on whatever was true at the
    /// instant this screen first mounted.
    /// The `openTrigger` snapshot VM creation was last attempted against
    /// (nil = never). `openState` is `.unavailable` only once the CURRENT
    /// snapshot has been tried and produced no VM.
    @State private var attemptedOpenTrigger: OpenTrigger?
    /// True while a `.task(id:)` run is inside `viewModel.start()` and its
    /// post-open bookkeeping (see the guard there).
    @State private var isStartInFlight = false

    private struct OpenTrigger: Equatable {
        let hydrationPhase: AppEnvironment.HydrationPhase
        let gatewayPresent: Bool
    }

    private var openTrigger: OpenTrigger {
        OpenTrigger(hydrationPhase: environment.hydrationPhase, gatewayPresent: isGatewayPresent)
    }

    private var openState: ConversationOpenState {
        ConversationOpenPolicy.resolve(
            hasViewModel: viewModel != nil,
            hydrationPhase: environment.hydrationPhase,
            attemptedOpen: attemptedOpenTrigger == openTrigger)
    }

    public var body: some View {
        Group {
            if let viewModel {
                canvas(viewModel)
            } else if openState == .loading {
                loadingPlaceholder
            } else {
                unavailable
            }
        }
        .navigationTitle(screenTitle)
        // Compaction round 2: the conversation owns ALL of its chrome in one
        // 44pt row — the system navigation bar is hidden here (back, drawer,
        // status, timeline and latest all live in the compact header row /
        /// the floating latest chevron / the ⋯ menu).
        .navigationBarTitleDisplayMode(.inline)
        // B87 follow-up: the compact in-canvas header (with its own back
        // control) exists only once a VM is live. Loading and unavailable
        // render before that header exists, so the system navigation bar —
        // and its back button — must stay visible, or the screen is a dead
        // end with no way out.
        .toolbar(viewModel == nil ? .visible : .hidden, for: .navigationBar)
        .task(id: openTrigger) {
            if viewModel == nil {
                viewModel = environment.makeConversationViewModel(route: route, sessionID: sessionID)
                attemptedOpenTrigger = openTrigger
            }
            // Nothing to (re)start yet — the next retrigger of `openTrigger`
            // (hydration settling, or the gateway appearing/disappearing)
            // tries again. `start()` below is idempotent for an
            // already-live VM (P2-3), so a retrigger after success is safe.
            guard let viewModel else { return }
            // `.task(id:)` cancellation is cooperative and `start()` has no
            // re-entrancy guard until `openedSessionID` lands, so a trigger
            // change while the first open is still awaiting would run a
            // SECOND concurrent open (for a new chat: two createSession
            // calls). The in-flight run finishes the open and its
            // post-open bookkeeping; a later run (re-appear) still restarts
            // the status watcher as before.
            guard !isStartInFlight else { return }
            isStartInFlight = true
            defer { isStartInFlight = false }
            // Foreground auto-heal: a mounted conversation reconnects itself
            // when the app returns (no manual banner tap).
            viewModel.startForegroundHealing()
            await viewModel.start()
            // FOS-4 (SPEC §7 Continue / §17): record the open ONLY after the
            // destination resolved — the view model's resolved id is the
            // exact session (resumed or created), never a title guess.
            if let resolved = viewModel.resolvedSessionID {
                // Dogfood r4 (decision 1): opening marks read. Use the
                // LISTED session's lastActive when this entry came from a
                // list read; a brand-new session has nothing unread yet.
                if let listed = environment.sessionsByRoute[route]?.first(where: { $0.id == resolved }) {
                    environment.markConversationRead(route: route, sessionID: resolved, lastActive: listed.lastActive)
                }
                let gatewayLabel = environment.gateway(for: route.gatewayID)?.displayName
                    ?? route.gatewayID.rawValue
                environment.recordConversationOpen(
                    route: route,
                    sessionID: resolved,
                    canonical: environment.isCanonicalBotChat(route: route, sessionID: resolved),
                    title: screenTitle,
                    subtitle: "\(route.profileSlug.rawValue) · \(gatewayLabel)")
            }
            // R10-T1 demo hook (simulator only): `HERMES_FLEET_ATTACHMENT_PICK=1`
            // stages a fixture markdown file through the seam once the session
            // is open — the deterministic UI-test stand-in for the system
            // photo/document pickers (which cannot be driven deterministically
            // on the simulator).
            if ProcessInfo.processInfo.environment["HERMES_FLEET_ATTACHMENT_PICK"] == "1",
               viewModel.pendingAttachments.isEmpty {
                let fixture = Data("# fixture notes\nR10-T1 scripted attachment.\n".utf8)
                await viewModel.stageAttachment(
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
        .background(theme.background.ignoresSafeArea())
    }

    // MARK: Canvas

    private func canvas(_ model: ConversationViewModel) -> some View {
        VStack(spacing: 0) {
            compactHeader(model)
            // P0-B (RC-84): the Find in Conversation bar docks directly
            // under the compact header while active.
            if findActive {
                findBar(model)
            }
            bannerArea(model)
            // R9-T4: transient tooling notices (fork/rename failures) —
            // renders nothing when clear, so the steady-state chrome stays
            // one banner; failures are never silenced.
            if let toolingModel = model.toolingViewModel {
                ToolingNoticeBanner(model: toolingModel)
            }
            if let replyActionError = model.replyActionError {
                replyActionErrorBanner(model, message: replyActionError)
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
        // Dogfood r8: thinking-level overlay — presented above the composer
        // (NOT a sheet: no presentation animation can drop taps; the scrim
        // keeps the composer visible below the panel).
        .overlay {
            if showingReasoningSlider, let reasoningModel = model.reasoningViewModel {
                ReasoningSliderOverlay(model: reasoningModel) {
                    showingReasoningSlider = false
                }
                .transition(.opacity)
            }
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
        .onChange(of: model.forkedSession?.storedSessionID ?? model.forkedSession?.sessionID) { _, newID in
            guard let newID, newID != forkTargetSessionID else { return }
            // session.branch returns distinct runtime + stored identities;
            // ConversationViewModel's open path accepts the stored/list key.
            forkTargetSessionID = newID
            model.consumeForkedSession()
        }
        .navigationDestination(isPresented: forkNavigationBinding) {
            ConversationView(
                environment: environment,
                route: route,
                sessionID: forkTargetSessionID
            )
            .toolbar { FleetDrawerMenu(showsUnreadBadge: environment.anyUnreadSessions) }
        }
        // Slash parity: command-driven navigation. /new pushes a fresh
        // conversation on the SAME route (gateway/profile preserved);
        // /model opens the native picker; /resume,/sessions,/switch pop to
        // the Chats list (Fleet's native session UX). Each navigation is
        // CONSUMED after handling (the consumeForkedSession pattern) so a
        // second identical command re-fires.
        .onChange(of: model.commandNavigation) { _, navigation in
            guard let navigation else { return }
            switch navigation {
            case .newConversation(let sessionID):
                newChatTargetSessionID = sessionID
            case .modelPicker:
                showingModelPicker = true
            case .sessionsList:
                dismiss()
            }
            model.consumeCommandNavigation()
        }
        .navigationDestination(isPresented: newChatBinding) {
            ConversationView(
                environment: environment,
                route: route,
                sessionID: newChatTargetSessionID
            )
            .toolbar { FleetDrawerMenu(showsUnreadBadge: environment.anyUnreadSessions) }
        }
        // (Toolbar intentionally empty: the former principal StatusPill and
        // the trailing timeline/latest items now live in compactHeader and
        // the ⋯ session-actions menu; latest ALSO floats on the transcript.)
        .overlay(alignment: .bottomTrailing) {
            floatingLatestChevron
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showingJumpToLatest)
    }

    /// Floating jump-to-latest chevron — zero permanent chrome: it renders
    /// ONLY while the user has scrolled away from the live bottom (same
    /// condition the old toolbar item used), overlaid on the transcript's
    /// bottom-trailing corner above the composer.
    @ViewBuilder
    private var floatingLatestChevron: some View {
        if showingJumpToLatest {
            Button {
                followingLatest = true
                scrollPulse += 1
            } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(theme.highlight, theme.surface)
            }
            .buttonStyle(.fleetPressable)
            .accessibilityLabel("Latest")
            .accessibilityIdentifier("fleet.conversation.timeline.latest")
            .padding(.trailing, FleetTheme.spacingLg)
            .padding(.bottom, FleetTheme.spacingSm)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    /// Whether any loaded user turn exists (same condition the removed
    /// permanent row used to gate its rendering).
    private var hasUserTurns: Bool {
        viewModel?.transcript.contains(where: { $0.kind == .user }) ?? false
    }

    /// The transcript follows the live bottom until the user scrolls away;
    /// this drives the "Latest" affordance (same semantics as the removed
    /// inset row — manual scroll-off cancels following).
    private var showingJumpToLatest: Bool {
        hasUserTurns && !followingLatest
    }

    /// Two-way binding for the /new push: entering pushes the fresh
    /// conversation; popping clears the target so a SECOND /new can push
    /// again.
    private var newChatBinding: Binding<Bool> {
        Binding(
            get: { newChatTargetSessionID != nil },
            set: { shown in
                if !shown { newChatTargetSessionID = nil }
            }
        )
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

    // MARK: Single-row header (dogfood compaction round 2 — merge the
    // inline nav bar INTO the bot header row; the conversation hides the
    // system navigation bar entirely and owns its chrome: back, drawer,
    // status dot, identity, meter, chip, actions — 44pt total).

    /// ONE row: [‹] [☰] [avatar●status] Name / session-title … [3%] [chip] [⋯]
    /// - Back: custom chevron (NavigationStack pop; swipe-back survives —
    ///   the gesture rides the interactive pop, not the bar).
    /// - Drawer: same `openFleetDrawer` action + `fleet.drawer.open` id.
    /// - Status: colored dot on the avatar's corner (semantic color); the
    ///   spoken form stays on the identity element ("Status: Online").
    /// - Identity: 28pt avatar, name + title stacked; at accessibility
    ///   sizes the trailing metadata drops (still reachable via ⋯).
    /// - Timeline + jump-to-latest moved into the ⋯ session-actions menu;
    ///   latest ALSO has a zero-chrome floating chevron on the transcript.
    private func compactHeader(_ model: ConversationViewModel) -> some View {
        let bot = environment.bot(for: route)
        let name = bot?.displayName ?? route.profileSlug.rawValue
        let status = headerPillStatus(bot: bot, model: model)
        return HStack(spacing: FleetTheme.spacingSm) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fleetPressable)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("fleet.conversation.back")

            Button {
                openDrawer?()
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fleetPressable)
            .accessibilityLabel("Menu")
            .accessibilityIdentifier("fleet.drawer.open")

            avatarWithStatus(bot: bot, status: status)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .accessibilityIdentifier("fleet.conversation.header.name")
                Text(model.sessionTitle ?? route.id)
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("fleet.conversation.header.title")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(name), status \(status.label)")
            .accessibilityIdentifier("fleet.conversation.header.identity")

            // Keep the session actions trailing and make the custom chrome
            // span the full width. Without a flexible spacer this HStack is
            // content-sized and the header visibly collapses on entry.
            Spacer(minLength: FleetTheme.spacingXs)

            // P0-B (RC-84): Find in Conversation — a fixed 44pt control
            // (the header's Spacer geometry keeps the row full-width).
            Button {
                if findActive {
                    closeFind()
                } else {
                    openFind()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(findActive ? theme.highlight : theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fleetPressable)
            .accessibilityLabel("Find in Conversation")
            .accessibilityIdentifier("fleet.conversation.find")

            // r9: the chip zone moved UNDER the composer (the Toolbelt) —
            // nothing renders here anymore.
            if let toolingModel = model.toolingViewModel {
                SessionSteerControls(
                    model: toolingModel,
                    isStreaming: model.isStreaming,
                    sessionTitle: model.sessionTitle,
                    showsTimeline: hasUserTurns,
                    showsLatest: showingJumpToLatest,
                    onTimeline: { showingTimeline = true },
                    onLatest: {
                        followingLatest = true
                        scrollPulse += 1
                    },
                    onFork: { _ in }
                )
            }

            // R9-T3: per-session YOLO toggle (session-scoped only, confirmed
            // on enable). Hidden when the session has no approvals seam.
            // (Restored: e748746's single-row header dropped this mount while
            // claiming identifier preservation; R9ApprovalBanner is the guard.)
            if let approvalModel = model.approvalViewModel {
                SessionYoloToggle(model: approvalModel)
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, FleetTheme.spacingSm)
        .padding(.vertical, 4)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.conversation.header")
    }

    // MARK: Find in Conversation (P0-B / RC-84)

    /// Opens the find bar fresh (empty query, no stale matches).
    private func openFind() {
        findQuery = ""
        findMatches = []
        findIndex = 0
        findTargetRowID = nil
        findActive = true
    }

    /// Closes find and restores the steady-state chrome — no conversation
    /// state is touched.
    private func closeFind() {
        findActive = false
        findQuery = ""
        findMatches = []
        findIndex = 0
        findTargetRowID = nil
        findFieldFocused = false
    }

    /// The status text in the find bar: "n of m", "No matches" for a live
    /// no-result query, empty while the query is blank.
    private var findStatusText: String {
        guard !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard !findMatches.isEmpty else { return "No matches" }
        return ConversationFindPolicy.positionText(index: findIndex, count: findMatches.count)
    }

    /// Recomputes matches over the loaded (bounded) transcript. `resetIndex`
    /// is true for a fresh query (land on the first match) and false when
    /// the transcript grew underneath a live query (keep the user's place).
    private func recomputeFind(_ model: ConversationViewModel, resetIndex: Bool = true) {
        let previousTarget = findTargetRowID
        findMatches = ConversationFindPolicy.matches(rows: model.transcript, query: findQuery)
        guard !findMatches.isEmpty else {
            findIndex = 0
            findTargetRowID = nil
            return
        }
        findIndex = resetIndex ? 0 : min(max(findIndex, 0), findMatches.count - 1)
        findTargetRowID = findMatches[findIndex].rowID
        if findTargetRowID != previousTarget {
            // Manual navigation stops live-follow; the floating chevron
            // carries the way back (same rule as the timeline sheet).
            followingLatest = false
            findScrollPulse += 1
        }
    }

    /// Moves to the previous/next match with wrap-around.
    private func advanceFind(direction: Int) {
        guard !findMatches.isEmpty else { return }
        findIndex = direction >= 0
            ? ConversationFindPolicy.nextIndex(current: findIndex, count: findMatches.count)
            : ConversationFindPolicy.previousIndex(current: findIndex, count: findMatches.count)
        findTargetRowID = findMatches[findIndex].rowID
        followingLatest = false
        findScrollPulse += 1
    }

    /// The find bar: field + match position + prev/next + close. Docks
    /// under the compact header while active; every control is a 44pt
    /// target. Typing is debounced via `.task(id:)` so long transcripts
    /// are not rescanned per keystroke.
    private func findBar(_ model: ConversationViewModel) -> some View {
        HStack(spacing: FleetTheme.spacingSm) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
                TextField("Find in conversation", text: $findQuery)
                    .font(.subheadline)
                    .foregroundStyle(theme.textPrimary)
                    .tint(theme.highlight)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($findFieldFocused)
                    .onSubmit { advanceFind(direction: 1) }
                    .accessibilityIdentifier("fleet.conversation.find.field")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.background, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))

            Text(findStatusText)
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
                .accessibilityIdentifier("fleet.conversation.find.count")

            Button {
                advanceFind(direction: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fleetPressable)
            .disabled(findMatches.isEmpty)
            .accessibilityLabel("Previous match")
            .accessibilityIdentifier("fleet.conversation.find.prev")

            Button {
                advanceFind(direction: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fleetPressable)
            .disabled(findMatches.isEmpty)
            .accessibilityLabel("Next match")
            .accessibilityIdentifier("fleet.conversation.find.next")

            Button {
                closeFind()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fleetPressable)
            .accessibilityLabel("Close find")
            .accessibilityIdentifier("fleet.conversation.find.close")
        }
        .padding(.horizontal, FleetTheme.spacingSm)
        .padding(.vertical, 2)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
        }
        // `.contain` (the compact-header pattern) makes the bar a container
        // element so the field/stepper/close keep their OWN identifiers —
        // without it the bar's id propagates onto every child (AX dump
        // evidence, RC-84 CC UI test).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.conversation.find.bar")
        .task(id: findQuery) {
            // Debounce: a short idle before rescanning keeps long
            // transcripts off the per-keystroke path.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            recomputeFind(model)
        }
        .onAppear { findFieldFocused = true }
    }

    /// 28pt avatar with a 10pt status dot pinned bottom-trailing. The dot is
    /// decorative (the identity element carries the spoken status).
    private func avatarWithStatus(bot: FleetBot?, status: FleetStatus) -> some View {
        BotAvatar(bot: bot, management: environment.botManagement)
            .frame(width: 28, height: 28)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(theme.semanticStatusColor(for: status))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(theme.surface, lineWidth: 2))
            }
    }

    /// Working-project-folder chip: folder glyph + the LAST path component
    /// (full path in the tap popover — phone-width chips must not truncate).
    /// Hidden honestly when the gateway reports no cwd.
    @ViewBuilder
    private func folderChip(_ model: ConversationViewModel) -> some View {
        if let cwd = model.sessionCWD {
            // r9 toolbelt: the folder chip now opens the working-folder
            // SWITCHER (session.cwd.set) — copy-path moved to a long-press.
            Button {
                showingWorkingFolder = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                    Text(ConversationHeaderChips.lastPathComponent(cwd))
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.background, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
            }
            .buttonStyle(.fleetPressable)
            .simultaneousGesture(LongPressGesture().onEnded { _ in
                UIPasteboard.general.string = cwd
            })
            .accessibilityLabel("Working folder")
            .accessibilityValue(cwd)
            .accessibilityHint("Changes the session's working directory")
            .accessibilityIdentifier("fleet.conversation.header.folder")
            .sheet(isPresented: $showingWorkingFolder) {
                if let toolingModel = model.toolingViewModel {
                    WorkingFolderSheet(
                        model: toolingModel,
                        currentCWD: cwd,
                        onChanged: { info in
                            model.refreshCWD(info)
                        }
                    )
                    .presentationDetents([.medium])
                }
            }
        }
    }

    /// Selected-profile chip (display-only; the conversation is bound to
    /// this profile's route).
    @ViewBuilder
    private func profileChip(_ model: ConversationViewModel) -> some View {
        if let profile = model.sessionProfileName {
            // r9 toolbelt: the profile chip opens the session DOSSIER —
            // identity card + rename + branch (wires that already existed).
            Button {
                showingDossier = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                    Text(profile)
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.background, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
            }
            .buttonStyle(.fleetPressable)
            .accessibilityLabel("Profile")
            .accessibilityValue(profile)
            .accessibilityHint("Session details, rename, and branch")
            .accessibilityIdentifier("fleet.conversation.header.profile")
            .sheet(isPresented: $showingDossier) {
                if let toolingModel = model.toolingViewModel {
                    SessionDossierSheet(
                        model: toolingModel,
                        profileName: profile,
                        gatewayName: model.route.gatewayID.rawValue,
                        sessionID: model.sessionID ?? "—",
                        sessionTitle: model.sessionTitle ?? "Session",
                        onBranch: { branch in
                            model.adoptFork(branch)
                        }
                    )
                    .presentationDetents([.medium])
                }
            }
        }
    }

/// Animated three-dot "working" glyph (Hermes `...` parity). Discrete phase
/// animation ~0.9s cycle; purely decorative (the working label carries AX).
private struct WorkingDots: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.85))
                    .frame(width: 4, height: 4)
                    .opacity(0.35 + 0.65 * pulse(index: index))
            }
        }
        .onAppear { phase = 0 }
        .task {
            while !Task.isCancelled {
                phase += 0.15
                try? await Task.sleep(for: .milliseconds(135))
            }
        }
    }

    /// 0...1 opacity wave for dot `index` at the current phase.
    private func pulse(index: Int) -> Double {
        let offset = Double(index) / 3.0
        let t = (phase.truncatingRemainder(dividingBy: 3.0)) / 3.0
        return 0.5 + 0.5 * sin((t - offset) * 2 * .pi)
    }
}

/// Header chip string helpers.
enum ConversationHeaderChips {
    /// Last path component of a working directory ("/a/b/hermes-fleet" ->
    /// "hermes-fleet"; "/" -> "/"; trailing slashes normalized).
    static func lastPathComponent(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "/" }
        return String(trimmed.split(separator: "/").last ?? Substring(trimmed))
    }
}

    /// The compact model chip (no longer its own dedicated full-width row).
    /// The chip shows the sticky pick (or the session's model readback);
    /// tap opens the picker. Same identifiers and semantics as before.
    private func modelChipButton(_ model: ConversationViewModel) -> some View {
        Button {
            showingModelPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                Text(model.toolingViewModel?.selectedModel?.shortName
                     ?? model.sessionModel?.split(separator: "·").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
                     ?? "model")
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(
                        model.toolingViewModel?.selectedModel != nil
                            ? theme.highlight
                            : theme.textSecondary
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.background, in: Capsule())
        }
        .buttonStyle(.fleetPressable)
        .accessibilityLabel("Model picker")
        .accessibilityValue(model.toolingViewModel?.selectedModel?.model ?? "profile default")
        .accessibilityHint("Choose the model for new chats on this device")
        .accessibilityIdentifier("model.chip")
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
        case .streaming:
            return .executing(.working)
        case .ready:
            return .online
        case .idle, .opening, .connecting, .reconnecting:
            return .waiting
        case .authRequired:
            return .authRequired
        case .failed:
            return .degraded
        case .disconnected:
            return .offline
        }
    }

    // MARK: Status / reconnect / replay / auth banners

    /// Compact banner chrome (dogfood top-space fix): exactly ONE banner —
    /// the highest-priority surface for the current state (see
    /// `ConversationBannerSelector`). Actionable failure states keep their
    /// Reconnect / Re-authenticate buttons and identifiers; networking and
    /// session semantics are untouched.
    @ViewBuilder
    private func bannerArea(_ model: ConversationViewModel) -> some View {
        if let banner = ConversationBannerSelector.select(
            phase: model.phase,
            integrityNotice: model.integrityNotice,
            replayNotice: model.replayNotice,
            hydratedFromCache: model.hydratedFromCache,
            historyLoadError: model.historyLoadError,
            errorMessage: model.errorMessage
        ) {
            HStack(spacing: 12) {
                bannerBody(banner)
                switch banner.kind {
                case .disconnected:
                    Button("Reconnect") {
                        Task { await model.reconnect() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("fleet.conversation.reconnect")
                case .authRequired:
                    Button("Re-authenticate") {
                        Task { await model.reauthenticate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.highlight)
                    .foregroundStyle(theme.onHighlight)
                    .controlSize(.small)
                    .accessibilityIdentifier("fleet.conversation.reauthenticate")
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(theme.surface)
        }
    }

    /// One banner row: spinner (progress states) or glyph + text.
    private func bannerBody(_ banner: ConversationBanner) -> some View {
        HStack(spacing: 8) {
            if banner.kind.showsSpinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: banner.kind.symbolName)
                    .foregroundStyle(bannerTint(banner.kind))
            }
            Text(banner.text)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func bannerTint(_ kind: ConversationBannerKind) -> Color {
        switch kind {
        case .integrity, .disconnected, .authRequired, .failed:
            return FleetTheme.statusDestructive
        default:
            return theme.highlight
        }
    }

    // MARK: Transcript

    /// H1 (t_01c9d411) — native loading placeholder shown while an existing
    /// session's history is in flight and no row has rendered yet. A spinner
    /// plus "Loading conversation…" keeps the screen from reading as a
    /// blank new chat. Redacted skeleton rows would imply content shape we
    /// do not know yet; the plain ProgressView is the honest HIG choice.
    private var historyLoadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading conversation…")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 120)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading conversation history")
        .accessibilityIdentifier("fleet.conversation.history.loading")
    }

    /// "••• Working for 7s" — dots + live elapsed, one line under the last
    /// row (Hermes placement). TimelineView ticks 1s; the label is the AX
    /// surface (VoiceOver reads the live elapsed). Reduce Motion: dots stop.
    private func workingIndicator(_ model: ConversationViewModel) -> some View {
        TimelineView(.periodic(from: model.turnStartedAt ?? .now, by: 1)) { timeline in
            let elapsed = Int(timeline.date.timeIntervalSince(model.turnStartedAt ?? timeline.date))
            HStack(spacing: 6) {
                if reduceMotion {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                } else {
                    WorkingDots()
                }
                Text("Working for \(Self.workingDuration(elapsed))")
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Working for \(Self.workingSpoken(elapsed))")
            .accessibilityIdentifier("fleet.conversation.working")
        }
    }

    /// 7s / 1m 05s — compact elapsed format.
    static func workingDuration(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : String(format: "%dm %02ds", seconds / 60, seconds % 60)
    }

    /// Spoken form for VoiceOver.
    static func workingSpoken(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : String(format: "%d minutes %d seconds", seconds / 60, seconds % 60)
    }

    /// Stage 1 (+ extensions): builds one transcript bubble with its footer
    /// wiring as a sub-expression — the inline form outgrew the type-checker.
    private func bubbleView(model: ConversationViewModel, row: ConversationRow) -> some View {
        ConversationBubbleView(
            row: row,
            environment: environment,
            react: { emoji in
                Task { await model.react(rowID: row.rowID, kind: row.kind, emoji: emoji) }
            },
            clear: {
                Task { await model.clearReaction(rowID: row.rowID, kind: row.kind) }
            },
            onReadAloud: model.voiceCanSpeakFooter
                ? { Task { await model.readReplyAloud(rowID: row.id, text: row.text) } }
                : nil,
            onStopReading: model.voiceCanSpeakFooter
                ? { Task { await model.stopReadingReply() } }
                : nil,
            onBranch: AssistantReplyActionPolicy.branchMessageCount(
                rows: model.transcript, selectedRowID: row.id) != nil
                ? { Task { await model.branchReply(rowID: row.id) } }
                : nil,
            onRetry: AssistantReplyActionPolicy.canRetry(
                rows: model.transcript, selectedRowID: row.id, isStreaming: model.isStreaming)
                ? { Task { await model.retryReply(rowID: row.id) } }
                : nil,
            onSearchWeb: model.phase == .ready && !model.isStreaming
                ? { Task { await model.searchWebReply(rowID: row.id, text: row.text) } }
                : nil,
            isSearchInFlight: model.searchingWebRowID == row.id,
            isReadingThisRow: model.readAloudRowID == row.id
        )
    }

    /// B87 round 2 — ported from `RoomChatView`'s FOS-8 follow pattern,
    /// simplified for this transcript: a single known row is scrolled
    /// directly via `ScrollViewProxy`, so no lazy-history frame-convergence
    /// loop is needed here (that machinery exists there to cope with a
    /// LazyVStack's height estimates for rows it has not yet materialized
    /// over a large durable room history).
    ///
    /// Marks the scroll as programmatic (`isProgrammaticFollow`) so the
    /// `onScrollGeometryChange`/`onScrollPhaseChange` observers in
    /// `transcriptList` never mistake it for the user's own drag — which is
    /// the only thing allowed to unfollow. `animate` is false for in-place
    /// growth (a token, or a streaming Reasoning block, growing the SAME
    /// last row) so a spring animation never replays on every delta; true
    /// only for a brand-new row arriving or an explicit "Latest" jump.
    private func scrollToLive(_ id: String, proxy: ScrollViewProxy, animate: Bool) {
        #if DEBUG
        let scrollDiagnostic = ProcessInfo.processInfo.environment["HERMES_FLEET_INLINE_SCROLL_DIAG"]
        if scrollDiagnostic == "no-follow" { return }
        #endif
        isProgrammaticFollow = true
        var shouldAnimate = animate && !reduceMotion
        #if DEBUG
        if scrollDiagnostic == "no-animation" { shouldAnimate = false }
        #endif
        if shouldAnimate {
            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
        } else {
            proxy.scrollTo(id, anchor: .bottom)
        }
        Task { @MainActor in
            await Task.yield()
            isProgrammaticFollow = false
        }
    }

    private func transcriptList(_ model: ConversationViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.transcript) { row in
                        bubbleView(model: model, row: row)
                        .id(row.id)
                        // P0-B: the active find match gets a border ring
                        // (decorative — the find bar carries the AX truth).
                        .overlay {
                            if findActive, let target = findTargetRowID, row.id == target {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(theme.highlight.opacity(0.7), lineWidth: 1.5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }

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
                    // Hermes-parity working indicator: animated dots + a
                    // live elapsed clock for the WHOLE in-flight turn
                    // (submit → complete/error/interrupt) — the tool/reasoning
                    // phases finally say "working" out loud.
                    if model.isWorking {
                        workingIndicator(model)
                    }
                    // H1 (t_01c9d411): while an EXISTING session's history is
                    // still in flight and no row has rendered yet, show a
                    // HIG-native loading placeholder — never a bare blank
                    // slate that reads as a brand-new chat.
                    if model.showsHistoryLoadingPlaceholder {
                        historyLoadingPlaceholder
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
            // B87 round 2 (ported from RoomChatView's FOS-8 follow pattern):
            // at-bottom detection with tolerance (covers lazy height
            // estimation for a row that just streamed in; tighter than the
            // room's 160pt because this composer is a sibling, not an
            // overlay — a small upward drag must be enough to stop following). This observer
            // only CONFIRMS arrival; it is `isUserInteractingWithScroll`
            // below — the user's own drag — that is allowed to unfollow.
            // Coming back to the bottom under a real drag re-follows (the
            // floating "Latest" chevron hides again).
            .onScrollGeometryChange(for: Bool.self) { geometry in
                #if DEBUG
                if ProcessInfo.processInfo.environment["HERMES_FLEET_INLINE_SCROLL_DIAG"] == "no-geometry" {
                    return true
                }
                #endif
                return geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.visibleRect.height <= 64
            } action: { _, atBottom in
                // A delivered image changes row height without a user drag.
                // Writing view state during that geometry pass feeds another
                // SwiftUI layout update on iOS 26.5. Only a user-driven
                // scroll may change follow state; programmatic growth keeps
                // following the live transcript.
                guard isUserInteractingWithScroll, !isProgrammaticFollow else { return }
                if isAtBottomLatest != atBottom { isAtBottomLatest = atBottom }
                // A drag usually STARTS at the live bottom, so the phase
                // callback alone never sees "away from bottom"; the first
                // non-bottom geometry update during a user-driven scroll is
                // the explicit history escape (same rule as RoomChatView).
                // Arriving back at the bottom under the user's own scroll
                // re-follows and hides the floating Latest chevron.
                if followingLatest != atBottom { followingLatest = atBottom }
            }
            // B87 round 2: the user's own drag away from the bottom is the
            // ONLY thing that unfollows — a brand-new row, in-place
            // streaming growth, and this view's own `scrollToLive` calls
            // all shift geometry while still "following latest" and must
            // never be mistaken for it (guarded by `isProgrammaticFollow`).
            .onScrollPhaseChange { _, phase in
                // User-driven = finger down OR the fling it released
                // (`.decelerating`); programmatic `scrollTo` animations
                // report `.animating` and never count.
                isUserInteractingWithScroll = phase == .interacting || phase == .decelerating
                if phase == .interacting, !isAtBottomLatest, !isProgrammaticFollow {
                    followingLatest = false
                }
            }
            // Dogfood top-space fix: the permanent 44pt "Conversation
            // timeline / Latest" top inset is GONE — the actions moved into
            // the navigation toolbar (`timelineToolbarContents`). The
            // transcript content now starts directly below the banner
            // chrome.
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
                                        .foregroundStyle(theme.textPrimary).padding(.vertical, 4)
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
            // while new rows keep arriving at the bottom. A brand-new row is
            // the one case worth an animated scroll.
            .onChange(of: model.transcript.last?.id) {
                guard followingLatest, let last = model.transcript.last else { return }
                scrollToLive(last.id, proxy: proxy, animate: true)
            }
            // B87 fix: the row-identity rescroll above only fires when a
            // NEW row appears. A streaming turn instead grows the SAME last
            // row in place — its reply text, and its Reasoning block, which
            // is force-expanded for the duration of the stream and then
            // auto-collapses when the turn ends (`ReasoningExpansionState`).
            // Neither edge changed `id`, so the transcript never re-followed
            // the live bottom for them: the block would grow past the
            // viewport unfollowed while streaming, then its collapse would
            // leave a gap between the transcript and the composer — read by
            // testers as the thinking block making the chat "scroll a
            // strange way" / the chat not filling the screen. Re-anchor to
            // the bottom on every change to this signature (text/detail
            // length or streaming state of the last row), not just its id —
            // WITHOUT animation: this can fire on every streamed token, and
            // a spring animation replaying per-token would itself jank.
            .onChange(of: model.transcript.last.map {
                "\($0.id)#\($0.text.count)#\($0.detail?.count ?? 0)#\($0.isStreaming)"
            }) { _, _ in
                guard followingLatest, let last = model.transcript.last else { return }
                scrollToLive(last.id, proxy: proxy, animate: false)
            }
            // Dogfood top-space fix: the toolbar/menu "Latest" action bumps
            // `scrollPulse` (the toolbar cannot reach this proxy); scrolling
            // to the live bottom happens here. An explicit jump is worth
            // animating.
            .onChange(of: scrollPulse) { _, _ in
                guard followingLatest, let last = model.transcript.last else { return }
                scrollToLive(last.id, proxy: proxy, animate: true)
            }
            // P0-B: jumps to the active find match (the find bar sits above
            // this ScrollView and cannot reach the proxy).
            .onChange(of: findScrollPulse) { _, _ in
                guard let target = findTargetRowID else { return }
                if reduceMotion { proxy.scrollTo(target, anchor: .center) }
                else { withAnimation(.snappy) { proxy.scrollTo(target, anchor: .center) } }
            }
            // P0-B: keep matches fresh while the transcript grows (or the
            // bounded display window trims) under a live query.
            .onChange(of: model.transcript.last?.id) { _, _ in
                guard findActive,
                      !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                recomputeFind(model, resetIndex: false)
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
        NavigationLink(value: FleetScreen.projects(route.gatewayID, profile: route.profileSlug, focusPath: ref.displayPath)) {
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
            .foregroundStyle(theme.highlight)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(theme.surfaceElevated, in: Capsule())
            .overlay(
                Capsule().strokeBorder(theme.highlight.opacity(0.35), lineWidth: 1))
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
            if let query = BotConversationMentions.query(in: composerText) {
                let suggestions = BotConversationMentions.suggestions(query: query,
                    roster: environment.mentionCandidates(), excluding: route,
                    gatewayLabel: { environment.gateway(for: $0)?.displayName ?? $0.rawValue })
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(suggestions) { suggestion in
                            Button {
                                composerText = BotConversationMentions.inserting(suggestion.alias, into: composerText)
                            } label: {
                                HStack {
                                    BotAvatar(bot: environment.bot(for: suggestion.id), management: environment.botManagement)
                                    VStack(alignment: .leading) {
                                        Text(suggestion.candidate.friendlyTitle)
                                        Text("@\(suggestion.alias) · \(suggestion.gatewayLabel)").font(.caption)
                                    }
                                }
                            }
                            .accessibilityLabel("Mention \(suggestion.candidate.friendlyTitle) on \(suggestion.gatewayLabel)")
                            .accessibilityIdentifier("fleet.mention.\(suggestion.id.id)")
                        }
                    }
                }.frame(maxHeight: 180)
                 .accessibilityIdentifier("fleet.mentions")
            }
            if let notice = model.botDraftNotice {
                Text(notice).font(.caption).padding(8)
                    .accessibilityIdentifier("fleet.conversation.bot-notice")
            }
            // Issue #4: skill discovery lives in the same compact composer
            // surface as the input, never as a full-screen command browser.
            if model.isSlashPaletteVisible {
                slashPalette(model)
            }
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
            // Dogfood r6 (G1): ONE floating composer pill (ChatGPT
            // anatomy) — +, field, mic, and send/stop live INSIDE the
            // stadium; it morphs to a soft card when focused/expanded
            // (Hermex's ChatComposerPresentation recipe: continuous
            // corners, ultraThinMaterial glass, hairline + soft shadow).
            // All controls keep their identifiers (zero test edits).
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
                        // r6: bare glyph inside the pill (the pill is the
                        // surface; 44pt target via the frame).
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityLabel("Attach")
                    .accessibilityIdentifier("fleet.conversation.attach")
                }

                TextField("Message", text: $composerText, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .font(.body)
                    .foregroundStyle(theme.textPrimary)
                    .tint(theme.highlight)
                    // r6: the pill is the field's surface — transparent
                    // inside, no own chrome.
                    .padding(.vertical, FleetTheme.spacingSm)
                    .disabled(model.phase != .ready && model.phase != .streaming)
                    .accessibilityIdentifier("fleet.conversation.composer")
                    .onSubmit {
                        Task { await submit(model) }
                    }

                // r8.1: thinking-level gauge — right cluster, FIRST
                // position (ChatGPT placement: field … gauge, mic, send).
                // Level-encoding needle; highlight ink once adjusted.
                if let reasoningModel = model.reasoningViewModel {
                    ReasoningChip(model: reasoningModel) {
                        showingReasoningSlider = true
                    }
                }

                // R10-T4: mic button — on-device transcription (Speech
                // framework) into the composer. Hidden entirely when no
                // voice engine is wired (fail-closed). While listening, the
                // button becomes a stop control (best-partial capture).
                // r8.1: moved to the RIGHT cluster (ChatGPT order:
                // gauge, mic, send); idle ink is pure white (textPrimary)
                // per Tony — the neutral among two accent buttons.
                if model.isVoiceAvailable {
                    Button {
                        Task { await model.toggleMic() }
                    } label: {
                        Image(systemName: model.isListening ? "stop.circle.fill" : "mic.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(model.isListening ? AnyShapeStyle(FleetTheme.statusDestructive) : AnyShapeStyle(theme.textPrimary))
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityLabel(model.isListening ? "Stop Listening" : "Transcribe Voice")
                    .accessibilityIdentifier("fleet.conversation.mic")
                }

                if model.phase == .streaming || model.isStreaming {
                    Button {
                        Task { await model.interrupt() }
                    } label: {
                        // Hermes parity: the live turn's interrupt reads as
                        // DESTRUCTIVE — bright red glyph on a dimmed red
                        // circle (the mic-stop pattern), not a neutral chip.
                        Image(systemName: "stop.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(FleetTheme.statusDestructive)
                            .frame(width: Self.sendButtonSide, height: Self.sendButtonSide)
                            .background(Circle().fill(FleetTheme.statusDestructive.opacity(0.18)))
                            .overlay(Circle().strokeBorder(FleetTheme.statusDestructive.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("fleet.conversation.stop")
                } else {
                    Button {
                        Task { await submit(model) }
                    } label: {
                        // V2 (Nous Direction A): FLAT highlight circle, derived
                        // ink glyph — the one accent, no glow, no gradient.
                        // The glyph ink is derived from the HIGHLIGHT fill
                        // (not the canvas) so it stays legible for any user
                        // highlight, including white or near-black.
                        // r6: the accent ORB rides inside the pill —
                        // the single interactive accent (ChatGPT's send).
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(theme.onHighlight)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(theme.highlight))
                    }
                    .buttonStyle(.fleetPressable)
                    .disabled(model.phase != .ready || (composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty))
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("fleet.conversation.send")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: composerPillRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: composerPillRadius, style: .continuous)
                    .strokeBorder(theme.border.opacity(0.6), lineWidth: 0.5)
            )
            .shadow(color: theme.shadow, radius: 10, y: 4)
            .padding(.horizontal, FleetTheme.spacingMd)
            .padding(.vertical, 6)
            // Scrollable chip zone: model · working folder · profile ·
            // context — the r9 TOOLBELT, docked UNDER the composer (moved
            // from the header in r9; actions live next to the input they
            // affect). Overflow scrolls (never truncates). Hidden at
            // accessibility sizes (the ⋯ menu carries model + context
            // there — established policy).
            if !dynamicTypeSize.isAccessibilitySize {
                toolbeltZone(model)
            }
        }
        // r6: the composer floats on the canvas — no full-width surface
        // band, no top hairline (the de-glass contract).
        .background(theme.background.ignoresSafeArea())
        // R10-T1: pickers.
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            Task { await loadPickedPhoto(item, model: model) }
        }
        .onChange(of: composerText) { _, newValue in
            model.updateSlashSuggestions(for: newValue)
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.pdf, .item]) { result in
            guard case .success(let url) = result else {
                // User-cancelled picker: not an error.
                return
            }
            Task { await loadPickedFile(url, model: model) }
        }
    }

    /// r9 toolbelt — the chip zone UNDER the composer: model · folder ·
    /// context · profile (actions left → identity right). Extracted from
    /// the composer body (kept the parent expression type-checkable).
    private func toolbeltZone(_ model: ConversationViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FleetTheme.spacingSm) {
                modelChipButton(model)
                folderChip(model)
                if let toolingModel = model.toolingViewModel {
                    ContextMeterView(model: toolingModel) {
                        showingContextBreakdown = true
                    }
                }
                profileChip(model)
            }
            .padding(.horizontal, FleetTheme.spacingXs)
            .frame(minHeight: 32)
        }
        .frame(maxWidth: .infinity)
        .defaultScrollAnchor(.center)
        .accessibilityIdentifier("fleet.conversation.header.chipzone")
        .scrollBounceBehavior(.basedOnSize)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.top, 2)
    }

    /// Compact, touch-friendly skill palette backed entirely by the active
    /// Hermes session's discovery/completion responses.
    private func slashPalette(_ model: ConversationViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: FleetTheme.spacingSm) {
                Image(systemName: "sparkles")
                    .foregroundStyle(theme.highlight)
                Text("Commands")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                if model.isLoadingCommandSuggestions {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingXs)

            if let error = model.commandSuggestionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.statusDegraded)
                    .padding(.horizontal, FleetTheme.spacingLg)
                    .padding(.vertical, FleetTheme.spacingSm)
                    .accessibilityIdentifier("fleet.conversation.command.error")
            } else if model.commandSuggestions.isEmpty && !model.isLoadingCommandSuggestions {
                Text("No commands available in this Hermes profile")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, FleetTheme.spacingLg)
                    .padding(.vertical, FleetTheme.spacingSm)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("No commands available in this Hermes profile")
                    .accessibilityIdentifier("fleet.conversation.command.empty")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        let commandRows = model.commandSuggestions.filter { $0.kind != .skill }
                        let skillRows = model.commandSuggestions.filter { $0.kind == .skill }
                        if !commandRows.isEmpty {
                            paletteSectionLabel("Commands")
                        }
                        ForEach(commandRows) { suggestion in
                            paletteRow(model, suggestion)
                        }
                        if !skillRows.isEmpty {
                            paletteSectionLabel("Skills")
                        }
                        ForEach(skillRows) { suggestion in
                            paletteRow(model, suggestion)
                        }
                    }
                }
                .frame(maxHeight: 176)
            }
        }
        .background(theme.surfaceElevated)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.conversation.command.palette")
    }

    /// One palette row: canonical token + description. Inserting the token
    /// never auto-executes; focus returns to the composer for arguments.
    private func paletteRow(_ model: ConversationViewModel, _ suggestion: SlashCommandSuggestion) -> some View {
        Button {
            composerText = model.selectedCommandText(
                suggestion,
                replacing: composerText)
            composerFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.text)
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textPrimary)
                if !suggestion.description.isEmpty {
                    Text(suggestion.description)
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingSm)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("fleet.conversation.command.\(suggestion.text.dropFirst())")
    }

    private func paletteSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.top, FleetTheme.spacingSm)
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
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                            .fill(theme.surfaceElevated))
                    .accessibilityIdentifier("fleet.conversation.attachment.uploading")
                }
                ForEach(model.pendingAttachments) { chip in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(theme.highlight)
                        Text(chip.caption)
                            .font(.caption)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Button {
                            model.removePendingAttachment(chip.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .accessibilityLabel("Remove attachment \(chip.displayName)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                            .fill(theme.surfaceElevated))
                    .overlay(
                        RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                            .strokeBorder(theme.border, lineWidth: 1))
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
                .foregroundStyle(FleetTheme.statusDestructive)
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                model.clearAttachmentError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityLabel("Dismiss attachment error")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        // r6 G4: flat on canvas + hairline, no boxed card.
        .overlay(alignment: .top) {
            Rectangle().fill(FleetTheme.statusDestructive.opacity(0.35)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.attachment.error")
    }

    /// Assistant-reply actions are user-initiated network operations; any
    /// unsupported gateway or failed request stays visible and dismissible.
    private func replyActionErrorBanner(_ model: ConversationViewModel, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(FleetTheme.statusDestructive)
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                model.clearReplyActionError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityLabel("Dismiss reply action error")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(theme.surfaceElevated)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.reply-action.error")
    }

    /// R10-T2: reaction error banner — never silent (same mandate).
    private func reactionErrorBanner(_ model: ConversationViewModel, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(FleetTheme.statusDestructive)
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                model.clearReactionError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityLabel("Dismiss reaction error")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(theme.surfaceElevated)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.reaction.error")
    }

    // MARK: R10-T4 — voice banners + transcript review chip

    /// Honest authorization-denied gate: mic/speech permission refused — the
    /// ONLY action offered is opening Settings (never a fake retry).
    private func voiceDeniedBanner(_ model: ConversationViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash")
                .foregroundStyle(FleetTheme.statusDestructive)
            Text("Voice needs microphone + speech recognition access. Enable them in Settings to transcribe.")
                .font(.caption)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Settings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.highlight)
            }
            .accessibilityIdentifier("fleet.conversation.voice.denied.settings")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(theme.surfaceElevated)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.voice.denied")
    }

    /// Never-silent voice failure banner (capture/synthesis errors).
    private func voiceErrorBanner(_ model: ConversationViewModel, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(FleetTheme.statusDestructive)
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                model.clearVoiceError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityLabel("Dismiss voice error")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(theme.surfaceElevated)
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
                .foregroundStyle(theme.highlight)
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.text)
                    .font(.caption)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(3)
                if !transcript.isFinal {
                    Text("Partial — stopped early. Edit before sending.")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                composerText = transcript.text
                model.discardTranscript()
            } label: {
                Text("Use")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.highlight)
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
                    .foregroundStyle(theme.highlight)
            }
            .accessibilityIdentifier("fleet.conversation.voice.transcript.send")
            Button {
                model.discardTranscript()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityLabel("Discard transcript")
            .accessibilityIdentifier("fleet.conversation.voice.transcript.discard")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(theme.surfaceElevated)
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
        sendPulse += 1
        if await model.send(text) {
            // A prefill directive (e.g. /undo) REPLACES the draft instead of
            // clearing: adopted synchronously here so the composer's clear
            // can never race the onChange path.
            if let prefill = model.consumePrefill() {
                composerText = prefill
                composerFocused = true
            } else {
                composerText = ""
            }
        }
    }

    /// B87 follow-up: shown instead of `unavailable` while there is still
    /// something to wait on (fleet hydration settling, or this route's
    /// gateway not having answered yet) — `openTrigger` retries VM creation
    /// the moment either changes, so this is never the terminal state.
    private var loadingPlaceholder: some View {
        VStack(spacing: FleetTheme.spacingMd) {
            ProgressView()
            Text("Opening conversation…")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.loading")
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label {
                Text("Conversation Unavailable")
            } icon: {
                Image(systemName: "text.bubble")
                    .foregroundStyle(theme.textSecondary)
            }
        } description: {
            Text(isGatewayPresent
                ? "This gateway has no conversation session wired."
                : "This conversation's gateway is no longer in your fleet.")
        } actions: {
            // B87 follow-up: the compact in-canvas header (with its own back
            // control) never mounts in this state, and the system nav bar's
            // back button depends on the platform default rendering one —
            // an explicit, always-present way out so the screen is never a
            // dead end.
            Button("Go Back") { dismiss() }
                .accessibilityIdentifier("fleet.conversation.unavailable.back")
        }
        .accessibilityIdentifier("fleet.conversation.unavailable")
    }
}

/// P0-8: collapsible, dimmed reasoning block for assistant rows. The summary
/// header (chevron + "Reasoning") is always visible; the reasoning text is
/// expanded while its turn is streaming so live reasoning stays visible, and
/// collapsed by default for completed turns (it is auxiliary, not the reply).
private struct ReasoningDisclosure: View {
    @Environment(\.fleetTheme) private var theme
    /// Build 46: the completed-turn default comes from the persisted
    /// reasoning-presentation preference (Settings → Conversation).
    @AppStorage(ReasoningPresentationPreference.storageKey)
    private var defaultPreferenceRaw = ReasoningPresentationPreference.collapsed.rawValue
    let text: String
    let isStreaming: Bool

    init(text: String, isStreaming: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
    }

    private var preference: ReasoningPresentationPreference {
        ReasoningPresentationPreference(rawValue: defaultPreferenceRaw) ?? .collapsed
    }

    @State private var expansionState = ReasoningExpansionState()

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            Button {
                expansionState.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expansionState.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                    Text("Reasoning")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reasoning, \(expansionState.isExpanded ? "expanded" : "collapsed")")
            .accessibilityHint("Double tap to \(expansionState.isExpanded ? "collapse" : "expand") reasoning")
            .accessibilityIdentifier("fleet.conversation.reasoning.toggle")
            if expansionState.isExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.background, in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
        .onAppear {
            // Completed-turn default from the persisted preference; a live
            // stream immediately re-asserts visibility below.
            if !isStreaming { expansionState.applyDefault(preference) }
        }
        .onChange(of: defaultPreferenceRaw) { _, _ in
            if !isStreaming { expansionState.applyDefault(preference) }
        }
        .onChange(of: isStreaming) { _, nowStreaming in
            // Keep live reasoning visible while the turn streams; auto-
            // collapse when the turn completes. Streaming wins over the
            // preference (live reasoning is the reply being written), but
            // never clears a manual override made during the stream.
            if nowStreaming {
                expansionState.expandForStreaming()
            } else if !expansionState.hasUserOverride {
                expansionState.applyDefault(preference)
            }
        }
    }
}

/// One transcript row (U6 Gold Fleet re-skin): user bubbles are right-aligned
/// magenta-gradient capsules; assistant replies are left-aligned surface
/// cards; timestamps render under each bubble (caption2 secondary) whenever
/// the row carries one.
private struct ConversationBubbleView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let row: ConversationRow
    /// Card D: needed to retrieve/render inline generated-image artifacts on
    /// the row that cited them. Optional so previews/tests that only exercise
    /// plain bubbles keep working.
    var environment: AppEnvironment? = nil
    /// R10-T2: reaction handlers from the owning view (the bubble owns no
    /// model reference).
    var react: (String) -> Void = { _ in }
    var clear: () -> Void = {}
    /// Stage 1: footer action handlers + state from the owning view. Defaults
    /// keep previews/plain-bubble tests working; nil read-aloud hides the
    /// ellipsis (fail-closed voice wiring).
    var onReadAloud: (() -> Void)? = nil
    var onStopReading: (() -> Void)? = nil
    var onBranch: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onSearchWeb: (() -> Void)? = nil
    var isSearchInFlight: Bool = false
    var isReadingThisRow: Bool = false

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
                    // Dogfood r7 (decision 2): the width cap is USER-ONLY
                    // (the capsule stays compact); assistant output spans
                    // the full content width like ChatGPT/Hermex.
                    .frame(maxWidth: row.kind == .user ? 420 : nil,
                           alignment: row.kind == .user ? .trailing : .leading)
                if let reactions = row.reactions, !reactions.isEmpty {
                    reactionChips(reactions)
                }
                if let timestampText {
                    // V3: timestamps are telemetry — mono caption.
                    Text(timestampText)
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                }
                // Stage 1: action footer on COMPLETED assistant replies only
                // (policy gate — streaming/failed/empty rows never render
                // it, so it can never overlap live turns or placeholders).
                if AssistantReplyFooterPolicy.showsFooter(
                    kind: row.kind, text: row.text, isStreaming: row.isStreaming, isFailed: row.isFailed
                ) {
                    AssistantReplyFooter(
                        text: row.text,
                        react: { emoji in react(emoji) },
                        ownReaction: row.reactions?.first(where: { $0.author == "user" })?.emoji,
                        onBranch: onBranch,
                        onRetry: onRetry,
                        onSearchWeb: onSearchWeb,
                        isSearchInFlight: isSearchInFlight,
                        readAloud: onReadAloud,
                        stopReading: onStopReading,
                        isReading: isReadingThisRow,
                        idNamespace: "fleet.conversation.footer.\(row.id)"
                    )
                }
            }
            // B87 fix round 2: the design intent (r7 decision 2, above) is
            // that assistant output spans the FULL content width, like
            // ChatGPT/Hermex — it should never share the row with a
            // trailing spacer at all. Tool/status/system/error rows keep
            // their existing trailing spacer (unchanged card-width look);
            // only `.assistant` drops it. `.layoutPriority(1)` stays as a
            // defensive backstop for those remaining kinds, where the
            // message column can still be exactly as flexible
            // (`.frame(maxWidth: .infinity)`) as their trailing spacer.
            .layoutPriority(1)
            if row.kind != .user && row.kind != .assistant { Spacer(minLength: 60) }
        }
        .transition(row.kind == .user ? entrance : .identity)
        // R10-T2: long-press Tapback menu — small palette + Clear. Only
        // user/assistant rows are reactable (tool/status/system rows are
        // not addressable on the wire). r7: the FLAT assistant row has no
        // bubble fill, so a glyph-landing long-press can be claimed by the
        // text system before the menu fires — the ASSISTANT row attaches
        // its menu to a CLEAR BACKGROUND HOST covering the row (the Hermex
        // #208 pattern, SwiftUI-light form): the host owns the interaction,
        // text stays selectable where it renders, nothing is painted. The
        // USER row keeps the direct attachment — its capsule fill is the
        // proven press target (measured: a host behind the capsule loses).
        .background(
            Group {
                if row.kind == .assistant {
                    Color.clear
                        .contentShape(Rectangle())
                        .contextMenu { reactionMenu }
                }
            }
        )
        .contextMenu { if row.kind != .assistant { reactionMenu } }
        // Rich assistant content contains links, code-copy controls, lists,
        // and tables. Keep those descendants independently reachable while
        // preserving the existing single-element semantics for user/status/
        // system/error bubbles. Tool content already used containment.
        .accessibilityElement(children: row.kind == .tool || (row.kind == .assistant && !row.isFailed) ? .contain : .combine)
        // P2-7: expose speaker + content semantics and live turn state to
        // assistive tech. A contained assistant row supplies speaker context
        // on the parent without hiding its interactive descendants.
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
                        theme.surfaceElevated,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            reaction.author == "user"
                                ? theme.highlight.opacity(0.5)
                                : theme.border,
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
            // Dogfood r6 (G2, supersedes V3 Direction A per owner approval
            // 2026-09-19): NEUTRAL user capsule — ChatGPT/Hermex pattern.
            // neutralFill (the proven per-appearance token), normal label
            // ink, no accent hairline: the accent belongs to interactive
            // chrome (send pill, links), not message content.
            Text(row.text)
                .font(.body)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    FleetTheme.neutralFill,
                    in: RoundedRectangle(cornerRadius: FleetTheme.radiusBubble, style: .continuous)
                )
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                if let detail = row.detail, !detail.isEmpty {
                    // P0-8: reasoning renders as a DISTINCT collapsible,
                    // dimmed block — never merged into the assistant text.
                    ReasoningDisclosure(text: detail, isStreaming: row.isStreaming)
                }
                if row.isFailed {
                    // A failed assistant row is an existing error surface;
                    // keep its visual treatment and literal error copy.
                    Text(row.text)
                        .font(.body)
                        .foregroundStyle(FleetTheme.statusDestructive)
                        .textSelection(.enabled)
                } else if row.text.isEmpty, row.isStreaming {
                    Text("…")
                        .font(.body)
                        .foregroundStyle(theme.textPrimary)
                } else {
                    AssistantRichTextView(
                        markdown: row.text,
                        isStreaming: row.isStreaming,
                        identity: row.id)
                }
                if row.isStreaming {
                    // P2-7: decorative streaming dots — hidden from assistive
                    // tech (the row's accessibilityValue already announces
                    // "Streaming").
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(theme.highlight)
                                .frame(width: 5, height: 5)
                                .opacity(0.6)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            // Dogfood r7 (decision 1, ChatGPT/Hermex parity): the assistant
            // output is FLAT — no capsule. No fill, no border, no wrapper
            // padding: markdown renders directly on the canvas at full
            // content width; only EMBEDDED content draws surfaces (r6 code
            // cards, artifacts). Pinned by the hosted chrome guard.
            //
        case .tool:
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                FleetToolActivityView(title: row.text, detail: row.detail)
                // Card E: the branded indeterminate animation while the
                // gateway has VERIFIED an in-flight image_generate call. The
                // terminal states render nothing here (the artifact slot or
                // the chip above tells the outcome) — and the cross-fade
                // hands the space cleanly to the delivered image.
                if row.generationActivity?.isGenerating == true {
                    FleetWingGenerationView(identifier: row.id)
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                }
                // Card D: generated-image artifacts render in the CITING row's
                // bubble — the row whose result named them (never a positional
                // guess). Retrieval + dedupe live in the shared store.
                if let environment, let artifacts = row.artifacts, !artifacts.isEmpty {
                    ForEach(artifacts, id: \.self) { reference in
                        ConversationArtifactView(
                            reference: reference,
                            environment: environment,
                            identifier: "\(row.id).\(reference.name)")
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                }
            }
            // Card E: the lifecycle swap (animation ⇄ delivered artifact) is
            // one animated handoff; under Reduce Motion both transitions are
            // `.identity` and the animations are nil — an instant, motionless
            // swap.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: row.generationActivity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: row.artifacts)
        case .status, .system:
            Text(row.text)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Label(row.text, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(FleetTheme.statusDestructive)
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
    func resumeSession(sessionID: String, lastEventID: Int? = nil, profile: String? = nil) async throws -> ConversationSession {
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
