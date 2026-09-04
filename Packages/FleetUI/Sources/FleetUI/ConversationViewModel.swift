import Foundation
import Observation
import FleetCore

/// One rendered row in the conversation transcript (U3).
///
/// Pure presentation value derived from `SessionMessage` (persisted/cold-start
/// history) and `ConversationEvent` (streamed turns). `isStreaming` marks an
/// assistant row still accumulating `message.delta` frames; `isFailed` marks a
/// turn whose `message.complete` reported `status == "error"`.
public struct ConversationRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case user
        case assistant
        case tool
        case status
        case system
        case error
    }

    /// Stable identity for SwiftUI list rendering: the durable `row_id` when
    /// one exists, else a monotonic client-assigned id. Never content-derived.
    public let id: String
    public var kind: Kind
    public var text: String
    /// Secondary detail (tool name/context, status kind, thinking text).
    public var detail: String?
    /// Display-only authoring time (Unix seconds) carried through from the
    /// persisted/streamed `SessionMessage` when the gateway stamped one
    /// (U6: timestamp styling under the bubbles). Nil for live rows the
    /// gateway has not stamped yet — no time is fabricated.
    public var timestamp: Double?
    public var isStreaming: Bool
    public var isFailed: Bool

    public init(
        id: String,
        kind: Kind,
        text: String,
        detail: String? = nil,
        timestamp: Double? = nil,
        isStreaming: Bool = false,
        isFailed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.isFailed = isFailed
    }

    // MARK: VoiceOver semantics (P2-7)

    /// A11y label identifying who produced this row + its content. Gives
    /// assistive-tech users the speaker (User / Assistant / Tool / Status /
    /// System / Error) that the combined bubble otherwise hides. Content is
    /// omitted when empty (e.g. an assistant row still streaming its first
    /// delta), so VoiceOver never announces a bare dangling comma.
    public var accessibilityLabel: String {
        let speaker: String
        let content: String
        switch kind {
        case .user:
            speaker = "User"
            content = text
        case .assistant:
            speaker = "Assistant"
            content = text
        case .tool:
            speaker = "Tool"
            // Tool rows carry the tool name as `text` and context as `detail`.
            content = [text, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        case .status:
            speaker = "Status"
            content = text
        case .system:
            speaker = "System"
            content = text
        case .error:
            speaker = "Error"
            content = text
        }
        return content.isEmpty ? speaker : speaker + ", " + content
    }

    /// A11y value describing live row state: "Streaming" while a turn is still
    /// accumulating, "Failed" for an errored turn, otherwise "".
    public var accessibilityValue: String {
        if isFailed { return "Failed" }
        if isStreaming { return "Streaming" }
        return ""
    }
}

/// The conversation screen view model (U3) — observable so SwiftUI renders the
/// full loop: open/create a session (session.create/resume), submit prompts
/// (prompt.submit), render streamed events incrementally (M5), complete a turn
/// (message.complete), interrupt; on reconnect show replay hydration (M6
/// replay-hold → flush seq-gated) and re-auth UX on 4401 (M11: no silent
/// retry). Persisted history via `CacheStoring` (M10) for cold-start.
///
/// FleetUI depends ONLY on the FleetCore seams (`ConversationSessionProviding`,
/// `CacheStoring`) — never on the transport module (M0 guard). The concrete
/// bundle is injected by the composition root.
@MainActor
@Observable
public final class ConversationViewModel {
    /// The conversation screen phase — drives the banner/composer states.
    public enum Phase: Equatable, Sendable {
        /// No work started.
        case idle
        /// Connecting the gateway socket.
        case connecting
        /// session.create / session.resume in flight.
        case opening
        /// Ready to accept a prompt (turn idle or completed).
        case ready
        /// A turn is streaming (message.start → deltas → message.complete).
        case streaming
        /// The socket dropped mid-stream / mid-session; awaiting a reconnect.
        case disconnected
        /// Reconnect + replay hydration in flight.
        case reconnecting
        /// 4401 — authentication required; re-auth is EXPLICIT (no silent
        /// retry, M11).
        case authRequired
        /// A classified failure (non-secret description).
        case failed(String)
    }

    // MARK: Injected seams (composition root)

    private let session: any ConversationSessionProviding
    private let cache: any CacheStoring
    public let route: Route
    /// The runtime session id to resume, or nil to create a new conversation.
    public let sessionID: String?
    /// R9-T1/T2/T3 — biometric seam for the approval gate (FaceID-gated
    /// approve, confirmed YOLO enable). Injected by the composition root;
    /// defaults to the app-lock provider's seam.
    private let biometrics: any AppLockBiometricAuth

    // MARK: Observable state (SwiftUI renders these)

