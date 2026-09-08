import XCTest
import FleetCore
import FleetNetworking
import FleetPersistence
import FleetUI

/// U3 hosted tests — the `ConversationViewModel` (FleetUI) over SCRIPTED
/// FleetCore seams: full create/resume → prompt.submit → incremental streaming
/// render → message.complete → interrupt loop, cold-start persisted history
/// (M10), replay hydration on reconnect (M6) and the 4401 re-auth UX (M11 — no
/// silent retry). Deterministic: no network, no in-process server here (that
/// suite lives in `ConversationFixtureLoopTests`). The view model depends only
/// on FleetCore seams, so the scripted session fully controls status, events
/// and replay outcomes.
@MainActor
final class ConversationViewModelTests: XCTestCase {

    // MARK: - Scripted conversation session double

    /// A controllable `ConversationSessionProviding` implementing every
    /// sub-seam directly (conversation / replay / history), with a pushable
    /// event stream and scripted connect/status/replay outcomes. All access is
    /// main-actor-confined (the tests are `@MainActor`), matching how the view
    /// model drives it.
    private final class ScriptedSession:
        ConversationSessionProviding,
        ConversationProviding,
        ReplayProviding,
        SessionHistoryProviding,
        ApprovalsCapable,
        @unchecked Sendable
    {
        let gatewayID = GatewayID(rawValue: "workstation")

        // connectivity
        var statusValue: GatewayStatus = .online
        var livenessValue: ConnectionLivenessSnapshot?
        var connectError: GatewayConnectivityError?
        var connectCount = 0
        var reauthenticateCount = 0

        // conversation
        var createResult: Result<ConversationSession, ConversationError> =
            .success(ConversationSession(sessionID: "s-1", profileName: "default"))
        var resumeResult: Result<ConversationSession, ConversationError> =
            .success(ConversationSession(sessionID: "s-1", profileName: "default"))
        var createCallCount = 0
        var resumeCallCount = 0
        var submittedTexts: [String] = []
        var submitError: ConversationError?
        var interruptError: ConversationError?

        // event stream
        private let streamPair: (AsyncStream<ConversationEvent>, AsyncStream<ConversationEvent>.Continuation)

        // replay
        var replayOutcomes: Result<[ReplayOutcome], ReplayError> = .success([.nothingToReplay])
        /// t_e77c614c — one-shot gate for holding the replay RPC in flight.
        var replayGate: OneShotGate?
        var replayCallCount = 0
        /// Incremented when a call PARKS on the gate (its scripted result is
        /// already captured) — lets tests deterministically observe that an
        /// RPC is truly held in flight.
        var replayParkedCount = 0

        // history
        var historyResult: Result<SessionHistory, SessionHistoryError> =
            .success(SessionHistory(sessionID: "s-1", count: 0, messages: []))
        /// t_e77c614c — one-shot gate: when armed, the FIRST history fetch
        /// suspends until `open()` (subsequent fetches pass through). Lets a
        /// test hold one in-flight refetch while a newer operation runs.
        var historyGate: OneShotGate?
        var historyCallCount = 0
        /// Incremented when a fetch PARKS on the gate — deterministic
        /// in-flight observation (see replayParkedCount).
        var historyParkedCount = 0

        init() {
            self.streamPair = AsyncStream.makeStream()
        }

        // MARK: GatewayConnectivityProviding
        var status: GatewayStatus { statusValue }
        var liveness: ConnectionLivenessSnapshot? { livenessValue }
        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "epoch-1", heartbeatEnabled: true, changeEventsEnabled: true)
        }
        func connect() async throws {
            connectCount += 1
            if let connectError { throw connectError }
        }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "MacBook")
        }

        // MARK: ConversationSessionProviding
        var conversation: any ConversationProviding { self }
        var replay: any ReplayProviding { self }
        var history: any SessionHistoryProviding { self }
        // MARK: ApprovalsCapable (R9-T1 rework: approval.pending restore)
        var approvals: any ApprovalsProviding { approvalsBox }
        let approvalsBox = ScriptedPendingApprovals()
        func reauthenticate() async throws {
            reauthenticateCount += 1
            if let connectError { throw connectError }
        }

        // MARK: ConversationProviding
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            createCallCount += 1
            return try createResult.get()
        }
        func resumeSession(sessionID: String, lastEventID: Int? = nil) async throws -> ConversationSession {
            resumeCallCount += 1
            return try resumeResult.get()
        }
        /// t_8401d3c3 — captured gap-recovery requests + scripted responses.
        var resumeEventsResult: Result<[ConversationEvent], ConversationError> = .success([])
        var resumeEventsRequests: [(lastEventID: Int, sessionID: String)] = []
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] {
            resumeEventsRequests.append((lastEventID, sessionID))
            return try resumeEventsResult.get()
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
            submittedTexts.append(text)
            if let submitError { throw submitError }
            return PromptSubmission(status: "streaming")
        }
        func interrupt(sessionID: String) async throws -> InterruptResult {
            if let interruptError { throw interruptError }
            return InterruptResult(status: "interrupted")
        }
        var events: AsyncStream<ConversationEvent> { streamPair.0 }

        // MARK: ReplayProviding
        func watermarks() async -> [SessionEventWatermark] { [] }
        func replayAfterReconnect() async throws -> [ReplayOutcome] {
            replayCallCount += 1
            // Capture the scripted result at CALL time: a gated (in-flight)
            // RPC must return the state it was issued against, not whatever
            // the test scripted later — otherwise stale-result tests can't
            // distinguish stale from new.
            let result = replayOutcomes
            if let replayGate {
                replayParkedCount += 1
                await replayGate.wait()
            }
            return try result.get()
        }

        // MARK: SessionHistoryProviding
        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
            historyCallCount += 1
            // Captured at CALL time — see replayAfterReconnect.
            let result = historyResult
            if let historyGate {
                historyParkedCount += 1
                await historyGate.wait()
            }
            return try result.get()
        }
        func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
            SessionStatus.parse(output: "Session ID: \(sessionID)")
        }

        // MARK: event pushing
        func push(_ event: ConversationEvent) {
            streamPair.1.yield(event)
        }
    }

    /// Let the (MainActor) event/status tasks consume yields before asserting.
    private func flush() async {
        try? await Task.sleep(for: .milliseconds(25))
    }

    /// t_e77c614c — one-shot async gate for holding a scripted call in flight.
    final class OneShotGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            opened = true
            let resumed = waiters
            waiters = []
            lock.unlock()
            resumed.forEach { $0.resume() }
        }
    }

    // MARK: - Scripted approvals double (R9-T1 rework)

    /// Thread-safe scripted `ApprovalsProviding` — the ConversationViewModel
    /// wiring test only needs `pendingApprovals` (respond/yolo fail closed).
    private final class ScriptedPendingApprovals: ApprovalsProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _pendingCalls: [String] = []
        var pendingCalls: [String] {
            lock.lock(); defer { lock.unlock() }
            return _pendingCalls
        }
        /// Delay applied inside pendingApprovals before returning, letting a
        /// test hold the restore in flight (fencing observation).
        var pendingGate: OneShotGate?
        private func recordPendingAndTakeGate(_ sessionID: String) -> OneShotGate? {
            lock.lock(); defer { lock.unlock() }
            _pendingCalls.append(sessionID)
            return pendingGate
        }

        func respond(sessionID: String, requestID: String, choice: ApprovalChoice, all: Bool) async throws -> Int {
            throw ConversationError.notConnected
        }

        func setSessionYolo(_ enabled: Bool, sessionID: String) async throws -> Bool {
            throw ConversationError.notConnected
        }

        func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] {
            let gate = recordPendingAndTakeGate(sessionID)
            if let gate { await gate.wait() }
            return [
                ApprovalRequest(
                    requestID: "req-restore-1",
                    sessionID: sessionID,
                    command: "git push --force",
                    detail: "Force push",
                    choices: ["once", "deny"]
                )
            ]
        }
    }

    // MARK: - Fixture

    private var cache: SwiftDataCacheStore!

    private func makeFixture(
        sessionID: String? = nil
    ) async throws -> (ScriptedSession, ConversationViewModel) {
        let scripted = ScriptedSession()
        cache = try SwiftDataCacheStore.makeInMemory()
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default")
        )
        let viewModel = ConversationViewModel(
            session: scripted,
            cache: cache,
            route: route,
            sessionID: sessionID,
            statusInterval: .milliseconds(10)
        )
        return (scripted, viewModel)
    }

    // MARK: - Open/create/resume

    func testStartConnectsAndCreatesSession() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: nil)
        XCTAssertEqual(viewModel.phase, .idle)

        await viewModel.start()

        XCTAssertEqual(scripted.connectCount, 1)
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.sessionTitle, "default")
    }

    /// R9-T1 rework: opening a session pulls `approval.pending` and restores
    /// a banner whose push event was missed while detached.
    func testStartRestoresPendingApprovalsAfterOpen() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: nil)

        await viewModel.start()

        XCTAssertEqual(scripted.connectCount, 1)
        XCTAssertEqual(viewModel.phase, .ready)
        // The restore rides a post-open Task — poll for it (bounded).
        for _ in 0..<200 where viewModel.approvalViewModel?.pending == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            scripted.approvalsBox.pendingCalls, ["s-1"],
            "open must pull approval.pending for the bound runtime session"
        )
        XCTAssertEqual(viewModel.approvalViewModel?.pending?.requestID, "req-restore-1")
        XCTAssertEqual(viewModel.approvalViewModel?.state, .pending)
    }

    func testStartConnectsAndResumesExistingSession() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-9")
        scripted.resumeResult = .success(ConversationSession(sessionID: "s-9", messages: [
            SessionMessage(role: .user, text: "earlier"),
        ]))

        await viewModel.start()

        XCTAssertEqual(scripted.connectCount, 1)
        XCTAssertEqual(viewModel.phase, .ready)
        // Authoritative resume messages supersede cache.
        XCTAssertEqual(viewModel.transcript.count, 1)
        XCTAssertEqual(viewModel.transcript.first?.kind, .user)
        XCTAssertEqual(viewModel.transcript.first?.text, "earlier")
    }

    func testStartConnectFailureClassifies() async throws {
        let (scripted, viewModel) = try await makeFixture()
        scripted.connectError = .unreachable

        await viewModel.start()

        XCTAssertEqual(viewModel.phase, .failed("gateway unreachable"))
    }

    // MARK: - Streaming render (M5)

    func testSendStreamsDeltasIncrementallyAndCompletes() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()

        await viewModel.send("hello")
        XCTAssertEqual(viewModel.transcript.count, 1) // user row
        XCTAssertEqual(viewModel.transcript.first?.kind, .user)
        XCTAssertEqual(viewModel.transcript.first?.text, "hello")

        // Streamed turn arrives incrementally.
        scripted.push(.messageStart(sessionID: "s-1"))
        await flush()
        XCTAssertEqual(viewModel.phase, .streaming)
        XCTAssertTrue(viewModel.isStreaming)

        scripted.push(.messageDelta(sessionID: "s-1", text: "Hel", rendered: nil))
        scripted.push(.messageDelta(sessionID: "s-1", text: "lo", rendered: nil))
        await flush()
        XCTAssertEqual(viewModel.transcript.last?.kind, .assistant)
        XCTAssertEqual(viewModel.transcript.last?.text, "Hello")
        XCTAssertTrue(viewModel.transcript.last?.isStreaming == true)

        scripted.push(.messageComplete(sessionID: "s-1", text: "Hello world", status: nil, error: nil))
        await flush()
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertEqual(viewModel.transcript.last?.text, "Hello world")
        XCTAssertFalse(viewModel.transcript.last?.isStreaming == true)
    }

    func testFailedTurnMarkedError() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()
        await viewModel.send("go")
        scripted.push(.messageStart(sessionID: "s-1"))
        scripted.push(.messageComplete(sessionID: "s-1", text: "Error: provider rejected", status: "error", error: "provider rejected"))
        await flush()

        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.transcript.last?.kind, .assistant)
        XCTAssertTrue(viewModel.transcript.last?.isFailed == true)
        XCTAssertEqual(viewModel.errorMessage, "provider rejected")
    }

    // MARK: - P0-8 event taxonomy + turn isolation

    /// P0-8 (2)/(3): live wire order is reasoning deltas FIRST, then
    /// tool.generating (seq 66) BEFORE tool.start (seq 68), then the assistant
    /// message. Reasoning must land on THIS turn's assistant row (not the
    /// previous turn's), and a tool name must render as exactly ONE row —
    /// never a duplicated chip.
    func testReasoningBeforeMessageStartAttachesToNewTurnNotPrevious() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()

        // Turn 1 completes normally.
        await viewModel.send("first")
        scripted.push(.messageStart(sessionID: "s-1"))
        scripted.push(.messageDelta(sessionID: "s-1", text: "one", rendered: nil))
        scripted.push(.messageComplete(sessionID: "s-1", text: "one", status: nil, error: nil))
        await flush()
        XCTAssertEqual(viewModel.transcript.last?.kind, .assistant)
        XCTAssertEqual(viewModel.transcript.last?.text, "one")
        XCTAssertNil(viewModel.transcript.last?.detail)

        // Turn 2: reasoning arrives BEFORE message.start (live wire order).
        await viewModel.send("second")
        scripted.push(.reasoningDelta(sessionID: "s-1", text: "thinking "))
        scripted.push(.reasoningDelta(sessionID: "s-1", text: "hard"))
        await flush()
        // No assistant row exists yet — reasoning is buffered, NOT attached to
        // turn 1's completed row.
        XCTAssertEqual(viewModel.transcript.last?.kind, .user)
        XCTAssertNil(viewModel.transcript.first { $0.kind == .assistant }?.detail)

        scripted.push(.messageStart(sessionID: "s-1"))
        scripted.push(.messageDelta(sessionID: "s-1", text: "two", rendered: nil))
        scripted.push(.messageComplete(sessionID: "s-1", text: "two", status: nil, error: nil))
        await flush()

        // Turn 2's assistant row carries the reasoning; turn 1's does not.
        let assistants = viewModel.transcript.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.count, 2)
        XCTAssertEqual(assistants[0].text, "one")
        XCTAssertNil(assistants[0].detail, "turn 1 must not inherit turn 2's reasoning")
        XCTAssertEqual(assistants[1].text, "two")
        XCTAssertEqual(assistants[1].detail, "thinking hard")
    }

    /// P0-8 (3): tool.generating arriving BEFORE tool.start must not mint a
    /// duplicate tool row — one tool name, one chip.
    func testToolGeneratingBeforeToolStartDoesNotDuplicateChip() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()

        await viewModel.send("use a tool")
        // Live wire order (probe seq 66 < 68): generating first, then start.
        scripted.push(.toolGenerating(sessionID: "s-1", name: "web_search"))
        await flush()
        scripted.push(.toolStart(sessionID: "s-1", toolID: "t1", name: "web_search", context: "query", argsText: nil))
        await flush()
        scripted.push(.messageStart(sessionID: "s-1"))
        scripted.push(.messageComplete(sessionID: "s-1", text: "done", status: nil, error: nil))
        await flush()

        let toolRows = viewModel.transcript.filter { $0.kind == .tool }
        XCTAssertEqual(toolRows.count, 1, "tool name must render as exactly one chip, got \(toolRows.count)")
        XCTAssertEqual(toolRows.first?.text, "web_search")
        XCTAssertEqual(toolRows.first?.detail, "query")
    }

    /// P0-8: a repeated tool name in a LATER turn updates that turn's chip,
    /// never resurrects the earlier turn's finished chip.
    func testRepeatedToolNameAcrossTurnsDoesNotResurrectOldChip() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()

        // Turn 1: tool + reply.
        await viewModel.send("one")
        scripted.push(.toolStart(sessionID: "s-1", toolID: "t1", name: "read_file", context: "a.swift", argsText: nil))
        scripted.push(.toolComplete(sessionID: "s-1", toolID: "t1", name: "read_file", summary: "read a.swift"))
        scripted.push(.messageStart(sessionID: "s-1"))
        scripted.push(.messageComplete(sessionID: "s-1", text: "one done", status: nil, error: nil))
        await flush()

        // Turn 2: same tool name.
        await viewModel.send("two")
        scripted.push(.toolGenerating(sessionID: "s-1", name: "read_file"))
        await flush()

        let toolRows = viewModel.transcript.filter { $0.kind == .tool }
        XCTAssertEqual(toolRows.count, 2, "each turn gets its own chip")
        XCTAssertEqual(toolRows[0].detail, "read a.swift", "turn 1's finished chip must keep its final context")
    }

    /// P0-8 (1): entering chat with sessionID nil CREATES a fresh session —
    /// the app never silently resumes the profile's most recent session.
    func testNilSessionIDCreatesFreshSessionNeverResumes() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: nil)
        await viewModel.start()
        XCTAssertEqual(scripted.createCallCount, 1, "nil sessionID must take the createSession path")
        XCTAssertEqual(scripted.resumeCallCount, 0, "nil sessionID must NEVER call resumeSession")
    }

    // MARK: - Interrupt

    func testInterruptStopsStreaming() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()
        await viewModel.send("hello")
        scripted.push(.messageStart(sessionID: "s-1"))
        scripted.push(.messageDelta(sessionID: "s-1", text: "par", rendered: nil))
        await flush()
        XCTAssertTrue(viewModel.isStreaming)

        await viewModel.interrupt()

        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.transcript.last?.text, "par")
        XCTAssertFalse(viewModel.transcript.last?.isStreaming == true)
    }

    // MARK: - Cold-start persisted history (M10)

    func testColdStartHydratesFromCache() async throws {
        // Pre-seed the cache with persisted history for the session.
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-1")
        try await cache.saveHistory(
            SessionHistory(sessionID: "s-1", count: 2, messages: [
                SessionMessage(role: .user, text: "cached question", timestamp: 1, rowID: "r1"),
                SessionMessage(role: .assistant, text: "cached answer", timestamp: 2, rowID: "r2"),
            ]),
            for: GatewayID(rawValue: "workstation")
        )
        // H1: the post-resume authoritative fetch now runs eagerly; hold it
        // with the one-shot gate so the COLD-START phase (cache rows on
        // screen, hydratedFromCache) is observed deterministically. Once
        // released, the authoritative history (same rows) settles the swap.
        let gate = OneShotGate()
        scripted.historyGate = gate
        scripted.historyResult = .success(SessionHistory(sessionID: "s-1", count: 2, messages: [
            SessionMessage(role: .user, text: "cached question", timestamp: 1, rowID: "r1"),
            SessionMessage(role: .assistant, text: "cached answer", timestamp: 2, rowID: "r2"),
        ]))

        await viewModel.start()
        await flush()

        XCTAssertTrue(viewModel.hydratedFromCache)
        XCTAssertEqual(viewModel.transcript.count, 2)
        XCTAssertEqual(viewModel.transcript.first?.text, "cached question")
        XCTAssertEqual(viewModel.transcript.last?.kind, .assistant)

        // Release the authoritative fetch: same durable rows ⇒ ids preserved.
        gate.open()
        await flush()
        XCTAssertEqual(viewModel.transcript.count, 2)
        XCTAssertFalse(viewModel.hydratedFromCache)
    }

    // MARK: - Reconnect / replay hydration (M6)

    func testReconnectRunsReplayAndShowsNotice() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()

        scripted.replayOutcomes = .success([
            .replayed(sessionID: "s-1", count: 2),
        ])
        await viewModel.reconnect()

        XCTAssertEqual(scripted.connectCount, 2)
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.replayNotice, "Reconnected · replayed 2 missed events")
    }

    func testReplayDedupeVisibleInTranscript() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()
        await viewModel.send("hello")

        // Connection 1 streams a partial turn.
        scripted.push(.messageStart(sessionID: "s-1"))
        scripted.push(.messageDelta(sessionID: "s-1", text: "Hel", rendered: nil))
        scripted.push(.messageDelta(sessionID: "s-1", text: "lo", rendered: nil))
        await flush()

        // Simulate a mid-stream drop: status flips offline → view model goes
        // disconnected and finalizes the partial row.
        scripted.statusValue = .offline
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(viewModel.phase, .disconnected)
        XCTAssertFalse(viewModel.isStreaming)

        // Reconnect: replay re-injects the missed tail, never the already
        // rendered prefix ("Hel"/"lo" must not duplicate).
        scripted.statusValue = .online
        scripted.replayOutcomes = .success([.replayed(sessionID: "s-1", count: 1)])
        await viewModel.reconnect()

        scripted.push(.messageDelta(sessionID: "s-1", text: " world", rendered: nil))
        scripted.push(.messageComplete(sessionID: "s-1", text: "Hello world", status: nil, error: nil))
        await flush()

        XCTAssertEqual(viewModel.phase, .ready)
        let assistantRows = viewModel.transcript.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantRows.count, 1, "replay must not duplicate the assistant row")
        XCTAssertEqual(assistantRows.first?.text, "Hello world")
        XCTAssertEqual(viewModel.replayNotice, "Reconnected · replayed 1 missed event")
    }

    // MARK: - P1-5 — recovery after an initial connect/open failure

    /// P1-5 regression: when the INITIAL connection fails, the reconnect must
    /// actually open a session and start subscriptions — never flip to `.ready`
    /// with a dead composer. Pre-fix, `reconnect()` only reconnected + replayed,
    /// leaving `openedSessionID` nil, so the enabled composer silently dropped
    /// every `send()`.
    func testReconnectAfterInitialConnectFailureRecoversToLiveSession() async throws {
        let (scripted, viewModel) = try await makeFixture() // sessionID nil → create
        scripted.connectError = .unreachable
        await viewModel.start()
        XCTAssertEqual(viewModel.phase, .failed("gateway unreachable"))

        // Gateway comes back; the user taps Reconnect.
        scripted.connectError = nil
        await viewModel.reconnect()

        XCTAssertEqual(viewModel.phase, .ready, "reconnect after initial failure must reach ready")
        XCTAssertEqual(scripted.connectCount, 2, "reconnect must re-drive connect")
        // The composer must be LIVE: send() must append a user row (pre-fix it
        // no-oped because no session was ever opened).
        await viewModel.send("hello")
        XCTAssertEqual(viewModel.transcript.count, 1)
        XCTAssertEqual(viewModel.transcript.first?.kind, .user)
        XCTAssertEqual(viewModel.transcript.first?.text, "hello")
        // Subscriptions must be live: a streamed turn must render.
        scripted.push(.messageStart(sessionID: "s-1"))
        await flush()
        XCTAssertEqual(viewModel.phase, .streaming, "event subscription must be live after recovery")
    }

    /// P1-5 regression: an initial OPEN failure (createSession rejected) must
    /// be retried by the reconnect — ready must not be reached with no session.
    func testReconnectAfterInitialOpenFailureReopensSession() async throws {
        let (scripted, viewModel) = try await makeFixture()
        scripted.createResult = .failure(.sessionNotFound("gone"))
        await viewModel.start()
        XCTAssertEqual(viewModel.phase, .failed("Session not found: gone. Start a new conversation."))

        scripted.createResult = .success(ConversationSession(sessionID: "s-1", profileName: "default"))
        await viewModel.reconnect()

        XCTAssertEqual(viewModel.phase, .ready, "reconnect after initial open failure must reach ready")
        await viewModel.send("retry")
        XCTAssertEqual(viewModel.transcript.count, 1)
        XCTAssertEqual(viewModel.transcript.first?.kind, .user)
        XCTAssertEqual(viewModel.transcript.first?.text, "retry")
    }

    // MARK: - 4401 re-auth UX (M11 — no silent retry)

    func test4401SurfacesAuthRequiredNoSilentRetry() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()
        XCTAssertEqual(scripted.connectCount, 1)

        // Gateway closes with 4401 → status flips to authenticationRequired.
        scripted.statusValue = .authenticationRequired
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(viewModel.phase, .authRequired)
        XCTAssertFalse(viewModel.isStreaming)
        // NO silent retry: connect was not automatically re-driven.
        XCTAssertEqual(scripted.connectCount, 1, "4401 must never silently reconnect")

        // Explicit re-authenticate drives a fresh connect + replay.
        scripted.statusValue = .online
        scripted.replayOutcomes = .success([.nothingToReplay])
        await viewModel.reauthenticate()

        XCTAssertEqual(scripted.reauthenticateCount, 1)
        XCTAssertEqual(viewModel.phase, .ready)
    }

    // MARK: - Epoch change / truncation refetch (authoritative history)

    func testReplayTruncationRefetchesHistory() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-1")
        await viewModel.start()

        scripted.replayOutcomes = .success([.truncated(sessionID: "s-1")])
        scripted.historyResult = .success(SessionHistory(sessionID: "s-1", count: 2, messages: [
            SessionMessage(role: .user, text: "authoritative q"),
            SessionMessage(role: .assistant, text: "authoritative a"),
        ]))

        await viewModel.reconnect()

        XCTAssertEqual(viewModel.transcript.count, 2)
        XCTAssertEqual(viewModel.transcript.first?.text, "authoritative q")
        XCTAssertEqual(viewModel.replayNotice, "Reconnected · history refreshed")
    }

    func testReplayEpochChangedRefetchesHistory() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-1")
        await viewModel.start()

        scripted.replayOutcomes = .success([.epochChanged(from: "epoch-1", to: "epoch-2")])
        scripted.historyResult = .success(SessionHistory(sessionID: "s-1", count: 1, messages: [
            SessionMessage(role: .assistant, text: "post-restart history"),
        ]))

        await viewModel.reconnect()

        XCTAssertEqual(viewModel.transcript.count, 1)
        XCTAssertEqual(viewModel.transcript.first?.text, "post-restart history")
        XCTAssertEqual(viewModel.replayNotice, "Reconnected · gateway restarted — history refreshed")
    }

    // MARK: - P2-3 reappear keeps live subscriptions

    /// RED (old): `teardown()` cancelled the event task, and `start()` returned
    /// early on re-appear (session already open) — so a temporary
    /// disappearance left the screen with NO live subscriptions; a pushed event
    /// was silently dropped. GREEN (fix): the event subscription is ONE-TIME
    /// (single-subscriber `AsyncStream` — cannot be re-created after
    /// cancellation) and survives teardown; re-appear restarts the status
    /// watcher. A pushed event still renders after teardown + re-appear.
    func testReappearAfterTeardownRestartsSubscriptions() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()
        XCTAssertEqual(viewModel.phase, .ready)

        // Render one event while subscriptions are live.
        scripted.push(.statusUpdate(sessionID: "s-1", kind: "info", text: "first"))
        await flush()
        XCTAssertTrue(viewModel.transcript.contains { $0.text == "first" })

        // Simulate onDisappear: cancels the restartable status watcher (the
        // one-time event subscription is intentionally retained).
        viewModel.teardown()

        // Simulate re-appear: `.task` calls start() again. The session is still
        // open; start() restarts the status watcher and the live event
        // subscription keeps flowing (P2-3).
        await viewModel.start()

        scripted.push(.statusUpdate(sessionID: "s-1", kind: "info", text: "second"))
        await flush()
        XCTAssertTrue(viewModel.transcript.contains { $0.text == "second" },
                      "P2-3: reappear after teardown must keep the event subscription live")
    }

    // MARK: - P2-8 bounded display window preserves authoritative history

    /// RED (old): `transcript` grew without bound as events streamed — after
    /// 240 status rows the array held all 240. GREEN (fix): the public
    /// transcript is a capped display window (default `maxDisplayRows = 200`)
    /// over the authoritative history, so a long session stays bounded in the
    /// UI while the full history remains persisted (cache) and rehydratable.
    /// Uses the DEFAULT window (no new API) so this test compiles + runs on the
    /// pre-fix VM too (runtime RED).
    func testTranscriptWindowIsCappedAndPreservesAuthoritativeHistory() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-1")
        await viewModel.start()

        // Stream 240 status rows — far beyond the default 200-row window.
        for i in 0..<240 {
            scripted.push(.statusUpdate(sessionID: "s-1", kind: "info", text: "row-\(i)"))
        }
        // Drain the buffered events (the event task consumes on the main actor;
        // a few 25ms flushes are enough for 240 cheap appends).
        for _ in 0..<8 {
            await flush()
            if viewModel.transcript.last?.text == "row-239" { break }
        }

        // Display window is capped at the default 200.
        XCTAssertEqual(viewModel.transcript.count, 200,
                       "P2-8: display window must be capped at maxDisplayRows (200)")
        // The NEWEST rows are the ones kept.
        XCTAssertEqual(viewModel.transcript.last?.text, "row-239",
                       "P2-8: newest rows retained at the window tail")

        // Authoritative history is preserved: persist the full transcript and
        // verify the cache holds ALL 240 rows, not just the 200-row window.
        scripted.push(.messageComplete(sessionID: "s-1", text: "done", status: "ok", error: nil))
        await flush()
        let cached = try await cache.loadHistory(sessionID: "s-1", for: GatewayID(rawValue: "workstation"))
        XCTAssertEqual(cached?.messages.count, 240,
                       "P2-8: authoritative history must survive the display cap (cache holds all rows)")
    }

    // MARK: - t_8401d3c3 — Last-Event-ID resume semantics

    /// Gap on the live stream (seq jumps 3 → 6): the missed events 4-5 are
    /// recovered via targeted `resumeEvents(since: cursor)` and the result is
    /// EXACT — every token rendered exactly once, in order, and the explicit
    /// integrity notice surfaces the recovery.
    func testLiveStreamGapRecoveredExactly() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()
        await viewModel.send("hello")

        // Stamped live prefix: seq 1-3 (start + "Hel" + "lo").
        scripted.push(.messageStart(sessionID: "s-1", seq: 1))
        scripted.push(.messageDelta(sessionID: "s-1", text: "Hel", rendered: nil, seq: 2))
        scripted.push(.messageDelta(sessionID: "s-1", text: "lo", rendered: nil, seq: 3))
        await flush()

        // The recovery tail the gateway ring will return: seq 4-5 + the
        // triggering live event 6 arrives with the gap.
        scripted.resumeEventsResult = .success([
            .messageDelta(sessionID: "s-1", text: " wo", rendered: nil, seq: 4),
            .messageDelta(sessionID: "s-1", text: "rl", rendered: nil, seq: 5),
        ])
        // Live frame jumps to seq 6 — events 4,5 were missed.
        scripted.push(.messageDelta(sessionID: "s-1", text: "d", rendered: nil, seq: 6))
        // Let the recovery task run to completion.
        for _ in 0..<50 where viewModel.integrityNotice == nil {
            await flush()
        }

        // Recovery requested from the CLIENT cursor (last applied = 3).
        XCTAssertEqual(scripted.resumeEventsRequests.count, 1)
        XCTAssertEqual(scripted.resumeEventsRequests.first?.lastEventID, 3,
                       "gap recovery must resume from the client's last applied event id")
        XCTAssertEqual(scripted.resumeEventsRequests.first?.sessionID, "s-1")

        // EXACT resumption: all six events applied, none duplicated.
        let assistant = viewModel.transcript.first { $0.kind == .assistant }
        XCTAssertEqual(assistant?.text, "Hello world",
                       "recovered tokens concatenate in order — zero lost, zero duplicated")
        XCTAssertNotNil(viewModel.integrityNotice, "recovery must be surfaced, never silent")
        XCTAssertTrue(viewModel.integrityNotice?.contains("recovered") ?? false)

        // The live tail continues contiguously after recovery.
        scripted.push(.messageComplete(sessionID: "s-1", text: "Hello world", status: nil, error: nil, seq: 7))
        await flush()
        let completed = viewModel.transcript.first { $0.kind == .assistant }
        XCTAssertEqual(completed?.text, "Hello world")
        XCTAssertEqual(viewModel.phase, .ready)
    }

    /// Duplicates after recovery (a re-delivered overlap) are dropped by the
    /// cursor gate — the RT1 replay-hold composition guarantee at the layer
    /// that renders.
    func testDuplicateEventsAfterRecoveryAreDropped() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()
        await viewModel.send("hello")

        scripted.push(.messageStart(sessionID: "s-1", seq: 1))
        scripted.push(.messageDelta(sessionID: "s-1", text: "a", rendered: nil, seq: 2))
        await flush()

        // The SAME event re-delivered (replay overlap / duplicate frame).
        scripted.push(.messageDelta(sessionID: "s-1", text: "a", rendered: nil, seq: 2))
        scripted.push(.messageComplete(sessionID: "s-1", text: "a", status: nil, error: nil, seq: 3))
        await flush()

        let assistant = viewModel.transcript.first { $0.kind == .assistant }
        XCTAssertEqual(assistant?.text, "a", "duplicate seq must not double-render")
        XCTAssertEqual(scripted.resumeEventsRequests.count, 0,
                       "duplicates are NOT gaps — no recovery request fires")
    }

    /// Unrecoverable gap (ring evicted): the explicit signal surfaces, the
    /// authoritative history is refetched, and the stale cursor is discarded
    /// — never silent loss.
    func testUnrecoverableGapSurfacesSignalAndRefetchesHistory() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()
        await viewModel.send("hello")

        scripted.push(.messageStart(sessionID: "s-1", seq: 1))
        scripted.push(.messageDelta(sessionID: "s-1", text: "par", rendered: nil, seq: 2))
        await flush()

        // The ring no longer retains the tail after 2.
        scripted.resumeEventsResult = .failure(.gapUnrecoverable(sessionID: "s-1", afterEventID: 2))
        // Authoritative history has the full turn.
        scripted.historyResult = .success(SessionHistory(sessionID: "s-1", count: 2, messages: [
            SessionMessage(role: .user, text: "hello", timestamp: nil, rowID: nil, displayKind: nil, reasoning: nil, toolName: nil, toolContext: nil),
            SessionMessage(role: .assistant, text: "partial recovered from history", timestamp: nil, rowID: nil, displayKind: nil, reasoning: nil, toolName: nil, toolContext: nil),
        ]))
        // Live frame jumps to seq 9 — gap.
        scripted.push(.messageDelta(sessionID: "s-1", text: "tail", rendered: nil, seq: 9))
        for _ in 0..<50 where viewModel.integrityNotice == nil {
            await flush()
        }

        XCTAssertNotNil(viewModel.integrityNotice)
        XCTAssertTrue(viewModel.integrityNotice?.contains("no longer retained") ?? false,
                      "the unrecoverable-gap signal must be explicit")
        // Transcript was replaced by the authoritative history (2 rows:
        // user + assistant) — no partial hole, no silent loss.
        let assistant = viewModel.transcript.first { $0.kind == .assistant }
        XCTAssertEqual(assistant?.text, "partial recovered from history",
                       "authoritative history replaces the gapped stream")
    }

    /// t_8401d3c3 review round 1 (apple-qa) — gateway PROCESS restart (epoch
    /// change) resets the gateway's per-session seq to 1 while the client may
    /// still hold a high-watermark cursor. The epoch-change history refetch
    /// must DROP the cursor, so the first post-restart stamped event (seq 1)
    /// is APPLIED and re-establishes continuity instead of being classified
    /// `.duplicate` and silently dropped.
    func testEpochChangeRefetchDropsStaleCursor() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()
        await viewModel.send("hello")

        // Establish a HIGH client cursor (seq 1-3) against the old epoch.
        scripted.push(.messageStart(sessionID: "s-1", seq: 1))
        scripted.push(.messageDelta(sessionID: "s-1", text: "old", rendered: nil, seq: 2))
        scripted.push(.messageComplete(sessionID: "s-1", text: "old", status: nil, error: nil, seq: 3))
        await flush()
        let before = viewModel.transcript.first { $0.kind == .assistant }
        XCTAssertEqual(before?.text, "old", "pre-restart cursor established at seq 3")

        // Gateway restarts: epoch change → authoritative history refetch
        // (history survives restarts; seq does not — it restarts at 1).
        scripted.replayOutcomes = .success([.epochChanged(from: "epoch-1", to: "epoch-2")])
        scripted.historyResult = .success(SessionHistory(sessionID: "s-1", count: 2, messages: [
            SessionMessage(role: .user, text: "hello", timestamp: nil, rowID: nil, displayKind: nil, reasoning: nil, toolName: nil, toolContext: nil),
            SessionMessage(role: .assistant, text: "old", timestamp: nil, rowID: nil, displayKind: nil, reasoning: nil, toolName: nil, toolContext: nil),
        ]))
        await viewModel.reconnect()
        XCTAssertEqual(viewModel.replayNotice, "Reconnected · gateway restarted — history refreshed")

        // Post-restart live turn: events arrive with seq 1, 2 — all ≤ the
        // stale cursor 3. They MUST render (cursor dropped with the refetch),
        // never drop silently as duplicates.
        scripted.push(.messageStart(sessionID: "s-1", seq: 1))
        scripted.push(.messageDelta(sessionID: "s-1", text: "post-restart ", rendered: nil, seq: 2))
        scripted.push(.messageDelta(sessionID: "s-1", text: "turn", rendered: nil, seq: 3))
        await flush()

        let assistant = viewModel.transcript.last { $0.kind == .assistant }
        XCTAssertEqual(assistant?.text, "post-restart turn",
                       "post-restart low-seq events must APPLY (cursor dropped), not drop as duplicates")

        // The applied tail is contiguous from the fresh epoch: the next live
        // event (seq 4) renders without firing a spurious gap recovery.
        scripted.push(.messageComplete(sessionID: "s-1", text: "post-restart turn", status: nil, error: nil, seq: 4))
        await flush()
        XCTAssertEqual(scripted.resumeEventsRequests.count, 0,
                       "fresh-epoch tail must be contiguous — no spurious gap recovery")
        let completed = viewModel.transcript.last { $0.kind == .assistant }
        XCTAssertEqual(completed?.text, "post-restart turn")
    }

    // MARK: - t_a07ca37e heartbeat-freshness poll gate

    /// Transport-fresh liveness (<12s silence) means PROVABLY alive: the
    /// status watcher must SKIP its polls in that window, so a transient
    /// offline status flip is not acted on while heartbeats just flowed.
    /// Past the fresh window the poll resumes and the flip applies.
    func testStatusPollSkippedWhileTransportFresh() async throws {
        let (scripted, viewModel) = try await makeFixture()
        // Fresh frame right now.
        scripted.livenessValue = ConnectionLivenessSnapshot(lastFrameReceivedAt: .now)
        await viewModel.start()
        XCTAssertEqual(viewModel.phase, .ready)

        // Offline flip while FRESH: poll gated — no disconnected transition.
        scripted.statusValue = .offline
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(viewModel.phase, .ready,
                       "fresh transport (<12s silence) must skip the status poll")

        // Silence ages past the fresh window (30s): polls resume, flip applies.
        scripted.livenessValue = ConnectionLivenessSnapshot(
            lastFrameReceivedAt: .now - .seconds(30))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(viewModel.phase, .disconnected,
                       "non-fresh transport must resume status polling")
    }

    /// Nil liveness (no transport signal — doubles/previews) keeps the
    /// previous always-poll behavior.
    func testNilLivenessKeepsAlwaysPollBehavior() async throws {
        let (scripted, viewModel) = try await makeFixture()
        scripted.livenessValue = nil
        await viewModel.start()
        XCTAssertEqual(viewModel.phase, .ready)

        scripted.statusValue = .offline
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(viewModel.phase, .disconnected,
                       "nil liveness must not gate status polls")
    }

    // MARK: - t_e77c614c generation-token fencing

    /// Superseded recovery's history refetch (epoch-change path) must not
    /// overwrite the transcript a NEWER reconnect already established.
    ///
    /// Race: reconnect #1 in flight, its replay hydration hits an
    /// epoch-changed outcome and refetches history; before that fetch lands,
    /// reconnect #2 (the user retapped) completes with a DIFFERENT (newer)
    /// authoritative history. The stale refetch landing last must be dropped
    /// — the transcript keeps the newest reconnect's state.
    func testSupersededReconnectRefetchDoesNotOverwriteNewerState() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-1")
        await viewModel.start()

        // start() intentionally launches eager history hydration asynchronously.
        // Settle it before arming the reconnect gate, otherwise the gate can
        // capture that initial fetch instead of reconnect #1's refetch.
        for _ in 0..<100 {
            if !viewModel.isHistoryHydrationInProgress { break }
            await flush()
        }
        XCTAssertFalse(viewModel.isHistoryHydrationInProgress)

        // Hold reconnect #1's history refetch in flight.
        let gate = OneShotGate()
        scripted.historyGate = gate
        scripted.replayOutcomes = .success([.epochChanged(from: "e1", to: "e2")])
        // Stale history the OLD refetch will eventually return.
        scripted.historyResult = .success(SessionHistory(sessionID: "s-1", count: 1, messages: [
            SessionMessage(role: .assistant, text: "STALE old refetch"),
        ]))
        async let staleReconnect: Void = viewModel.reconnect()

        // Deterministically wait until #1's history refetch has PARKED (the
        // stale result is captured, the fetch held) before starting the
        // newer operation which must supersede it.
        while scripted.historyParkedCount == 0 { await flush() }
        XCTAssertEqual(viewModel.phase, .reconnecting)

        // Reconnect #2 supersedes; it must complete fully and settle state
        // (its own epoch-change outcome refetches the NEW history ungated).
        scripted.replayOutcomes = .success([.epochChanged(from: "e2", to: "e3")])
        scripted.historyGate = nil // subsequent fetches pass straight through
        scripted.historyResult = .success(SessionHistory(sessionID: "s-1", count: 1, messages: [
            SessionMessage(role: .assistant, text: "NEW authoritative history"),
        ]))
        await viewModel.reconnect()
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.replayNotice, "Reconnected · gateway restarted — history refreshed")

        // Release the stale refetch AFTER the newer state settled.
        gate.open()
        _ = await staleReconnect

        let assistant = viewModel.transcript.last { $0.kind == .assistant }
        XCTAssertEqual(assistant?.text, "NEW authoritative history",
                       "stale (superseded) refetch must be dropped, not overwrite newer state")
        XCTAssertEqual(viewModel.phase, .ready,
                       "stale completion must not flip the phase either")
    }

    /// Superseded reconnect's replay notice must not overwrite the newer
    /// operation's notice (observable UI state, same fence).
    func testSupersededReconnectDoesNotOverwriteNewerNotice() async throws {
        let (scripted, viewModel) = try await makeFixture()
        await viewModel.start()
        let parkedBaseline = scripted.replayParkedCount

        // Reconnect #1 in flight, holding the replay RPC.
        let gate = OneShotGate()
        scripted.replayGate = gate
        scripted.replayOutcomes = .success([.replayed(sessionID: "s-1", count: 9)])
        async let staleReconnect: Void = viewModel.reconnect()

        // Deterministically wait until #1 has PARKED on the gate (its token
        // is captured and its RPC is held) before starting the newer op.
        while scripted.replayParkedCount == parkedBaseline { await flush() }

        // Reconnect #2 supersedes and settles a different notice.
        scripted.replayGate = nil
        scripted.replayOutcomes = .success([.nothingToReplay])
        await viewModel.reconnect()
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.replayNotice, "Reconnected · nothing new")

        // Stale replay lands now — its notice must be dropped.
        gate.open()
        _ = await staleReconnect
        XCTAssertEqual(viewModel.replayNotice, "Reconnected · nothing new",
                       "stale replay notice must not overwrite the newer operation's")
    }

    /// In-order (non-raced) reconnect behaves exactly as before: notice set,
    /// phase ready, transcript refetched on epoch change.
    func testInOrderReconnectUnchanged() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-1")
        await viewModel.start()

        scripted.replayOutcomes = .success([.epochChanged(from: "e1", to: "e2")])
        scripted.historyResult = .success(SessionHistory(sessionID: "s-1", count: 1, messages: [
            SessionMessage(role: .assistant, text: "in-order history"),
        ]))
        await viewModel.reconnect()

        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.replayNotice, "Reconnected · gateway restarted — history refreshed")
        let assistant = viewModel.transcript.last { $0.kind == .assistant }
        XCTAssertEqual(assistant?.text, "in-order history")
    }

    // MARK: - H1 history hydration UX (t_01c9d411)

    /// H1: opening an existing session with an EMPTY cache must show the
    /// loading placeholder (never a bare new-chat slate) and fetch the
    /// authoritative history IMMEDIATELY after resume — the resume
    /// projection suppressing its messages is not an "empty session".
    func testEmptyCacheShowsPlaceholderThenAuthoritativeHistory() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-1")
        // Empty cache (nothing seeded) AND empty resume projection (the
        // gateway default) — history must come from session.history.
        scripted.historyResult = .success(SessionHistory(sessionID: "s-1", count: 2, messages: [
            SessionMessage(role: .user, text: "wire question", timestamp: 1, rowID: "r1"),
            SessionMessage(role: .assistant, text: "wire answer", timestamp: 2, rowID: "r2"),
        ]))

        await viewModel.start()
        await flush() // let the eager post-resume history fetch land

        XCTAssertTrue(viewModel.isHistoryHydrationInProgress == false,
                      "authoritative history landed — hydration must be settled")
        XCTAssertFalse(viewModel.showsHistoryLoadingPlaceholder)
        XCTAssertEqual(scripted.historyCallCount, 1,
                       "suppressed resume projection must trigger exactly one eager session.history fetch")
        XCTAssertEqual(viewModel.transcript.count, 2)
        XCTAssertEqual(viewModel.transcript.first?.text, "wire question")
        XCTAssertEqual(viewModel.transcript.last?.kind, .assistant)
    }

    /// H1: the placeholder phase must be OBSERVABLE while hydration is still
    /// in flight — arm the one-shot history gate so the eager fetch parks,
    /// then assert the loading state shows before it completes.
    func testPlaceholderVisibleWhileHistoryInFlight() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-1")
        let gate = OneShotGate()
        scripted.historyGate = gate
        scripted.historyResult = .success(SessionHistory(sessionID: "s-1", count: 1, messages: [
            SessionMessage(role: .assistant, text: "late history", rowID: "r1"),
        ]))

        await viewModel.start()
        await flush()

        XCTAssertTrue(scripted.historyParkedCount > 0, "the eager history fetch must be in flight")
        XCTAssertTrue(viewModel.showsHistoryLoadingPlaceholder,
                      "empty transcript + hydration in flight ⇒ placeholder, not a blank slate")
        XCTAssertTrue(viewModel.isHistoryHydrationInProgress)

        gate.open()
        await flush()
        XCTAssertFalse(viewModel.showsHistoryLoadingPlaceholder)
        XCTAssertEqual(viewModel.transcript.last?.text, "late history")
    }

    /// H1: a POPULATED cache renders immediately and the later authoritative
    /// swap PRESERVES row identities (no flash/jump when history replaces
    /// the cached rows). The one-shot history gate holds the eager fetch so
    /// both phases are observed deterministically.
    func testPopulatedCacheRendersImmediatelyAndSwapPreservesIDs() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-1")
        try await cache.saveHistory(
            SessionHistory(sessionID: "s-1", count: 2, messages: [
                SessionMessage(role: .user, text: "cached question", timestamp: 1, rowID: "r1"),
                SessionMessage(role: .assistant, text: "cached answer", timestamp: 2, rowID: "r2"),
            ]),
            for: GatewayID(rawValue: "workstation")
        )
        // The authoritative history carries the SAME durable rows.
        scripted.historyResult = .success(SessionHistory(sessionID: "s-1", count: 2, messages: [
            SessionMessage(role: .user, text: "cached question", timestamp: 1, rowID: "r1"),
            SessionMessage(role: .assistant, text: "cached answer", timestamp: 2, rowID: "r2"),
        ]))
        let gate = OneShotGate()
        scripted.historyGate = gate

        await viewModel.start()
        await flush()

        // Cache rows rendered immediately; no placeholder once they land.
        XCTAssertEqual(viewModel.transcript.map(\.text), ["cached question", "cached answer"])
        XCTAssertTrue(viewModel.hydratedFromCache)
        XCTAssertFalse(viewModel.showsHistoryLoadingPlaceholder)

        // Release the (parked) eager authoritative fetch — the swap must
        // preserve row ids so SwiftUI updates bubbles in place.
        gate.open()
        await flush()
        XCTAssertFalse(viewModel.hydratedFromCache)
        XCTAssertEqual(viewModel.transcript.map(\.text), ["cached question", "cached answer"])
        XCTAssertEqual(viewModel.transcript.map(\.id), ["row-1", "row-2"],
                       "cache→authoritative swap must preserve row ids (no flash)")
        XCTAssertEqual(scripted.historyCallCount, 1)
    }

    /// H1: a FAILED authoritative fetch must NEVER wipe cached rows — the
    /// cache stays rendered and an honest error surfaces.
    func testFailedAuthoritativeFetchKeepsCacheAndSurfacesError() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-1")
        try await cache.saveHistory(
            SessionHistory(sessionID: "s-1", count: 2, messages: [
                SessionMessage(role: .user, text: "cached question", timestamp: 1, rowID: "r1"),
                SessionMessage(role: .assistant, text: "cached answer", timestamp: 2, rowID: "r2"),
            ]),
            for: GatewayID(rawValue: "workstation")
        )
        scripted.historyResult = .failure(.rpcFailed("gateway hiccup"))

        await viewModel.start()
        await flush()

        XCTAssertTrue(viewModel.hydratedFromCache, "cache must remain the rendered source")
        XCTAssertEqual(viewModel.transcript.map(\.text), ["cached question", "cached answer"],
                       "a failed refetch must never wipe cached rows")
        XCTAssertNotNil(viewModel.historyLoadError, "an honest error must surface")
        XCTAssertTrue(viewModel.historyLoadError?.contains("gateway hiccup") == true)
    }

    /// H1: an authoritatively EMPTY session (empty cache + empty fetch
    /// result) settles hydration — placeholder clears, honest blank state.
    func testAuthoritativelyEmptySessionClearsPlaceholder() async throws {
        let (_, viewModel) = try await makeFixture(sessionID: "s-1")
        // Empty cache + empty history result: session.history confirming
        // zero messages is authoritative (unlike the suppressed projection).

        await viewModel.start()
        await flush()

        XCTAssertFalse(viewModel.showsHistoryLoadingPlaceholder,
                       "authoritative empty ⇒ no perpetual spinner")
        XCTAssertFalse(viewModel.isHistoryHydrationInProgress)
        XCTAssertTrue(viewModel.transcript.isEmpty)
    }

    /// H1: `mergePreservingIDs` — durable row_id matches keep their rendered
    /// ids; unmatched authoritative messages get fresh ids.
    func testMergePreservingIDsDurableAndContentPaths() {
        let existing = [
            ConversationRow(id: "row-1", kind: .user, text: "hello", rowID: "r1"),
            ConversationRow(id: "row-2", kind: .assistant, text: "hi", rowID: "r2"),
        ]
        let authoritative = [
            SessionMessage(role: .user, text: "hello", timestamp: 1, rowID: "r1"),
            SessionMessage(role: .assistant, text: "hi", timestamp: 2, rowID: "r2"),
            SessionMessage(role: .user, text: "second turn", timestamp: 3, rowID: "r3"),
        ]
        var counter = 0
        let merged = FleetUI.ConversationViewModel.mergePreservingIDs(
            existing: existing, authoritative: authoritative,
            nextRowID: { counter += 1; return "fresh-\(counter)" }
        )
        XCTAssertEqual(merged.map(\.id), ["row-1", "row-2", "fresh-1"])
        XCTAssertEqual(merged.map(\.rowID), ["r1", "r2", "r3"])

        // Content-match fallback (no durable ids, identical content+position).
        let existingNoIDs = [
            ConversationRow(id: "row-A", kind: .user, text: "q"),
            ConversationRow(id: "row-B", kind: .assistant, text: "a"),
        ]
        let authoritativeNoIDs = [
            SessionMessage(role: .user, text: "q"),
            SessionMessage(role: .assistant, text: "a"),
        ]
        counter = 0
        let mergedContent = FleetUI.ConversationViewModel.mergePreservingIDs(
            existing: existingNoIDs, authoritative: authoritativeNoIDs,
            nextRowID: { counter += 1; return "fresh-\(counter)" }
        )
        XCTAssertEqual(mergedContent.map(\.id), ["row-A", "row-B"])
    }
}
