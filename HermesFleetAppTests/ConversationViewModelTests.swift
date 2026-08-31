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
        @unchecked Sendable
    {
        let gatewayID = GatewayID(rawValue: "<dev-workstation>")

        // connectivity
        var statusValue: GatewayStatus = .online
        var connectError: GatewayConnectivityError?
        var connectCount = 0
        var reauthenticateCount = 0

        // conversation
        var createResult: Result<ConversationSession, ConversationError> =
            .success(ConversationSession(sessionID: "s-1", profileName: "default"))
        var resumeResult: Result<ConversationSession, ConversationError> =
            .success(ConversationSession(sessionID: "s-1", profileName: "default"))
        var submitError: ConversationError?
        var interruptError: ConversationError?

        // event stream
        private let streamPair: (AsyncStream<ConversationEvent>, AsyncStream<ConversationEvent>.Continuation)

        // replay
        var replayOutcomes: Result<[ReplayOutcome], ReplayError> = .success([.nothingToReplay])

        // history
        var historyResult: Result<SessionHistory, SessionHistoryError> =
            .success(SessionHistory(sessionID: "s-1", count: 0, messages: []))

        init() {
            self.streamPair = AsyncStream.makeStream()
        }

        // MARK: GatewayConnectivityProviding
        var status: GatewayStatus { statusValue }
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
        func reauthenticate() async throws {
            reauthenticateCount += 1
            if let connectError { throw connectError }
        }

        // MARK: ConversationProviding
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            try createResult.get()
        }
        func resumeSession(sessionID: String) async throws -> ConversationSession {
            try resumeResult.get()
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
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
            try replayOutcomes.get()
        }

        // MARK: SessionHistoryProviding
        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
            try historyResult.get()
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

    // MARK: - Fixture

    private var cache: SwiftDataCacheStore!

    private func makeFixture(
        sessionID: String? = nil
    ) async throws -> (ScriptedSession, ConversationViewModel) {
        let scripted = ScriptedSession()
        cache = try SwiftDataCacheStore.makeInMemory()
        let route = Route(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
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
        let (_, viewModel) = try await makeFixture(sessionID: "s-1")
        try await cache.saveHistory(
            SessionHistory(sessionID: "s-1", count: 2, messages: [
                SessionMessage(role: .user, text: "cached question", timestamp: 1, rowID: "r1"),
                SessionMessage(role: .assistant, text: "cached answer", timestamp: 2, rowID: "r2"),
            ]),
            for: GatewayID(rawValue: "<dev-workstation>")
        )

        await viewModel.start()

        XCTAssertTrue(viewModel.hydratedFromCache)
        XCTAssertEqual(viewModel.transcript.count, 2)
        XCTAssertEqual(viewModel.transcript.first?.text, "cached question")
        XCTAssertEqual(viewModel.transcript.last?.kind, .assistant)
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
}