    public private(set) var phase: Phase = .idle
    /// The DISPLAY window the view renders — capped at `maxDisplayRows` so a
    /// long-lived session never grows the in-memory array unboundedly (P2-8).
    /// The authoritative, full history lives in `allRows` (and the persisted
    /// cache), so capping the window never loses history.
    public var transcript: [ConversationRow] {
        Array(allRows.suffix(maxDisplayRows))
    }
    public private(set) var isStreaming = false
    /// Non-secret replay hydration notice shown after a reconnect (M6).
    public private(set) var replayNotice: String?
    /// t_8401d3c3 — non-secret stream-integrity notice shown when a gap was
    /// detected on the live event stream (recovered via targeted replay, or
    /// unrecoverable → authoritative history refetch). Never silent loss.
    public private(set) var integrityNotice: String?
    /// Non-secret error / auth surface text.
    public private(set) var errorMessage: String?
    /// R9-T1 — the approval banner state (pending request + YOLO readback).
    /// Lazily built once the session opens; nil when the concrete session
    /// exposes no approvals seam (fail-soft feature detection).
    public private(set) var approvalViewModel: ApprovalViewModel?
    /// True when the current transcript was hydrated from the persisted cache
    /// (M10 cold-start) rather than a live server fetch.
    public private(set) var hydratedFromCache = false
    /// Best-effort session metadata from session.info.
    public private(set) var sessionTitle: String?
    public private(set) var sessionModel: String?

    // MARK: Internal state

    private var openedSessionID: String?
    /// t_8401d3c3 — the client's last APPLIED event id for the open session's
    /// stream (the "last event id" of Last-Event-ID semantics). Advances only
    /// when an event is actually rendered into the transcript; sent as
    /// `last_seen` on session.resume (subscribe) and used as the resume
    /// cursor for targeted gap replay. Distinct from the transport watermark
    /// (highest observed): applying is what matters for lossless rendering.
    private var lastAppliedEventID: Int?
    private var rowCounter = 0
    /// P0-8: reasoning/thinking deltas that arrive BEFORE this turn's
    /// `message.start` (live wire order: reasoning streams first). Buffered
    /// here instead of attaching to the PREVIOUS turn's completed assistant
    /// row, and flushed into the row when this turn's assistant row is
    /// created (`message.start`, or the first `message.delta` minting one).
    private var pendingReasoning: String?
    /// `nonisolated(unsafe)`: the event task is only ever CANCELED from
    /// `deinit` (a nonisolated context); cancel is thread-safe. All mutation
    /// (creation, nil-out) happens on the main actor.
    nonisolated(unsafe) private var eventTask: Task<Void, Never>?
    /// `nonisolated(unsafe)`: same pattern — only canceled in `deinit`.
    nonisolated(unsafe) private var statusWatcher: Task<Void, Never>?
    private var hasStarted = false
    /// Generation of the newest conversation recovery operation
    /// (t_e77c614c). Bumped when `reconnect()` / `reauthenticate()` /
    /// `recoverGap()` starts; an in-flight operation whose captured token no
    /// longer matches is STALE and its completion is dropped (the
    /// `OnboardingViewModel.beginOperation()` fencing pattern).
    @ObservationIgnored private var operationGeneration = 0
    /// Status poll cadence (short in tests; production uses the default).
    private let statusInterval: Duration
    /// Authoritative transcript history — unbounded, persisted to the cache
    /// (P2-8). The public `transcript` is a capped display window over this.
    private var allRows: [ConversationRow] = []
    /// Maximum rows kept in the in-memory display window (P2-8 retention
    /// policy). Older rows remain in the persisted authoritative history.
    private let maxDisplayRows: Int

    public init(
        session: any ConversationSessionProviding,
        cache: any CacheStoring,
        route: Route,
        sessionID: String?,
        biometrics: any AppLockBiometricAuth = NeverLockBiometricAuth(),
        statusInterval: Duration = .milliseconds(400),
        maxDisplayRows: Int = 200
    ) {
        self.session = session
        self.cache = cache
        self.route = route
        self.sessionID = sessionID
        self.biometrics = biometrics
        self.statusInterval = statusInterval
        self.maxDisplayRows = maxDisplayRows
    }

    /// P2-3: when the VM is permanently released (the conversation screen is
    /// popped for good), stop the one-time event subscription so its task does
    /// not linger holding the session. Temporary disappearances do NOT reach
    /// here — the VM survives push/pop, so the live event stream is retained
    /// (single-subscriber: it cannot be re-created after cancellation).
    deinit {
        eventTask?.cancel()
        statusWatcher?.cancel()
    }

    // MARK: Lifecycle

