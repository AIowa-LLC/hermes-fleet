import XCTest
import FleetCore
import FleetPersistence
@testable import FleetUI

/// An authoritative-history response must never overwrite state that is newer
/// than the request: live events, an active turn, a newer request, another
/// session, or a cancellation all reject or discard it. Deterministic: every
/// history response is released by the test, in the order the test chooses.
@MainActor
final class HistoryRefetchRaceTests: XCTestCase {

    /// Hands out history responses only when the test releases them.
    final class Gates: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [Int: CheckedContinuation<[SessionMessage], Never>] = [:]
        private var ready: [Int: [SessionMessage]] = [:]
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }
        func nextIndex() -> Int { lock.withLock { defer { calls += 1 }; return calls } }
        func wait(_ index: Int) async -> [SessionMessage] {
            await withCheckedContinuation { (c: CheckedContinuation<[SessionMessage], Never>) in
                let result: [SessionMessage]? = lock.withLock {
                    if let r = ready.removeValue(forKey: index) { return r }
                    waiting[index] = c
                    return nil
                }
                if let result { c.resume(returning: result) }
            }
        }
        func release(_ index: Int, _ messages: [SessionMessage]) {
            let c: CheckedContinuation<[SessionMessage], Never>? = lock.withLock {
                if let c = waiting.removeValue(forKey: index) { return c }
                ready[index] = messages
                return nil
            }
            c?.resume(returning: messages)
        }
    }

    private final class Session:
        ConversationSessionProviding, ConversationProviding, ReplayProviding, SessionHistoryProviding,
        @unchecked Sendable
    {
        let gatewayID = GatewayID(rawValue: "workstation")
        let gates = Gates()
        /// When set, calls return immediately with these messages (no gating).
        nonisolated(unsafe) var immediate: [SessionMessage]?
        /// When set, the next ungated calls throw (history unavailable).
        nonisolated(unsafe) var failIndices: Set<Int> = []
        /// Real suspension for `immediate` responses so live events can interleave.
        nonisolated(unsafe) var immediateDelayMs = 0
        let gapStream: AsyncStream<EventGap>
        let gapContinuation: AsyncStream<EventGap>.Continuation
        let eventStream: AsyncStream<ConversationEvent>
        let eventContinuation: AsyncStream<ConversationEvent>.Continuation
        init() {
            (gapStream, gapContinuation) = AsyncStream<EventGap>.makeStream()
            (eventStream, eventContinuation) = AsyncStream<ConversationEvent>.makeStream()
        }
        var status: GatewayStatus = .online
        var liveness: ConnectionLivenessSnapshot?
        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "epoch-1", heartbeatEnabled: true, changeEventsEnabled: true)
        }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: "Workstation") }
        func reauthenticate() async throws {}
        var conversation: any ConversationProviding { self }
        var replay: any ReplayProviding { self }
        var history: any SessionHistoryProviding { self }
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            ConversationSession(sessionID: "fresh", profileName: profile)
        }
        func resumeSession(sessionID: String, lastEventID: Int?, profile: String? = nil) async throws -> ConversationSession {
            ConversationSession(sessionID: sessionID, profileName: "default")
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission { PromptSubmission(status: "streaming") }
        func interrupt(sessionID: String) async throws -> InterruptResult { InterruptResult(status: "ok") }
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
        var events: AsyncStream<ConversationEvent> { eventStream }
        func watermarks() async -> [SessionEventWatermark] { [] }
        func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }
        func subscribeToGaps() -> AsyncStream<EventGap> { gapStream }
        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
            let index = gates.nextIndex()
            if failIndices.contains(index) { throw ReplayError.rpcFailed("history unavailable") }
            let messages: [SessionMessage]
            if let immediate {
                if immediateDelayMs > 0 { try? await Task.sleep(for: .milliseconds(immediateDelayMs)) }
                messages = immediate
            } else { messages = await gates.wait(index) }
            return SessionHistory(sessionID: sessionID, count: messages.count, messages: messages)
        }
        func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
            SessionStatus.parse(output: "Session ID: \(sessionID)\nModel: test-model (sim)")
        }
    }

    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ s: TimeInterval) { lock.withLock { value += s } }
    }

    private var cache: SwiftDataCacheStore!

    private func makeFixture() async throws -> (Session, ConversationViewModel) {
        let session = Session()
        session.immediate = [] // open-time hydration must not block on a gate
        cache = try SwiftDataCacheStore.makeInMemory()
        let route = Route(gatewayID: GatewayID(rawValue: "workstation"), profileSlug: ProfileSlug(rawValue: "default"))
        let model = ConversationViewModel(session: session, cache: cache, route: route, sessionID: "s1")
        let clock = FakeClock()
        model.gapClock = { clock.now }
        model.gapSleep = { clock.advance($0) }
        await model.start()
        try await Task.sleep(for: .milliseconds(400))
        session.immediate = nil
        return (session, model)
    }

    private func msg(_ text: String, role: SessionMessageRole = .assistant, id: String? = nil) -> SessionMessage {
        SessionMessage(role: role, text: text, timestamp: nil, rowID: id)
    }

    private func texts(_ model: ConversationViewModel) -> [String] { model.transcript.map(\.text) }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: live events during a delayed refetch

    func testLiveEventDuringDelayedRefetchIsNotOverwrittenAndRecoveryIsProvenBeforeClearing() async throws {
        let (session, model) = try await makeFixture()
        let base = session.gates.callCount
        session.gapContinuation.yield(EventGap(sessionID: "s1", reason: .subscriberOverflow))
        let started = await waitUntil { session.gates.callCount == base + 1 }
        XCTAssertTrue(started)
        XCTAssertTrue(model.historyMayBeIncomplete)

        // A live event lands while the request is in flight.
        // A completed message (not an open stream): the turn is over, the transcript changed.
        session.eventContinuation.yield(.messageStart(sessionID: "s1", seq: 1))
        session.eventContinuation.yield(.messageDelta(sessionID: "s1", text: "LIVE-1", rendered: nil, seq: 2))
        session.eventContinuation.yield(.messageComplete(sessionID: "s1", text: "LIVE-1", status: nil, error: nil, seq: 3))
        _ = await waitUntil { texts(model).contains { $0.contains("LIVE-1") } && !model.isStreaming }

        // The (older) snapshot arrives: it must NOT replace the live row...
        session.gates.release(base, [msg("OLD-SNAPSHOT")])
        let retried = await waitUntil { session.gates.callCount == base + 2 }
        XCTAssertTrue(retried, "a stale response is retried, not applied")
        XCTAssertTrue(texts(model).contains { $0.contains("LIVE-1") }, "live event survived the stale response")
        XCTAssertFalse(texts(model).contains("OLD-SNAPSHOT"))
        XCTAssertTrue(model.historyMayBeIncomplete, "not proven complete yet: the flag must stay")

        // ...and only the fresh, uncontended snapshot is applied and clears the flag.
        session.gates.release(base + 1, [msg("SNAPSHOT-WITH-LIVE-1")])
        let applied = await waitUntil { texts(model) == ["SNAPSHOT-WITH-LIVE-1"] && !model.historyMayBeIncomplete }
        XCTAssertTrue(applied)
        XCTAssertEqual(session.gates.callCount, base + 2)
    }

    // MARK: out-of-order / overlapping

    func testOutOfOrderResponsesNewestRequestWins() async throws {
        let (session, model) = try await makeFixture()
        let base = session.gates.callCount
        let a = Task { await model.refetchAuthoritativeHistory(sessionID: "s1") }
        _ = await waitUntil { session.gates.callCount == base + 1 }
        let b = Task { await model.refetchAuthoritativeHistory(sessionID: "s1") }
        _ = await waitUntil { session.gates.callCount == base + 2 }

        session.gates.release(base + 1, [msg("B-NEWEST")])      // the newer request answers first
        let bOutcome = await b.value
        XCTAssertEqual(bOutcome, .applied)
        session.gates.release(base, [msg("A-OLD")])             // the older one answers late
        let aOutcome = await a.value
        XCTAssertEqual(aOutcome, .superseded, "a late response from a superseded request is discarded")
        XCTAssertEqual(texts(model), ["B-NEWEST"])
    }

    func testDuplicateResponsesAreIdempotent() async throws {
        let (session, model) = try await makeFixture()
        session.immediate = [msg("one", id: "r1"), msg("two", id: "r2")]
        let first = await model.refetchAuthoritativeHistory(sessionID: "s1")
        let second = await model.refetchAuthoritativeHistory(sessionID: "s1")
        XCTAssertEqual(first, .applied)
        XCTAssertEqual(second, .applied)
        XCTAssertEqual(texts(model), ["one", "two"], "re-applying the same snapshot never duplicates rows")
    }

    // MARK: active streaming

    /// A turn is open (quiet: no event arrives while the request would be in
    /// flight). The snapshot may lack the in-progress reply and later deltas
    /// would attach to the previous turn's row, so nothing is fetched or applied.
    func testQuietOpenTurnIsNeverReplacedAndRefreshesWhenTheTurnCompletes() async throws {
        let (session, model) = try await makeFixture()
        session.eventContinuation.yield(.messageStart(sessionID: "s1", seq: 1))
        session.eventContinuation.yield(.messageDelta(sessionID: "s1", text: "partial", rendered: nil, seq: 2))
        _ = await waitUntil { model.isStreaming && texts(model).contains { $0.contains("partial") } }
        session.immediate = [msg("OLD-HISTORY-WITHOUT-THE-REPLY")]
        let base = session.gates.callCount

        let outcome = await model.refetchAuthoritativeHistory(sessionID: "s1")
        XCTAssertEqual(outcome, .rejectedStale)
        XCTAssertEqual(session.gates.callCount, base, "no request is wasted while a turn is open")
        XCTAssertTrue(texts(model).contains { $0.contains("partial") }, "the in-flight reply is intact")
        XCTAssertTrue(model.historyMayBeIncomplete)
        XCTAssertEqual(model.integrityNotice?.contains("busy"), true)

        // A later delta still extends the SAME reply (not a previous turn's row).
        session.eventContinuation.yield(.messageDelta(sessionID: "s1", text: " more", rendered: nil, seq: 3))
        _ = await waitUntil { texts(model).contains { $0.contains("partial more") } }

        // Completion re-arms exactly one governed refresh, which now applies.
        session.immediate = [msg("FINAL-SNAPSHOT")]
        session.eventContinuation.yield(.messageComplete(sessionID: "s1", text: "partial more", status: nil, error: nil, seq: 4))
        let recovered = await waitUntil { texts(model) == ["FINAL-SNAPSHOT"] && !model.historyMayBeIncomplete }
        XCTAssertTrue(recovered)
    }

    /// The turn starts WHILE the request is in flight: the revision moved, so
    /// the response is rejected, and the retries do not fetch into an open turn.
    func testStreamingThatStartsDuringTheRequestIsNotOverwritten() async throws {
        let (session, model) = try await makeFixture()
        let base = session.gates.callCount
        let task = Task { await model.refetchAuthoritativeHistory(sessionID: "s1") }
        _ = await waitUntil { session.gates.callCount == base + 1 }
        session.eventContinuation.yield(.messageStart(sessionID: "s1", seq: 1))
        session.eventContinuation.yield(.messageDelta(sessionID: "s1", text: "streamed during flight", rendered: nil, seq: 2))
        _ = await waitUntil { model.isStreaming && texts(model).contains { $0.contains("streamed during flight") } }
        session.gates.release(base, [msg("STALE-SNAPSHOT")])
        let outcome = await task.value
        XCTAssertEqual(outcome, .rejectedStale)
        XCTAssertLessThanOrEqual(session.gates.callCount - base, ConversationViewModel.maxRefetchAttempts)
        XCTAssertTrue(texts(model).contains { $0.contains("streamed during flight") })
        XCTAssertFalse(texts(model).contains("STALE-SNAPSHOT"))
        XCTAssertTrue(model.historyMayBeIncomplete)
    }

    /// Attempt 1 is stale; attempt 2 returns an EMPTY history because the server
    /// has not persisted the live rows yet. The live rows survive, the call does
    /// not claim recovery, and a refresh stays armed (no stranded "refreshing…").
    func testEmptySnapshotAfterAStaleAttemptNeverStrandsTheNotice() async throws {
        let (session, model) = try await makeFixture()
        let base = session.gates.callCount
        session.gapContinuation.yield(EventGap(sessionID: "s1", reason: .subscriberOverflow))
        _ = await waitUntil { session.gates.callCount == base + 1 }
        session.eventContinuation.yield(.messageStart(sessionID: "s1", seq: 1))
        session.eventContinuation.yield(.messageDelta(sessionID: "s1", text: "LIVE", rendered: nil, seq: 2))
        session.eventContinuation.yield(.messageComplete(sessionID: "s1", text: "LIVE", status: nil, error: nil, seq: 3))
        _ = await waitUntil { texts(model).contains("LIVE") && !model.isStreaming }
        session.gates.release(base, [msg("STALE")])                       // attempt 1: stale
        for i in 1..<ConversationViewModel.maxRefetchAttempts {           // later attempts: empty
            _ = await waitUntil { session.gates.callCount == base + 1 + i }
            session.gates.release(base + i, [])
        }
        let flagged = await waitUntil { model.integrityNotice?.contains("busy") == true }
        XCTAssertTrue(flagged, "the notice must say recovery is pending, not stay at 'refreshing'")
        XCTAssertTrue(texts(model).contains("LIVE"), "an empty snapshot never erases live rows")
        XCTAssertTrue(model.historyMayBeIncomplete)
        // The armed refresh runs on the next live activity and proves recovery.
        session.immediate = [msg("PERSISTED")]
        session.eventContinuation.yield(.messageStart(sessionID: "s1", seq: 4))
        session.eventContinuation.yield(.messageComplete(sessionID: "s1", text: "", status: nil, error: nil, seq: 5))
        let healed = await waitUntil { texts(model) == ["PERSISTED"] && !model.historyMayBeIncomplete }
        XCTAssertTrue(healed)
    }

    func testPerpetuallyBusyConversationNeverLoopsUnbounded() async throws {
        let (session, model) = try await makeFixture()
        session.immediate = [msg("SNAP")]
        session.immediateDelayMs = 40 // a real suspension: live events interleave with every request
        let churn = Task { @MainActor in
            var seq = 1
            while !Task.isCancelled {
                session.eventContinuation.yield(.messageStart(sessionID: "s1", seq: seq))
                session.eventContinuation.yield(.messageComplete(sessionID: "s1", text: "", status: nil, error: nil, seq: seq + 1))
                seq += 2
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let base = session.gates.callCount
        let outcome = await model.refetchAuthoritativeHistory(sessionID: "s1")
        churn.cancel()
        XCTAssertEqual(outcome, .rejectedStale, "every response landed after fresh live activity")
        XCTAssertEqual(session.gates.callCount - base, ConversationViewModel.maxRefetchAttempts, "bounded: exactly the allowed attempts")
        XCTAssertTrue(model.historyMayBeIncomplete, "no recovery is claimed")
        XCTAssertFalse(texts(model).contains("SNAP"), "the stale snapshot was never applied")
    }

    func testANewerRequestThatFailsDoesNotLeaveRefreshingWithNoPendingPass() async throws {
        let (session, model) = try await makeFixture()
        let base = session.gates.callCount
        // Gap recovery request A is in flight...
        session.gapContinuation.yield(EventGap(sessionID: "s1", reason: .subscriberOverflow))
        _ = await waitUntil { session.gates.callCount == base + 1 }
        // ...a newer request B starts and FAILS...
        session.failIndices = [base + 1]
        let b = Task { await model.refetchAuthoritativeHistory(sessionID: "s1") }
        let bOutcome = await b.value
        XCTAssertEqual(bOutcome, .failed)
        // ...then A's (valid but superseded) response arrives and is discarded.
        session.gates.release(base, [msg("A-DISCARDED")])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(texts(model).contains("A-DISCARDED"))
        XCTAssertTrue(model.historyMayBeIncomplete)
        XCTAssertEqual(model.integrityNotice?.contains("will retry"), true, "the notice promises a retry that is actually armed")
        // The armed refresh runs at the next live activity and then proves recovery.
        session.immediate = [msg("RECOVERED")]
        session.eventContinuation.yield(.messageStart(sessionID: "s1", seq: 1))
        session.eventContinuation.yield(.messageComplete(sessionID: "s1", text: "", status: nil, error: nil, seq: 2))
        let healed = await waitUntil { texts(model) == ["RECOVERED"] && !model.historyMayBeIncomplete }
        XCTAssertTrue(healed)
    }

    // MARK: session change / cancellation

    func testResponseForAnotherSessionIsDiscarded() async throws {
        let (session, model) = try await makeFixture()
        session.immediate = [msg("OTHER-SESSION-HISTORY")]
        let outcome = await model.refetchAuthoritativeHistory(sessionID: "other")
        XCTAssertEqual(outcome, .superseded)
        XCTAssertFalse(texts(model).contains("OTHER-SESSION-HISTORY"))
    }

    func testCancellationDuringTheRequestAppliesNothing() async throws {
        let (session, model) = try await makeFixture()
        let base = session.gates.callCount
        let task = Task { await model.refetchAuthoritativeHistory(sessionID: "s1") }
        _ = await waitUntil { session.gates.callCount == base + 1 }
        task.cancel()
        session.gates.release(base, [msg("SHOULD-NOT-APPEAR")])
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(texts(model).contains("SHOULD-NOT-APPEAR"))
    }
}
