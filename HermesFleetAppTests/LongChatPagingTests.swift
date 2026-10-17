import XCTest
import FleetCore
import FleetPersistence
import FleetUI

/// #188 hosted tests — the long-chat paged transcript in `ConversationViewModel`.
///
/// Everything is synthetic: a 25,000-row lineage served by a fake pager, and a
/// fake session that refuses the full resume with 4130 and honors
/// `omit_messages`. No gateway, network, or live device.
@MainActor
final class LongChatPagingTests: XCTestCase {

    private var cache: SwiftDataCacheStore!

    // MARK: - Synthetic lineage pager

    /// Serves a chronological lineage through the newest-first page contract:
    /// `offset` skips the K newest RAW rows, the page comes back oldest→newest,
    /// and `returned` is the raw row count. Test-only; MainActor-confined.
    private final class SyntheticLineagePager: SessionHistoryPaging, @unchecked Sendable {
        private(set) var rows: [SessionMessage]
        private(set) var requests: [(offset: Int, limit: Int)] = []
        var unsupported = false

        init(count: Int) {
            rows = (1...count).map { index in
                SessionMessage(role: .assistant, text: "row \(index)", rowID: String(index))
            }
        }

        /// New tip rows arriving after the last page was read.
        func appendTip(_ count: Int) {
            let start = rows.count
            for index in (start + 1)...(start + count) {
                rows.append(SessionMessage(role: .assistant, text: "row \(index)", rowID: String(index)))
            }
        }

        func fetchLatestPage(sessionID: String, profile: String?, offset: Int, limit: Int) async throws -> SessionHistoryPage {
            requests.append((offset, limit))
            // Real network latency: the request suspends, so overlapping
            // callers observe an in-flight load.
            try? await Task.sleep(for: .milliseconds(2))
            if unsupported {
                throw SessionHistoryPagingError.unsupported("synthetic: route missing")
            }
            let end = max(0, rows.count - offset)
            let start = max(0, end - limit)
            let slice = Array(rows[start..<end])
            return SessionHistoryPage(messages: slice, offset: offset, limit: limit, returned: slice.count)
        }
    }

    // MARK: - Scripted session