    /// Connect → open the session (resume existing or create new) → subscribe
    /// to streamed events → hydrate persisted history for cold-start.
    /// Idempotent: repeated calls while already live are no-ops; a failed
    /// initial open can be retried (P1-5).
    ///
    /// P2-3: one-time init (hasStarted + cold-start hydrate + the event
    /// subscription) is separate from the RESTARTABLE status watcher. The
    /// client's `events` is a single-subscriber `AsyncStream` that cannot be
    /// re-iterated after its consumer is cancelled (verified empirically), so
    /// the event task is created ONCE and kept alive for the VM's lifetime —
    /// `teardown()` never cancels it. A re-appear after a temporary
    /// disappearance therefore only needs to restart the status watcher; the
    /// live event subscription is untouched, so the screen is never left
    /// without monitoring.
    public func start() async {
        if !hasStarted {
            hasStarted = true
            // M10 cold-start: render persisted history immediately while the
            // socket opens, so an offline/relaunch shows the last transcript.
            if let sessionID, transcript.isEmpty {
                await hydrateFromCache(sessionID: sessionID)
            }
        }
        // If a session is already open, this is a re-appear after a temporary
        // disappearance: the connection + session + event subscription are
        // still valid. Restart the RESTARTABLE status watcher (P2-3); do NOT
        // re-create the event task — the stream cannot be re-iterated, and
        // cancelling it would leave the screen permanently unsubscribed.
        if openedSessionID != nil {
            startStatusWatcher()
            return
        }
        guard await connectAndOpen() else { return }
        // Adopt the gateway's replay epoch on first open so a LATER reconnect
        // actually replays (M6: the engine adopts on its first call and
        // replays on the next after a reconnect). Nothing is watermarked yet,
        // so this surfaces no notice on a normal open.
        do {
            let outcomes = try await session.replay.replayAfterReconnect()
            if outcomes.contains(where: { outcome in
                switch outcome {
                case .replayed, .truncated, .epochChanged, .failed: return true
                default: return false
                }
            }) {
                replayNotice = Self.replayNotice(outcomes)
            }
        } catch {
            // Non-fatal: if the first adoption fails (e.g. transient drop
            // during open), the next reconnect will retry it.
        }
    }

    /// Connect the socket, then ensure the session is open and the event +
    /// status subscriptions are live. Returns true only when a session is open
    /// AND subscriptions exist — `.ready` is NEVER set without them (P1-5).
    /// Shared by `start()` (initial open) and `reconnect()`/`reauthenticate()`
    /// (recovery), so an initially-failed-open conversation recovers to a
    /// WORKING composer instead of an enabled-but-dead one.
    private func connectAndOpen() async -> Bool {
        phase = .connecting
        do {
            try await session.connect()
        } catch {
            classifyConnectFailure(error)
            return false
        }
        return await ensureOpenAndSubscribed()
    }

    /// Idempotent open + subscribe: open (create/resume) the session if none
    /// is open, and start the event + status subscriptions. Returns true only
    /// when both are live; on failure classifies and returns false.
    ///
    /// t_e77c614c: when fenced by a recovery operation's token, a superseded
    /// open never applies its session result or flips `.ready` — the newer
    /// operation owns the screen state. `nil` (initial `start()`) fences
    /// nothing, matching the pre-existing behavior.
    private func ensureOpenAndSubscribed(fencedBy token: Int? = nil) async -> Bool {
        if openedSessionID == nil {
            phase = .opening
            do {
                if let sessionID {
                    // t_8401d3c3: declare the client's last applied event id on
                    // every (re)subscribe so the resume point travels with the
                    // subscription itself.
                    let resumed = try await session.conversation.resumeSession(
                        sessionID: sessionID,
                        lastEventID: lastAppliedEventID
                    )
                    guard isCurrent(token) else { return false }
                    openedSessionID = resumed.sessionID
                    applyOpenedSession(resumed)
                } else {
                    let created = try await session.conversation.createSession(
                        title: nil,
                        profile: route.profileSlug.rawValue,
                        model: nil,
                        provider: nil,
                        cols: nil
                    )
                    guard isCurrent(token) else { return false }
                    openedSessionID = created.sessionID
                    applyOpenedSession(created)
                }
            } catch {
                guard isCurrent(token) else { return false }
                classifyOpenFailure(error)
                return false
            }
        }
        startEventSubscription()
        startStatusWatcher()
        phase = .ready
        return true
    }

    /// t_e77c614c — whether `token` still names the newest operation. A `nil`
    /// token (unfenced caller, e.g. the initial `start()`) is always current.
    private func isCurrent(_ token: Int?) -> Bool {
        guard let token else { return true }
        return token == operationGeneration
    }

    // MARK: Operation fencing (t_e77c614c)

    /// Begins a tracked async recovery operation and returns its generation
    /// token used to fence settlement against newer overlapping operations.
    /// Mirrors `OnboardingViewModel.beginOperation()`.
    private func beginOperation() -> Int {
        operationGeneration += 1
        return operationGeneration
    }

    /// Explicit user action: reconnect after a transient drop, then run the M6
    /// replay hydration. The UI calls this from the reconnect banner.
    ///
    /// P1-5: a reconnect after an INITIAL connect/open failure must actually
    /// (re)open the session + (re)start subscriptions before it can be called
    /// ready — never set `.ready` with no session and a dead composer. When a
    /// session IS already open (mid-stream drop), it is left as-is: reconnect
    /// + replay only (the live event/status tasks keep running).
    ///
    /// t_e77c614c: generation-fenced — a superseded recovery (user retapped
    /// reconnect, or re-auth started while a reconnect was in flight) never
    /// settles observable state; its stale completion is silently dropped.
    public func reconnect() async {
        let token = beginOperation()
        phase = .reconnecting
        do {
            try await session.connect()
        } catch {
            guard token == operationGeneration else { return }
            phase = .disconnected
            errorMessage = Self.nonSecret(error)
            return
        }
        if openedSessionID == nil {
            // Initial connect/open failure recovery (P1-5): the session was
            // never opened and subscriptions never started — open + subscribe
            // before the connection can be called ready.
            guard await ensureOpenAndSubscribed(fencedBy: token) else { return }
        }
        await runReplayHydration(fencedBy: token)
        guard token == operationGeneration else { return }
        phase = .ready
    }

