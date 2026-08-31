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
    public var isStreaming: Bool
    public var isFailed: Bool

    public init(
        id: String,
        kind: Kind,
        text: String,
        detail: String? = nil,
        isStreaming: Bool = false,
        isFailed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.isStreaming = isStreaming
        self.isFailed = isFailed
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

    // MARK: Observable state (SwiftUI renders these)

    public private(set) var phase: Phase = .idle
    public private(set) var transcript: [ConversationRow] = []
    public private(set) var isStreaming = false
    /// Non-secret replay hydration notice shown after a reconnect (M6).
    public private(set) var replayNotice: String?
    /// Non-secret error / auth surface text.
    public private(set) var errorMessage: String?
    /// True when the current transcript was hydrated from the persisted cache
    /// (M10 cold-start) rather than a live server fetch.
    public private(set) var hydratedFromCache = false
    /// Best-effort session metadata from session.info.
    public private(set) var sessionTitle: String?
    public private(set) var sessionModel: String?

    // MARK: Internal state

    private var openedSessionID: String?
    private var rowCounter = 0
    private var eventTask: Task<Void, Never>?
    private var statusWatcher: Task<Void, Never>?
    private var hasStarted = false
    /// Status poll cadence (short in tests; production uses the default).
    private let statusInterval: Duration

    public init(
        session: any ConversationSessionProviding,
        cache: any CacheStoring,
        route: Route,
        sessionID: String?,
        statusInterval: Duration = .milliseconds(400)
    ) {
        self.session = session
        self.cache = cache
        self.route = route
        self.sessionID = sessionID
        self.statusInterval = statusInterval
    }

    // MARK: Lifecycle

    /// Connect → open the session (resume existing or create new) → subscribe
    /// to streamed events → hydrate persisted history for cold-start.
    /// Idempotent: repeated calls while already live are no-ops; a failed
    /// initial open can be retried (P1-5).
    public func start() async {
        if !hasStarted {
            hasStarted = true
            // M10 cold-start: render persisted history immediately while the
            // socket opens, so an offline/relaunch shows the last transcript.
            if let sessionID, transcript.isEmpty {
                await hydrateFromCache(sessionID: sessionID)
            }
        }
        // Idempotent: if a session is already open, nothing to do — a repeated
        // `.task` / view re-appear must not double-connect or clobber an open
        // session. (Cold-start hydration sets `phase = .ready` as a rendering
        // placeholder, so keying off the OPEN SESSION — not the phase — is what
        // lets a cold start still connect.)
        if openedSessionID != nil { return }
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
    private func ensureOpenAndSubscribed() async -> Bool {
        if openedSessionID == nil {
            phase = .opening
            do {
                if let sessionID {
                    let resumed = try await session.conversation.resumeSession(sessionID: sessionID)
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
                    openedSessionID = created.sessionID
                    applyOpenedSession(created)
                }
            } catch {
                classifyOpenFailure(error)
                return false
            }
        }
        startEventSubscription()
        startStatusWatcher()
        phase = .ready
        return true
    }

    /// Explicit user action: reconnect after a transient drop, then run the M6
    /// replay hydration. The UI calls this from the reconnect banner.
    ///
    /// P1-5: a reconnect after an INITIAL connect/open failure must actually
    /// (re)open the session + (re)start subscriptions before it can be called
    /// ready — never set `.ready` with no session and a dead composer. When a
    /// session IS already open (mid-stream drop), it is left as-is: reconnect
    /// + replay only (the live event/status tasks keep running).
    public func reconnect() async {
        phase = .reconnecting
        do {
            try await session.connect()
        } catch {
            phase = .disconnected
            errorMessage = Self.nonSecret(error)
            return
        }
        if openedSessionID == nil {
            // Initial connect/open failure recovery (P1-5): the session was
            // never opened and subscriptions never started — open + subscribe
            // before the connection can be called ready.
            guard await ensureOpenAndSubscribed() else { return }
        }
        await runReplayHydration()
        phase = .ready
    }

    /// Explicit user action after a 4401 close (M11 — NEVER silent retry).
    /// Re-authenticates with a fresh ticket, then replays hydration.
    public func reauthenticate() async {
        phase = .reconnecting
        do {
            try await session.reauthenticate()
        } catch {
            phase = .authRequired
            errorMessage = Self.nonSecret(error)
            return
        }
        if openedSessionID == nil {
            guard await ensureOpenAndSubscribed() else { return }
        }
        await runReplayHydration()
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
    public func teardown() {
        eventTask?.cancel()
        eventTask = nil
        statusWatcher?.cancel()
        statusWatcher = nil
    }

    // MARK: Cold-start hydration (M10)

    private func hydrateFromCache(sessionID: String) async {
        guard let cached = try? await cache.loadHistory(sessionID: sessionID, for: route.gatewayID),
              !cached.messages.isEmpty else { return }
        transcript = cached.messages.map { Self.row(from: $0, id: nextRowID()) }
        hydratedFromCache = true
        phase = .ready
    }

    /// Replace the cache-hydrated transcript with the authoritative session
    /// projection returned by create/resume (when non-empty).
    private func applyOpenedSession(_ opened: ConversationSession) {
        if !opened.messages.isEmpty {
            transcript = opened.messages.map { Self.row(from: $0, id: nextRowID()) }
            hydratedFromCache = false
        }
        sessionTitle = opened.profileName
        if let model = opened.model, let provider = opened.provider {
            sessionModel = "\(model) · \(provider)"
        } else if let model = opened.model {
            sessionModel = model
        }
        Task { await persistTranscript() }
    }

    // MARK: Event subscription (M5 streaming render)

    private func startEventSubscription() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.session.conversation.events {
                await self.apply(event)
            }
        }
    }

    @MainActor
    private func apply(_ event: ConversationEvent) {
        // Only render events for THIS session (the transport may carry other
        // sessions' events on the same gateway).
        if let sid = event.sessionID, sid != openedSessionID { return }

        switch event {
        case .messageStart:
            appendRow(.init(id: nextRowID(), kind: .assistant, text: "", isStreaming: true))
            isStreaming = true
            phase = .streaming

        case .messageDelta(_, let text, _):
            appendToAssistant(text)
            if !isStreaming {
                isStreaming = true
                phase = .streaming
            }

        case .messageInterim(_, let text, let alreadyStreamed):
            if !alreadyStreamed {
                appendToAssistant(text)
            }

        case .messageComplete(_, let text, let status, let error):
            let isError = status == "error" || error != nil
            if let idx = lastAssistantIndex {
                transcript[idx].text = text.isEmpty ? transcript[idx].text : text
                transcript[idx].isStreaming = false
                transcript[idx].isFailed = isError
            }
            isStreaming = false
            phase = .ready
            if isError, let error {
                errorMessage = error
            }
            Task { await persistTranscript() }

        case .thinkingDelta(_, let text),
             .reasoningDelta(_, let text),
             .reasoningAvailable(_, let text):
            appendThinking(text)

        case .statusUpdate(_, let kind, let text):
            appendRow(.init(id: nextRowID(), kind: .status, text: text, detail: kind))

        case .toolStart(_, _, let name, let context, _):
            appendRow(.init(id: nextRowID(), kind: .tool, text: name, detail: context))

        case .toolGenerating(_, let name):
            updateLastTool(name, generating: true)

        case .toolProgress(_, _, let name, let text):
            if let name {
                updateLastTool(name, generating: true, progress: text)
            }

        case .toolComplete(_, _, let name, let summary):
            updateLastTool(name, generating: false, progress: summary)

        case .backgroundComplete(_, _, let text):
            appendRow(.init(id: nextRowID(), kind: .system, text: text ?? "Background task complete"))

        case .sessionInfo(_, let model, let provider, let title, _, _):
            if let model, let provider {
                sessionModel = "\(model) · \(provider)"
            } else if let model {
                sessionModel = model
            }
            sessionTitle = title ?? sessionTitle

        case .error(_, let message):
            appendRow(.init(id: nextRowID(), kind: .error, text: message, isFailed: true))
            isStreaming = false
            phase = .ready
            errorMessage = message

        case .unknown(_, let rawType):
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

    private func runReplayHydration() async {
        do {
            let outcomes = try await session.replay.replayAfterReconnect()
            replayNotice = Self.replayNotice(outcomes)
            // If the epoch changed or replay was truncated, the authoritative
            // transcript must be refetched (spec §9.5/§9.6).
            for outcome in outcomes {
                switch outcome {
                case .truncated(let sid), .failed(let sid, _):
                    if let history = try? await session.history.fetchSessionHistory(sessionID: sid) {
                        transcript = history.messages.map { Self.row(from: $0, id: nextRowID()) }
                        hydratedFromCache = false
                        Task { await persistTranscript() }
                    }
                case .epochChanged:
                    if let sid = openedSessionID,
                       let history = try? await session.history.fetchSessionHistory(sessionID: sid) {
                        transcript = history.messages.map { Self.row(from: $0, id: nextRowID()) }
                        hydratedFromCache = false
                        Task { await persistTranscript() }
                    }
                default:
                    break
                }
            }
        } catch {
            replayNotice = "Replay unavailable after reconnect."
        }
    }

    // MARK: Transcript mutation helpers

    private var lastAssistantIndex: Int? {
        transcript.lastIndex { $0.kind == .assistant }
    }

    private func appendToAssistant(_ text: String) {
        if let idx = lastAssistantIndex {
            transcript[idx].text += text
            transcript[idx].isStreaming = true
        } else {
            appendRow(.init(id: nextRowID(), kind: .assistant, text: text, isStreaming: true))
        }
    }

    private func appendThinking(_ text: String) {
        if let idx = lastAssistantIndex {
            transcript[idx].detail = (transcript[idx].detail ?? "") + text
        }
    }

    private func finalizeStreamingRow() {
        guard let idx = lastAssistantIndex else { return }
        transcript[idx].isStreaming = false
    }

    private func updateLastTool(_ name: String, generating: Bool, progress: String? = nil) {
        if let idx = transcript.lastIndex(where: { $0.kind == .tool && $0.text == name }) {
            if let progress, !progress.isEmpty {
                transcript[idx].detail = progress
            } else {
                transcript[idx].detail = generating ? "Generating…" : transcript[idx].detail
            }
        } else {
            appendRow(.init(id: nextRowID(), kind: .tool, text: name, detail: generating ? "Generating…" : nil))
        }
    }

    private func appendRow(_ row: ConversationRow) {
        transcript.append(row)
    }

    private func nextRowID() -> String {
        rowCounter += 1
        return "row-\(rowCounter)"
    }

    // MARK: Persistence (M10 — cold-start history)

    private func persistTranscript() async {
        guard let sid = openedSessionID else { return }
        let messages = transcript.compactMap { Self.sessionMessage(from: $0) }
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
            return .init(id: id, kind: .user, text: message.text)
        case .assistant:
            return .init(id: id, kind: .assistant, text: message.text, detail: message.reasoning)
        case .tool:
            return .init(id: id, kind: .tool, text: message.toolName ?? message.text, detail: message.toolContext)
        case .system:
            return .init(id: id, kind: .system, text: message.text)
        case .unknown:
            return .init(id: id, kind: .system, text: message.text)
        }
    }

    /// Reverse-map a rendered row onto a persisted `SessionMessage` (M10).
    static func sessionMessage(from row: ConversationRow) -> SessionMessage? {
        switch row.kind {
        case .user:
            return .init(role: .user, text: row.text)
        case .assistant:
            return .init(role: .assistant, text: row.text, reasoning: row.detail)
        case .tool:
            return .init(role: .tool, text: row.text, toolName: row.text, toolContext: row.detail)
        case .status, .system:
            return .init(role: .system, text: row.text, toolName: row.detail)
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
