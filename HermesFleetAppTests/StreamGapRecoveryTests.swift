import XCTest
import FleetCore
import FleetPersistence
@testable import FleetUI

/// A live-stream gap must never leave the transcript looking current: the
/// conversation is flagged incomplete, history is refetched, and repeated gaps
/// are rate-limited (bounded refetches, then a persistent visible state).
@MainActor
final class StreamGapRecoveryTests: XCTestCase {

    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    private final class GapSession:
        ConversationSessionProviding, ConversationProviding, ReplayProviding, SessionHistoryProviding,
        @unchecked Sendable
    {
        let gatewayID = GatewayID(rawValue: "workstation")
        private let lock = NSLock()
        private var _historyFetches = 0
        private var _failHistory = false
        let gapStream: AsyncStream<EventGap>
        let gapContinuation: AsyncStream<EventGap>.Continuation

        init() {
            (gapStream, gapContinuation) = AsyncStream<EventGap>.makeStream()
            (eventStream, eventContinuation) = AsyncStream<ConversationEvent>.makeStream()
        }

        var historyFetches: Int { lock.withLock { _historyFetches } }
        var failHistory: Bool {
            get { lock.withLock { _failHistory } }
            set { lock.withLock { _failHistory = newValue } }
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
        let eventStream: AsyncStream<ConversationEvent>
        let eventContinuation: AsyncStream<ConversationEvent>.Continuation
        var events: AsyncStream<ConversationEvent> { eventStream }

        func watermarks() async -> [SessionEventWatermark] { [] }
        func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }
        func subscribeToGaps() -> AsyncStream<EventGap> { gapStream }

        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
            let fail: Bool = lock.withLock { _historyFetches += 1; return _failHistory }
            if fail { throw ReplayError.rpcFailed("history unavailable") }
            return SessionHistory(sessionID: sessionID, count: 0, messages: [])
        }
        func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
            SessionStatus.parse(output: "Session ID: \(sessionID)\nModel: test-model (sim)")
        }
    }

    private var cache: SwiftDataCacheStore!

    private func makeFixture(clock: FakeClock) async throws -> (GapSession, ConversationViewModel) {
        let session = GapSession()
        cache = try SwiftDataCacheStore.makeInMemory()
        let route = Route(gatewayID: GatewayID(rawValue: "workstation"),
                          profileSlug: ProfileSlug(rawValue: "default"))
        let viewModel = ConversationViewModel(session: session, cache: cache, route: route, sessionID: "s1")
        viewModel.gapClock = { clock.now }
        viewModel.gapSleep = { seconds in clock.advance(seconds) } // instant, but time passes
        await viewModel.start()
        try await Task.sleep(for: .milliseconds(400)) // let open-time hydration settle before baselines
        return (session, viewModel)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testGapForTheOpenSessionFlagsIncompleteThenRefetchesAndClears() async throws {
        let (session, model) = try await makeFixture(clock: FakeClock())
        let baseline = session.historyFetches
        session.gapContinuation.yield(EventGap(sessionID: "s1", reason: .subscriberOverflow))
        let recovered = await waitUntil { !model.historyMayBeIncomplete && session.historyFetches > baseline }
        XCTAssertTrue(recovered, "a gap must trigger an authoritative refetch and clear the flag")
        XCTAssertEqual(session.historyFetches, baseline + 1)
        XCTAssertEqual(model.integrityNotice, "Skipped live updates were recovered — history refreshed.")
    }

    func testGapForAnotherSessionIsIgnored() async throws {
        let (session, model) = try await makeFixture(clock: FakeClock())
        let baseline = session.historyFetches
        session.gapContinuation.yield(EventGap(sessionID: "other", reason: .subscriberOverflow))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.historyMayBeIncomplete)
        XCTAssertEqual(session.historyFetches, baseline)
    }

    func testUnknownSessionGapAppliesToTheOpenConversation() async throws {
        let (session, model) = try await makeFixture(clock: FakeClock())
        let baseline = session.historyFetches
        session.gapContinuation.yield(EventGap(sessionID: nil, reason: .oversizedFrame))
        let refetched = await waitUntil { session.historyFetches > baseline }
        XCTAssertTrue(refetched)
        _ = model
    }

    func testAGapStormCostsAtMostTheGovernorBudgetAndEndsInAVisibleState() async throws {
        let clock = FakeClock()
        let (session, model) = try await makeFixture(clock: clock)
        session.failHistory = true // recovery never succeeds, so nothing resets the budget
        let baseline = session.historyFetches
        for _ in 0..<500 { session.gapContinuation.yield(EventGap(sessionID: "s1", reason: .subscriberOverflow)) }
        let suppressed = await waitUntil(10) {
            model.integrityNotice?.contains("faster than they could be recovered") == true
        }
        XCTAssertTrue(suppressed, "past the budget the UI must say history may be incomplete")
        let fetches = session.historyFetches - baseline
        XCTAssertLessThanOrEqual(fetches, model.gapGovernor.policy.maxRecoveriesPerWindow,
                                 "500 gaps must not become 500 refetches (got \(fetches))")
        XCTAssertGreaterThanOrEqual(fetches, 1)
        XCTAssertTrue(model.historyMayBeIncomplete, "an unrecovered transcript never looks current")
        // No further work happens after suppression.
        let settled = session.historyFetches
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.historyFetches, settled)
    }

    func testFailedRefetchKeepsTheTranscriptFlaggedIncomplete() async throws {
        let (session, model) = try await makeFixture(clock: FakeClock())
        session.failHistory = true
        session.gapContinuation.yield(EventGap(sessionID: "s1", reason: .aggregateOverflow))
        let flagged = await waitUntil {
            model.integrityNotice?.hasPrefix("History may be incomplete — refresh failed") == true
        }
        XCTAssertTrue(flagged)
        XCTAssertTrue(model.historyMayBeIncomplete)
    }

    func testRepeatedRecoveryAfterSuccessIsStillBoundedAcrossTheWindow() async throws {
        let clock = FakeClock()
        let (session, model) = try await makeFixture(clock: clock)
        let baseline = session.historyFetches
        for _ in 0..<12 {
            session.gapContinuation.yield(EventGap(sessionID: "s1", reason: .subscriberOverflow))
            _ = await waitUntil(2) { model.gapGovernor.attemptsInWindow(at: clock.now) > 0 && !model.historyMayBeIncomplete }
            try await Task.sleep(for: .milliseconds(20))
        }
        let fetches = session.historyFetches - baseline
        XCTAssertLessThanOrEqual(fetches, 12)
        XCTAssertLessThanOrEqual(model.gapGovernor.attemptsInWindow(at: clock.now),
                                 model.gapGovernor.policy.maxRecoveriesPerWindow)
    }

    func testSuppressedRecoveryNeverFreezesTheLiveStream() async throws {
        let clock = FakeClock()
        let (session, model) = try await makeFixture(clock: clock)
        session.failHistory = true
        // Exhaust the governor: four recoveries already spent inside the window.
        var governor = model.gapGovernor
        for offset in [100.0, 70, 40, 10] { _ = governor.request(at: clock.now - offset) }
        model.gapGovernor = governor
        XCTAssertEqual(governor.attemptsInWindow(at: clock.now), 4)

        session.eventContinuation.yield(.messageDelta(sessionID: "s1", text: "A", rendered: nil, seq: 1))
        _ = await waitUntil { model.transcript.contains { $0.text.contains("A") } }
        // A hole (seq 2-4 never arrive) while recovery is suppressed.
        session.eventContinuation.yield(.messageDelta(sessionID: "s1", text: "B", rendered: nil, seq: 5))
        let rendered = await waitUntil { model.transcript.contains { $0.text.contains("B") } }
        XCTAssertTrue(rendered, "the live tail must keep rendering, not drop against a stale cursor")
        XCTAssertTrue(model.historyMayBeIncomplete, "the hole is visible as an incomplete transcript")
        session.eventContinuation.yield(.messageDelta(sessionID: "s1", text: "C", rendered: nil, seq: 6))
        let tail = await waitUntil { model.transcript.contains { $0.text.contains("C") } }
        XCTAssertTrue(tail, "subsequent events stay contiguous after the hole")
    }

    func testAnOlderRefetchCannotClearAFlagRaisedByANewerGap() async throws {
        let (session, model) = try await makeFixture(clock: FakeClock())
        let baseline = session.historyFetches
        session.gapContinuation.yield(EventGap(sessionID: "s1", reason: .subscriberOverflow))
        session.gapContinuation.yield(EventGap(sessionID: "s1", reason: .subscriberOverflow))
        let done = await waitUntil { session.historyFetches >= baseline + 2 && !model.historyMayBeIncomplete }
        XCTAssertTrue(done, "after the last gap's own refetch the flag clears")
    }
}