    /// Explicit user action after a 4401 close (M11 — NEVER silent retry).
    /// Re-authenticates with a fresh ticket, then replays hydration.
    ///
    /// t_e77c614c: generation-fenced (same semantics as `reconnect()`).
    public func reauthenticate() async {
        let token = beginOperation()
        phase = .reconnecting
        do {
            try await session.reauthenticate()
        } catch {
            guard token == operationGeneration else { return }
            phase = .authRequired
            errorMessage = Self.nonSecret(error)
            return
        }
        if openedSessionID == nil {
            guard await ensureOpenAndSubscribed(fencedBy: token) else { return }
        }
        await runReplayHydration(fencedBy: token)
        guard token == operationGeneration else { return }
        phase = .ready
    }

    /// Submit a prompt. Requires an open session and no in-flight turn.
    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let sid = openedSessionID,
              !isStreaming,
              phase == .ready || phase == .streaming else { return }

        appendRow(.init(id: nextRowID(), kind: .user, text: trimmed))
        do {
            let submission = try await session.conversation.submitPrompt(sessionID: sid, text: trimmed)
            guard submission.isStreaming else {
                phase = .ready
                return
            }
        } catch {
            classifyTurnFailure(error)
        }
    }

    /// Interrupt a running turn (session.interrupt).
    public func interrupt() async {
        guard let sid = openedSessionID, isStreaming else { return }
        do {
            let result = try await session.conversation.interrupt(sessionID: sid)
            if result.isInterrupted {
                finalizeStreamingRow()
                isStreaming = false
                phase = .ready
                await persistTranscript()
            }
        } catch {
            classifyTurnFailure(error)
        }
    }

    /// Cancel background tasks (view disappear). Idempotent.
    ///
    /// P2-3: cancels ONLY the RESTARTABLE status watcher. The event
    /// subscription is one-time (single-subscriber `AsyncStream` — cannot be
    /// re-created after cancellation), so it is left running and dies with the
    /// VM; a re-appear restarts the status watcher via `start()`.
    public func teardown() {
        statusWatcher?.cancel()
        statusWatcher = nil
    }

    // MARK: Cold-start hydration (M10)

    private func hydrateFromCache(sessionID: String) async {
        guard let cached = try? await cache.loadHistory(sessionID: sessionID, for: route.gatewayID),
              !cached.messages.isEmpty else { return }
        allRows = cached.messages.map { Self.row(from: $0, id: nextRowID()) }
        hydratedFromCache = true
        phase = .ready
    }

    /// Replace the cache-hydrated transcript with the authoritative session
    /// projection returned by create/resume (when non-empty).
    private func applyOpenedSession(_ opened: ConversationSession) {
        if !opened.messages.isEmpty {
            allRows = opened.messages.map { Self.row(from: $0, id: nextRowID()) }
            hydratedFromCache = false
        }
        sessionTitle = opened.profileName
        if let model = opened.model, let provider = opened.provider {
            sessionModel = "\(model) · \(provider)"
        } else if let model = opened.model {
            sessionModel = model
        }
        // R9-T1: the session is open — build the approval banner VM bound to
        // this runtime session id, over the session's approvals seam (nil on
        // sessions without one → the banner surface simply never appears).
        // One cast at build time (see ApprovalsCapable: a same-named
        // extension property recurses through swift_dynamicCast).
        if approvalViewModel == nil {
            if let capable = session as? ApprovalsCapable {
                let vm = ApprovalViewModel(
                    approvals: capable.approvals,
                    biometrics: biometrics,
                    initialYolo: nil
                )
                vm.bind(sessionID: opened.sessionID)
                approvalViewModel = vm
            }
        } else {
            approvalViewModel?.bind(sessionID: opened.sessionID)
        }
        Task { await persistTranscript() }
    }

    // MARK: Event subscription (M5 streaming render)

    private func startEventSubscription() {
        eventTask?.cancel()
        // P2-3: the conversation client's `events` is a SINGLE-SUBSCRIBER
        // AsyncStream — once this task is cancelled, the stream cannot be
        // re-iterated to receive new events (verified empirically). So the
        // event subscription is created ONCE and kept alive for the VM's
        // lifetime; `teardown()` never cancels it. The task holds the VM
        // WEAKLY (per-iteration check, not a strong `guard let self` spanning
        // the whole loop), so it dies naturally with the VM — no leak — and
        // the stream continues to be consumed while the view is temporarily
        // off-screen (no missed events, no dropped reconnect/auth monitoring).
        eventTask = Task { [weak self] in
            guard let session = self?.session else { return }
            let events = session.conversation.events
            for await event in events {
                guard let self, !Task.isCancelled else { break }
                await self.apply(event)
            }
        }
    }

    @MainActor
    private func apply(_ event: ConversationEvent) {
        // Only render events for THIS session (the transport may carry other
        // sessions' events on the same gateway).
        if let sid = event.sessionID, sid != openedSessionID { return }

        // t_8401d3c3 — Last-Event-ID continuity gate: classify the inbound
        // event against the client's own last APPLIED event id before
        // rendering anything. This is the client-side no-gap validation that
        // composes with (not replaces) the transport watermark / RT1
        // replay-hold: it sees exactly what reaches the transcript.
        switch classifyContinuity(event) {
        case .duplicate:
            // Already applied (replayed overlap / duplicate frame) — drop.
            // This is what makes RT1's injected replay batches and the live
            // tail compose without double renders.
            return
        case .gap(let after, let before):
            // Events after `after` and before `before` were never applied.
            // Recover them via targeted last-event-id replay; if the ring no
            // longer holds them, surface the loss explicitly (never silent).
            Task { await recoverGap(after: after, before: before, triggering: event) }
            // Do NOT apply the triggering event yet — recovery re-applies it
            // in order (it will be contiguous then). If recovery fails, the
            // unrecoverable path refetches authoritative history instead.
            return
        case .contiguous, .unknown:
            break
        }

        applyRendered(event)
    }

    /// Continuity classification for one inbound event (t_8401d3c3).
    /// Unstamped events (no seq) and pre-cursor events are `.unknown` — they
    /// apply unconditionally, matching the pre-gate behavior for fixtures
    /// and session-less events; a stamped event after the first establishes
    /// the cursor.
    @MainActor
    private func classifyContinuity(_ event: ConversationEvent) -> EventContinuity {
        guard let sid = event.sessionID, sid == openedSessionID,
              let eventSeq = event.seq else { return .unknown }
        guard let cursor = lastAppliedEventID else {
            return .unknown // first stamped event — establishes the cursor
        }
        if eventSeq <= cursor { return .duplicate }
        if eventSeq == cursor + 1 { return .contiguous }
        return .gap(after: cursor, before: eventSeq)
    }

    /// Apply one event to the transcript and advance the last-applied cursor.
    @MainActor
    private func applyRendered(_ event: ConversationEvent) {
        if let seq = event.seq, event.sessionID == openedSessionID {
            lastAppliedEventID = max(lastAppliedEventID ?? 0, seq)
        }
        render(event)
    }

    /// t_8401d3c3 — gap recovery: fetch the missed tail from the gateway's
    /// replay ring starting at the client's cursor (`session.events.since`),
    /// re-apply it in order, then let the live tail resume contiguously.
    /// Unrecoverable gaps (ring evicted / replay failed) surface an explicit
    /// integrity notice and refetch authoritative history — never silent loss.
    ///
    /// t_e77c614c: generation-fenced — the recovery captures the CURRENT
    /// generation at start (without bumping), so a reconnect / re-auth that
    /// starts while the replay fetch is in flight supersedes it; the stale
    /// recovery never re-applies events, surfaces a notice, or overwrites the
    /// transcript. It deliberately does NOT bump the counter: a background
    /// recovery must never supersede a user recovery (that would drop the
    /// reconnect's `phase = .ready` settlement and strand the screen in
    /// `.reconnecting`).
    private func recoverGap(after: Int, before: Int, triggering: ConversationEvent) async {
        let token = operationGeneration
        guard let sid = openedSessionID else { return }
        do {
            let missed = try await session.conversation.resumeEvents(since: after, sessionID: sid)
            guard isCurrent(token) else { return }
            // Re-apply in seq order, cursor-gated: replayed overlap drops,
            // the missed events + triggering event apply contiguously.
            for event in missed {
                await apply(event)
            }
            // The triggering event was fetched too (seq < before ⇒ replayed);
            // if the ring somehow omitted it, apply it now so the live tail
            // stays contiguous.
            if let tseq = triggering.seq, (lastAppliedEventID ?? 0) < tseq {
                applyRendered(triggering)
            }
            integrityNotice = "Stream gap recovered — \(before - after - 1) missed event\(before - after - 1 == 1 ? "" : "s") replayed."
        } catch ConversationError.gapUnrecoverable(let gsid, let gAfter) {
            guard isCurrent(token) else { return }
            integrityNotice = "Some events after #\(gAfter) are no longer retained — reloading full history."
            await refetchAuthoritativeHistory(sessionID: gsid, fencedBy: token)
        } catch {
            guard isCurrent(token) else { return }
            // Replay attempt failed (transport-level): surface it explicitly
            // and rehydrate from history rather than rendering a hole.
            integrityNotice = "Stream gap could not be recovered — reloading full history."
            await refetchAuthoritativeHistory(sessionID: sid, fencedBy: token)
        }
    }

    /// Authoritative transcript refetch (already the M6 truncation path).
    ///
    /// t_e77c614c: when fenced, a superseded refetch (a newer reconnect /
    /// re-auth / gap recovery already refetched or owns the screen) never
    /// replaces the transcript. `nil` keeps the pre-existing unconditional
    /// behavior for unfenced callers.
    private func refetchAuthoritativeHistory(sessionID: String, fencedBy token: Int? = nil) async {
        guard let history = try? await session.history.fetchSessionHistory(sessionID: sessionID) else {
            return
        }
        guard isCurrent(token) else { return }
        allRows = history.messages.map { Self.row(from: $0, id: nextRowID()) }
        hydratedFromCache = false
        // History is snapshot-authoritative, not event-id tagged: drop the
        // cursor so the next stamped live event re-establishes continuity
        // from the freshest server state instead of false-gap-firing against
        // a stale cursor.
        lastAppliedEventID = nil
        Task { await persistTranscript() }
    }

    /// The transcript-mutating rendering switch (the former `apply` body).
    private func render(_ event: ConversationEvent) {
        switch event {
        case .messageStart:
            appendRow(.init(id: nextRowID(), kind: .assistant, text: "", isStreaming: true))
            flushPendingReasoning()
            isStreaming = true
            phase = .streaming

        case .messageDelta(_, let text, _, _):
            appendToAssistant(text)
            if !isStreaming {
                isStreaming = true
                phase = .streaming
            }

        case .messageInterim(_, let text, let alreadyStreamed, _):
            if !alreadyStreamed {
                appendToAssistant(text)
            }

        case .messageComplete(_, let text, let status, let error, _):
            let isError = status == "error" || error != nil
            if let idx = lastAssistantIndex {
                allRows[idx].text = text.isEmpty ? allRows[idx].text : text
                allRows[idx].isStreaming = false
                allRows[idx].isFailed = isError
            }
            isStreaming = false
            phase = .ready
            // P0-8: a completed turn must not carry buffered reasoning into
            // the next one (e.g. an errored turn that never minted a row).
            pendingReasoning = nil
            if isError, let error {
                errorMessage = error
            }
            Task { await persistTranscript() }

        case .thinkingDelta(_, let text, _),
             .reasoningDelta(_, let text, _),
             .reasoningAvailable(_, let text, _):
            appendThinking(text)

        case .statusUpdate(_, let kind, let text, _):
            appendRow(.init(id: nextRowID(), kind: .status, text: text, detail: kind))

        case .toolStart(_, _, let name, let context, _, _):
            // P0-8: on the live wire `tool.generating` can arrive BEFORE
            // `tool.start` (probe seq 66 vs 68) and mints a placeholder tool
            // row via updateLastTool. Adopt that row instead of appending a
            // second one — tool names must render as a single chip, never
            // duplicated inline. (Search scoped to the current turn, matching
            // updateLastTool's geometry.)
            let lowerBound = (lastAssistantIndex ?? -1) + 1
            if let idx = allRows[lowerBound...].lastIndex(where: { $0.kind == .tool && $0.text == name }) {
                if let context, !context.isEmpty {
                    allRows[idx].detail = context
                }
            } else {
                appendRow(.init(id: nextRowID(), kind: .tool, text: name, detail: context))
            }

        case .toolGenerating(_, let name, _):
            updateLastTool(name, generating: true)

        case .toolProgress(_, _, let name, let text, _):
            if let name {
                updateLastTool(name, generating: true, progress: text)
            }

        case .toolComplete(_, _, let name, let summary, _):
            updateLastTool(name, generating: false, progress: summary)

        case .backgroundComplete(_, _, let text, _):
            appendRow(.init(id: nextRowID(), kind: .system, text: text ?? "Background task complete"))

        case .sessionInfo(_, let model, let provider, let title, _, _, let yolo, let approvalMode, _):
            if let model, let provider {
                sessionModel = "\(model) · \(provider)"
            } else if let model {
                sessionModel = model
            }
            sessionTitle = title ?? sessionTitle
            // R9-T3: adopt the approval-bypass readback (effective OR of
            // config mode / env / session flag — server.py:7758).
            approvalViewModel?.applySessionInfo(yolo: yolo, approvalMode: approvalMode)

        case .approvalRequested(let sid, let requestID, let command, let detail, let choices, _):
            // R9-T1: surface the blocked dangerous command in the banner.
            // The session filter above already dropped other sessions'
            // approvals; the redaction pass lives in the approval VM.
            approvalViewModel?.handleApprovalRequest(
                ApprovalRequest(
                    requestID: requestID,
                    sessionID: sid,
                    command: command,
                    detail: detail,
                    choices: choices
                )
            )

        case .error(_, let message, _):
            appendRow(.init(id: nextRowID(), kind: .error, text: message, isFailed: true))
            isStreaming = false
            phase = .ready
            errorMessage = message

        case .unknown(_, let rawType, _):
            appendRow(.init(id: nextRowID(), kind: .system, text: "Unknown event: \(rawType)"))
        }
    }

    // MARK: Status watcher — detect mid-stream drop / 4401

    private func startStatusWatcher() {
        statusWatcher?.cancel()
        statusWatcher = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.statusInterval)
                guard !Task.isCancelled else { break }
                // t_a07ca37e: heartbeat-freshness gate — a transport whose
                // last valid frame arrived <12s ago is PROVABLY alive, so the
                // status poll is skipped entirely (Hermex #227: skip status
                // polls while transport-fresh). Nil liveness (test doubles /
                // preview connections) keeps the previous behavior.
                if let snapshot = self.session.liveness,
                   snapshot.tier(toolInFlight: self.isStreaming) == .fresh {
                    continue
                }
                let status = self.session.status
                await self.handleStatusChange(status)
            }
        }
    }

    @MainActor
    private func handleStatusChange(_ status: GatewayStatus) {
        switch status {
        case .offline, .unsupported:
            if phase == .streaming || phase == .ready {
                finalizeStreamingRow()
                isStreaming = false
                phase = .disconnected
                errorMessage = nil
            }
        case .authenticationRequired:
            // M11: 4401 → surface re-auth UX, NEVER a silent retry.
            if phase == .streaming || phase == .ready {
                finalizeStreamingRow()
                isStreaming = false
            }
            phase = .authRequired
            errorMessage = "Authentication required — re-authenticate to continue."
        case .online, .degraded, .connecting:
            break
        }
    }

    // MARK: Replay hydration (M6)

    /// t_e77c614c: when fenced by a recovery token, a superseded hydration
    /// (a newer reconnect / re-auth owns the screen) never surfaces its
    /// notice, refetches history, or settles state.
    private func runReplayHydration(fencedBy token: Int) async {
        do {
            let outcomes = try await session.replay.replayAfterReconnect()
            guard isCurrent(token) else { return }
            replayNotice = Self.replayNotice(outcomes)
            // If the epoch changed or replay was truncated, the authoritative
            // transcript must be refetched (spec §9.5/§9.6). All three paths
            // route through refetchAuthoritativeHistory so the conversation
            // cursor is DROPPED with the snapshot (t_8401d3c3 round 1): the
            // gateway's per-session seq is in-memory, so after a process
            // restart (epoch change) live events restart at seq 1 while the
            // client may hold a high-watermark cursor — a kept cursor would
            // classify the entire next turn as duplicates and drop it
            // silently (the exact loss this card forbids).
            for outcome in outcomes {
                switch outcome {
                case .truncated(let sid), .failed(let sid, _):
                    await refetchAuthoritativeHistory(sessionID: sid, fencedBy: token)
                case .epochChanged:
                    if let sid = openedSessionID {
                        await refetchAuthoritativeHistory(sessionID: sid, fencedBy: token)
                    }
                default:
                    break
                }
            }
        } catch {
            guard isCurrent(token) else { return }
            replayNotice = "Replay unavailable after reconnect."
        }
    }

    // MARK: Transcript mutation helpers

    private var lastAssistantIndex: Int? {
        allRows.lastIndex { $0.kind == .assistant }
    }

    private func appendToAssistant(_ text: String) {
        if let idx = lastAssistantIndex {
            allRows[idx].text += text
            allRows[idx].isStreaming = true
        } else {
            appendRow(.init(id: nextRowID(), kind: .assistant, text: text, isStreaming: true))
            flushPendingReasoning()
        }
    }

    /// P0-8: reasoning/thinking text accumulates in `pendingReasoning` until
    /// THIS turn's assistant row exists. It is never appended to a previous,
    /// completed assistant row — that leaked the previous turn's reasoning
    /// into the new turn's bubble (and, across a resume, foreign session
    /// content into the transcript).
    private func appendThinking(_ text: String) {
        if lastAssistantIndex != nil, isStreaming {
            allRows[lastAssistantIndex!].detail = (allRows[lastAssistantIndex!].detail ?? "") + text
        } else {
            pendingReasoning = (pendingReasoning ?? "") + text
        }
    }

    /// Attach any buffered pre-start reasoning to the freshly created
    /// assistant row and clear the buffer.
    private func flushPendingReasoning() {
        guard let buffered = pendingReasoning, !buffered.isEmpty else { return }
        pendingReasoning = nil
        if let idx = lastAssistantIndex {
            allRows[idx].detail = (allRows[idx].detail ?? "") + buffered
        }
    }

    private func finalizeStreamingRow() {
        guard let idx = lastAssistantIndex else { return }
        allRows[idx].isStreaming = false
    }

    private func updateLastTool(_ name: String, generating: Bool, progress: String? = nil) {
        // P0-8: match within the CURRENT turn only. A turn's tool rows arrive
        // AFTER the previous assistant reply (user → reasoning → tools →
        // message.start), so the search range starts past the last assistant
        // row; before any assistant row exists, the whole transcript is the
        // current turn. Without this, a repeated tool name in a later turn
        // resurrected a finished chip in an earlier one.
        let lowerBound = (lastAssistantIndex ?? -1) + 1
        if let idx = allRows[lowerBound...].lastIndex(where: { $0.kind == .tool && $0.text == name }) {
            if let progress, !progress.isEmpty {
                allRows[idx].detail = progress
            } else {
                allRows[idx].detail = generating ? "Generating…" : allRows[idx].detail
            }
        } else {
            appendRow(.init(id: nextRowID(), kind: .tool, text: name, detail: generating ? "Generating…" : nil))
        }
    }

    private func appendRow(_ row: ConversationRow) {
        allRows.append(row)
    }

    private func nextRowID() -> String {
        rowCounter += 1
        return "row-\(rowCounter)"
    }

    // MARK: Persistence (M10 — cold-start history)

    private func persistTranscript() async {
        guard let sid = openedSessionID else { return }
        // P2-8: persist the AUTHORITATIVE history (`allRows`), never the capped
        // display window — so retention never loses history from the cache.
        let messages = allRows.compactMap { Self.sessionMessage(from: $0) }
        try? await cache.saveHistory(
            SessionHistory(sessionID: sid, count: messages.count, messages: messages),
            for: route.gatewayID
        )
    }

    // MARK: Failure classification

    private func classifyConnectFailure(_ error: any Error) {
        switch error {
        case let connectivity as GatewayConnectivityError:
            switch connectivity {
            case .authenticationRequired:
                phase = .authRequired
                errorMessage = "Authentication required — re-authenticate to continue."
            default:
                phase = .failed(Self.nonSecret(error))
            }
        default:
            phase = .failed(Self.nonSecret(error))
        }
    }

    private func classifyOpenFailure(_ error: any Error) {
        switch error {
        case let conversation as ConversationError:
            switch conversation {
            case .sessionNotFound(let detail):
                phase = .failed("Session not found: \(detail). Start a new conversation.")
            default:
                phase = .failed(Self.nonSecret(error))
            }
        default:
            phase = .failed(Self.nonSecret(error))
        }
    }

    private func classifyTurnFailure(_ error: any Error) {
        switch error {
        case let conversation as ConversationError:
            if case .sessionNotFound(let detail) = conversation {
                phase = .failed("Session not found: \(detail). Start a new conversation.")
            } else {
                errorMessage = Self.nonSecret(error)
                phase = .ready
            }
        default:
            errorMessage = Self.nonSecret(error)
            phase = .ready
        }
    }

    // MARK: Static mapping helpers

    /// Map a persisted `SessionMessage` (history projection) onto a rendered row.
    static func row(from message: SessionMessage, id: String) -> ConversationRow {
        switch message.role {
        case .user:
            return .init(id: id, kind: .user, text: message.text, timestamp: message.timestamp)
        case .assistant:
            return .init(id: id, kind: .assistant, text: message.text, detail: message.reasoning, timestamp: message.timestamp)
        case .tool:
            return .init(id: id, kind: .tool, text: message.toolName ?? message.text, detail: message.toolContext, timestamp: message.timestamp)
        case .system:
            return .init(id: id, kind: .system, text: message.text, timestamp: message.timestamp)
        case .unknown:
            return .init(id: id, kind: .system, text: message.text, timestamp: message.timestamp)
        }
    }

    /// Reverse-map a rendered row onto a persisted `SessionMessage` (M10).
    /// U6: the display-only timestamp round-trips so a cached transcript keeps
    /// its stamped times across re-persists (rows without one stay unstamped).
    static func sessionMessage(from row: ConversationRow) -> SessionMessage? {
        switch row.kind {
        case .user:
            return .init(role: .user, text: row.text, timestamp: row.timestamp)
        case .assistant:
            return .init(role: .assistant, text: row.text, timestamp: row.timestamp, reasoning: row.detail)
        case .tool:
            return .init(role: .tool, text: row.text, timestamp: row.timestamp, toolName: row.text, toolContext: row.detail)
        case .status, .system:
            return .init(role: .system, text: row.text, timestamp: row.timestamp, toolName: row.detail)
        case .error:
            return nil // errors are transient UI state, not persisted history
        }
    }

    static func nonSecret(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
    }

    /// Human-readable replay hydration notice (non-secret; spec §30 answers
    /// "what happened" without leaking credentials).
    static func replayNotice(_ outcomes: [ReplayOutcome]) -> String {
        guard !outcomes.isEmpty else { return "Reconnected." }
        let parts = outcomes.map { outcome -> String in
            switch outcome {
            case .replayed(_, let count):
                return "replayed \(count) missed event\(count == 1 ? "" : "s")"
            case .truncated:
                return "history refreshed"
            case .epochChanged:
                return "gateway restarted — history refreshed"
            case .failed(_, let detail):
                return "replay failed: \(detail)"
            case .nothingToReplay:
                return "nothing new"
            }
        }
        return "Reconnected · " + parts.joined(separator: ", ")
    }
}

// MARK: - R9-T1 default biometric seam

/// Default `AppLockBiometricAuth` when the composition root injects none:
/// treats every evaluation as failed — the approval banner's APPROVE path
/// fails CLOSED (the command stays blocked) instead of crashing or silently
/// approving. Production injects the real `LocalAuthenticationBiometricAuth`
/// (or the scripted H1 provider in DEBUG).
public struct NeverLockBiometricAuth: AppLockBiometricAuth {
    public init() {}

    public func canEvaluateBiometrics() -> Bool { false }

    public func evaluateBiometrics(reason: String) async -> AppLockAuthResult {
        .unavailable
    }

    public func evaluateDevicePasscode(reason: String) async -> Bool { false }
}