    /// Fake session: the full resume answers `fullResume` (default: 4130), the
    /// omit-messages resume answers `omitResume`, and `session.history` is
    /// counted so tests can prove paged mode never calls it.
    private final class LongChatSession:
        ConversationSessionProviding,
        ConversationProviding,
        ReplayProviding,
        SessionHistoryProviding,
        SessionHistoryPagingCapable,
        @unchecked Sendable
    {
        let gatewayID = GatewayID(rawValue: "workstation")
        let pager: SyntheticLineagePager?

        var fullResume: Result<ConversationSession, ConversationError> =
            .failure(.sessionTooLongToReload(messageCount: 25_000))
        var omitResume: Result<ConversationSession, ConversationError> =
            .success(ConversationSession(sessionID: "s-1", messageCount: 25_000, messages: [], profileName: "default"))
        var resumeOmitFlags: [Bool] = []
        var historyCallCount = 0
        var replayOutcomes: [ReplayOutcome] = [.nothingToReplay]
        var submittedTexts: [String] = []

        private let streamPair: (AsyncStream<ConversationEvent>, AsyncStream<ConversationEvent>.Continuation)

        init(pager: SyntheticLineagePager?) {
            self.pager = pager
            self.streamPair = AsyncStream.makeStream()
        }

        var historyPager: (any SessionHistoryPaging)? { pager }

        // GatewayConnectivityProviding
        var status: GatewayStatus { .online }
        var liveness: ConnectionLivenessSnapshot? { nil }
        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "epoch-1", heartbeatEnabled: true, changeEventsEnabled: true)
        }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: "MacBook") }
        func reauthenticate() async throws {}

        // ConversationSessionProviding
        var conversation: any ConversationProviding { self }
        var replay: any ReplayProviding { self }
        var history: any SessionHistoryProviding { self }

        // ConversationProviding
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            ConversationSession(sessionID: "s-1", profileName: "default")
        }
        func resumeSession(sessionID: String, lastEventID: Int?, profile: String?) async throws -> ConversationSession {
            resumeOmitFlags.append(false)
            return try fullResume.get()
        }
        func resumeSession(sessionID: String, lastEventID: Int?, profile: String?, omitMessages: Bool) async throws -> ConversationSession {
            resumeOmitFlags.append(omitMessages)
            guard omitMessages else { return try fullResume.get() }
            return try omitResume.get()
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
            submittedTexts.append(text)
            return PromptSubmission(status: "streaming")
        }
        func interrupt(sessionID: String) async throws -> InterruptResult {
            InterruptResult(status: "interrupted")
        }
        var events: AsyncStream<ConversationEvent> { streamPair.0 }
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }

        // ReplayProviding
        func watermarks() async -> [SessionEventWatermark] { [] }
        func replayAfterReconnect() async throws -> [ReplayOutcome] { replayOutcomes }

        // SessionHistoryProviding: the paged path must never reach these.
        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
            historyCallCount += 1
            return SessionHistory(sessionID: sessionID, count: 0, messages: [])
        }
        func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
            SessionStatus.parse(output: "Session ID: \(sessionID)")
        }

        func push(_ event: ConversationEvent) {
            streamPair.1.yield(event)
        }
    }

    // MARK: - Fixtures

    private func makeFixture(
        session: LongChatSession
    ) async throws -> ConversationViewModel {
        cache = try SwiftDataCacheStore.makeInMemory()
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default")
        )
        return ConversationViewModel(
            session: session,
            cache: cache,
            route: route,
            sessionID: "s-1",
            statusInterval: .milliseconds(10)
        )
    }

    /// A long chat opened through the 4130 → omit_messages fallback, with the
    /// newest page loaded.
    private func openLongChat(lineage: Int = 25_000) async throws -> (LongChatSession, SyntheticLineagePager, ConversationViewModel) {
        let pager = SyntheticLineagePager(count: lineage)
        let session = LongChatSession(pager: pager)
        let viewModel = try await makeFixture(session: session)
        await viewModel.start()
        let loaded = await eventually { viewModel.hasOlderHistory }
        XCTAssertTrue(loaded, "the newest page should load and report older rows")
        return (session, pager, viewModel)
    }

    /// Poll the main actor until `condition` holds or the deadline passes.
    private func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func rowIDs(_ viewModel: ConversationViewModel) -> [Int] {
        viewModel.transcript.compactMap { $0.rowID.flatMap { Int($0) } }
    }

    /// Load older pages until exhausted (bounded so a regression cannot spin).
    private func loadEverything(_ viewModel: ConversationViewModel, maxPages: Int = 400) async {
        var pages = 0
        while viewModel.hasOlderHistory, pages < maxPages {
            await viewModel.loadOlderHistory()
            pages += 1
        }
    }

    // MARK: - Open path

    func testFourThirtyResumeReopensWithOmitMessagesAndLoadsLatestPageInOrder() async throws {
        let (session, pager, viewModel) = try await openLongChat()

        XCTAssertEqual(session.resumeOmitFlags, [false, true], "full resume refused, then omit_messages re-resume")
        XCTAssertTrue(viewModel.isPagedHistory)
        XCTAssertEqual(pager.requests.first?.offset, 0)
        XCTAssertEqual(pager.requests.first?.limit, 200)
        XCTAssertEqual(viewModel.transcript.count, 200)
        XCTAssertEqual(rowIDs(viewModel), Array(24_801...25_000), "latest page, oldest to newest")
        XCTAssertEqual(session.historyCallCount, 0, "paged mode never calls session.history")
        XCTAssertNil(viewModel.historyLoadError)
        XCTAssertNotNil(viewModel.pagedHistoryNotice)
    }

    func testLoadingOlderHistoryUntilExhaustedYieldsEveryRowOnceAscending() async throws {
        let (session, pager, viewModel) = try await openLongChat()

        await loadEverything(viewModel)

        XCTAssertFalse(viewModel.hasOlderHistory)
        XCTAssertNil(viewModel.olderHistoryError)
        let ids = rowIDs(viewModel)
        XCTAssertEqual(ids.count, 25_000)
        XCTAssertEqual(Set(ids).count, 25_000, "no duplicates")
        XCTAssertEqual(ids, Array(1...25_000), "strictly ascending, contiguous")
        XCTAssertTrue(pager.requests.allSatisfy { $0.limit <= 200 }, "every page request stays within the 200-row page")
        // 1 newest page + 125 older pages (the last returns the empty tail).
        XCTAssertEqual(pager.requests.count, 126)
        XCTAssertEqual(pager.requests.dropFirst().map { $0.offset }, Array(stride(from: 200, through: 25_000, by: 200)))
        XCTAssertEqual(session.historyCallCount, 0)
    }

    func testNewTipRowsBetweenPagesCauseNoDuplicatesOrGaps() async throws {
        let (session, pager, viewModel) = try await openLongChat()
        await viewModel.loadOlderHistory()

        // Five rows land at the tip while older history is being paged.
        pager.appendTip(5)
        await loadEverything(viewModel)

        var ids = rowIDs(viewModel)
        XCTAssertEqual(Set(ids).count, ids.count, "dedupe holds when offsets shift")
        XCTAssertEqual(ids, ids.sorted(), "rows never reorder")
        XCTAssertEqual(ids, Array(1...25_000), "overlap, not a gap")

        // A tip refresh then folds the new rows in without losing the older
        // pages already loaded.
        session.replayOutcomes = [.truncated(sessionID: "s-1")]
        await viewModel.reconnect()
        ids = rowIDs(viewModel)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, Array(1...25_005))
    }

    func testConcurrentLoadOlderHistoryIssuesOneRequest() async throws {
        let (_, pager, viewModel) = try await openLongChat()
        let before = pager.requests.count

        async let first: Void = viewModel.loadOlderHistory()
        async let second: Void = viewModel.loadOlderHistory()
        _ = await (first, second)

        XCTAssertEqual(pager.requests.count - before, 1, "a second caller joins nothing and issues nothing")
        XCTAssertEqual(rowIDs(viewModel).count, 400)
        XCTAssertFalse(viewModel.isLoadingOlderHistory)
    }

    // MARK: - Reconnect, streaming, failure

    func testReconnectInPagedModeRefetchesThroughPagerAndKeepsOlderRows() async throws {
        let (session, pager, viewModel) = try await openLongChat()
        await viewModel.loadOlderHistory()
        await viewModel.loadOlderHistory()
        XCTAssertEqual(viewModel.transcript.count, 600)
        let requestsBefore = pager.requests.count
        session.replayOutcomes = [.truncated(sessionID: "s-1")]

        await viewModel.reconnect()

        XCTAssertGreaterThan(pager.requests.count, requestsBefore, "the refetch went to the pager")
        XCTAssertEqual(pager.requests.last?.offset, 0)
        XCTAssertEqual(pager.requests.last?.limit, 200)
        XCTAssertEqual(session.historyCallCount, 0, "session.history is never used in paged mode")
        XCTAssertEqual(viewModel.transcript.count, 600, "older loaded rows survive the tail refresh")
        XCTAssertEqual(rowIDs(viewModel), Array(24_401...25_000))
    }

    func testStreamedRepliesDuringPagingAppendAfterTheTail() async throws {
        let (session, _, viewModel) = try await openLongChat()
        await viewModel.loadOlderHistory()

        // The wire opens every turn with message.start, which mints the live
        // assistant row; deltas then append to it.
        session.push(.messageStart(sessionID: "s-1", seq: nil))
        session.push(.messageDelta(sessionID: "s-1", text: "streamed ", rendered: nil, seq: nil))
        session.push(.messageDelta(sessionID: "s-1", text: "reply", rendered: nil, seq: nil))
        session.push(.messageComplete(sessionID: "s-1", text: "streamed reply", status: "complete", error: nil, seq: nil))

        let landed = await eventually { viewModel.transcript.last?.text == "streamed reply" }
        XCTAssertTrue(landed)
        let transcript = viewModel.transcript
        XCTAssertEqual(transcript.count, 401, "400 loaded rows plus one live reply")
        XCTAssertEqual(transcript.last?.kind, .assistant)
        XCTAssertNil(transcript.last?.rowID, "a live row carries no durable id")
        let ids = transcript.compactMap { $0.rowID.flatMap { Int($0) } }
        XCTAssertEqual(ids, Array(24_601...25_000))
    }

    func testUnsupportedPagingKeepsChatOpenWithActionableErrorAndComposerUsable() async throws {
        let pager = SyntheticLineagePager(count: 25_000)
        pager.unsupported = true
        let session = LongChatSession(pager: pager)
        let viewModel = try await makeFixture(session: session)

        await viewModel.start()
        let surfaced = await eventually { viewModel.historyLoadError != nil }

        XCTAssertTrue(surfaced)
        XCTAssertEqual(
            viewModel.historyLoadError,
            "This chat is too long to load all at once, and this gateway can't send it in pages. New messages still work here. To see earlier history, update Hermes on the gateway or open the chat in Hermes Desktop.")
        XCTAssertEqual(viewModel.phase, .ready, "the conversation stays open")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(session.historyCallCount, 0, "no fallback to the whole-lineage frame")
        XCTAssertFalse(viewModel.hasOlderHistory)

        let sent = await viewModel.send("still works here")
        XCTAssertTrue(sent)
        XCTAssertEqual(session.submittedTexts, ["still works here"])
    }

    func testOmitResumeFailureSurfacesLongChatOpenMessageWithCount() async throws {
        let pager = SyntheticLineagePager(count: 25_000)
        let session = LongChatSession(pager: pager)
        session.omitResume = .failure(.rpcFailed("transport closed"))
        let viewModel = try await makeFixture(session: session)

        await viewModel.start()

        guard case .failed(let message) = viewModel.phase else {
            return XCTFail("expected a failed open, got \(viewModel.phase)")
        }
        XCTAssertEqual(
            message,
            "This chat is too long to open on this gateway (25000 messages). Update Hermes on the gateway, or start a new chat with this bot.")
        XCTAssertFalse(viewModel.isPagedHistory)
    }

    // MARK: - Normal chats

    func testNormalChatNeverTouchesThePager() async throws {
        let pager = SyntheticLineagePager(count: 25_000)
        let session = LongChatSession(pager: pager)
        session.fullResume = .success(ConversationSession(
            sessionID: "s-1",
            messageCount: 3,
            messages: [
                SessionMessage(role: .user, text: "one", rowID: "1"),
                SessionMessage(role: .assistant, text: "two", rowID: "2"),
                SessionMessage(role: .user, text: "three", rowID: "3"),
            ],
            profileName: "default"))
        let viewModel = try await makeFixture(session: session)

        await viewModel.start()
        await viewModel.loadOlderHistory()

        XCTAssertEqual(session.resumeOmitFlags, [false], "no omit_messages on a chat that opens today")
        XCTAssertTrue(pager.requests.isEmpty, "the pager is never used for a normal chat")
        XCTAssertFalse(viewModel.isPagedHistory)
        XCTAssertFalse(viewModel.hasOlderHistory)
        XCTAssertEqual(viewModel.transcript.map(\.text), ["one", "two", "three"])
    }
}
