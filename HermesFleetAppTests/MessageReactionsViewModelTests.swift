import XCTest
import FleetCore
import FleetPersistence
import FleetUI

/// R10-T2 hosted tests — the `ConversationViewModel` reaction flow over a
/// scripted `ReactionProviding` seam: long-press target resolution (durable
/// row_id vs live newest_role), optimistic update with rollback on error,
/// server-truth settlement, render of history-carried reactions, and the
/// fail-closed default.
@MainActor
final class MessageReactionsViewModelTests: XCTestCase {

    // MARK: - Scripted reaction seam

    private final class ScriptedReactions: ReactionProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(sessionID: String, target: MessageReactionTarget, emoji: String?)] = []
        var calls: [(sessionID: String, target: MessageReactionTarget, emoji: String?)] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        /// When set, every react throws this (after recording the call).
        var failure: ReactionError?
        /// The result returned for the NEXT call (defaults to row 42 + the
        /// optimistic-confirmed list).
        var results: [MessageReactionResult] = []
        private var resultIndex = 0

        func react(
            sessionID: String,
            target: MessageReactionTarget,
            emoji: String?
        ) async throws -> MessageReactionResult {
            let failure: ReactionError?
            let result: MessageReactionResult
            // Scoped locking (lock/unlock are unavailable in async contexts).
            let view = lock.withLock {
                _calls.append((sessionID, target, emoji))
                let f = self.failure
                let r = self.resultIndex < self.results.count ? self.results[self.resultIndex] : nil
                self.resultIndex += 1
                return (f, r)
            }
            failure = view.0
            if let failure { throw failure }
            result = view.1 ?? MessageReactionResult(
                rowID: target.rowID ?? "42",
                reactions: emoji.map { [MessageReaction(emoji: $0, author: "user")] } ?? [])
            return result
        }
    }

    // MARK: - Session double exposing the capability

    private final class ReactionCapableSession: ConversationSessionProviding, ReactionCapable, @unchecked Sendable {
        let gatewayID = GatewayID(rawValue: "workstation")
        let reactionsBox = ScriptedReactions()
        var status: GatewayStatus { .online }
        var liveness: ConnectionLivenessSnapshot? { nil }
        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "epoch-1", heartbeatEnabled: false, changeEventsEnabled: true)
        }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: "MacBook") }
        func reauthenticate() async throws {}
        var conversation: any ConversationProviding { conversationDouble }
        let conversationDouble = ConversationDouble()
        var reactions: any ReactionProviding { reactionsBox }

        /// Push a durable history row (with reactions) the resume path can
        /// adopt — for render tests.
        var resumeMessages: [SessionMessage] = []

        fileprivate final class ConversationDouble: ConversationProviding, @unchecked Sendable {
            private let state = DispatchQueue(label: "react.conversation.double")
            private var _resumeMessages: [SessionMessage] = []
            func setResumeMessages(_ messages: [SessionMessage]) {
                state.sync { _resumeMessages = messages }
            }
            func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
                ConversationSession(sessionID: "s-1", profileName: "default")
            }
            func resumeSession(sessionID: String, lastEventID: Int? = nil) async throws -> ConversationSession {
                let messages = state.sync { _resumeMessages }
                return ConversationSession(sessionID: sessionID, messages: messages, profileName: "default")
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
            func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
        }

        var replay: any ReplayProviding { ReplayDouble() }
        private struct ReplayDouble: ReplayProviding {
            let gatewayID = GatewayID(rawValue: "workstation")
            func watermarks() async -> [SessionEventWatermark] { [] }
            func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }
        }
        var history: any SessionHistoryProviding { HistoryDouble() }
        private struct HistoryDouble: SessionHistoryProviding {
            func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
                SessionHistory(sessionID: sessionID, count: 0, messages: [])
            }
            func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
                SessionStatus.parse(output: "Session ID: \(sessionID)")
            }
        }
    }

    // MARK: - Fixture

    /// `resumeMessages` seeds the resume projection BEFORE the first open —
    /// `start()` is idempotent once a session is open, so seeding after has
    /// no effect.
    private func makeFixture(
        sessionID: String? = nil,
        resumeMessages: [SessionMessage] = []
    ) async throws -> (ReactionCapableSession, ConversationViewModel) {
        let session = ReactionCapableSession()
        session.conversationDouble.setResumeMessages(resumeMessages)
        let cache = try SwiftDataCacheStore.makeInMemory()
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default"))
        let viewModel = ConversationViewModel(
            session: session,
            cache: cache,
            route: route,
            sessionID: sessionID,
            statusInterval: .milliseconds(10))
        await viewModel.start()
        return (session, viewModel)
    }

    private func flush() async {
        try? await Task.sleep(for: .milliseconds(30))
    }

    // MARK: - Target resolution

    func testReactOnDurableRowSendsRowID() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-9", resumeMessages: [
            SessionMessage(role: .user, text: "durable", rowID: "77"),
        ])
        try await Task.sleep(for: .milliseconds(50))

        await viewModel.react(rowID: "77", emoji: "👍")
        await flush()

        let calls = scripted.reactionsBox.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].sessionID, "s-9")
        XCTAssertEqual(calls[0].target, .durable(rowID: "77"))
        XCTAssertEqual(calls[0].emoji, "👍")
    }

    // MARK: - Optimistic update + settlement + rollback

    func testReactAppliesOptimisticallySettlesOnServerTruth() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-9", resumeMessages: [
            SessionMessage(role: .assistant, text: "answer", rowID: "88"),
        ])
        try await Task.sleep(for: .milliseconds(50))

        // Server truth: the user's 👍 AND an agent ❤️.
        scripted.reactionsBox.results = [
            MessageReactionResult(rowID: "88", reactions: [
                MessageReaction(emoji: "👍", author: "user"),
                MessageReaction(emoji: "❤️", author: "agent"),
            ]),
        ]

        await viewModel.react(rowID: "88", emoji: "👍")
        await flush()

        let row = viewModel.transcript.first { $0.text == "answer" }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.reactions?.map(\.emoji).sorted(), ["❤️", "👍"],
                      "server truth settles: both the user's and the agent's reactions render")
    }

    func testReactFailureRollsBackOptimisticUpdateAndSurfacesError() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-9", resumeMessages: [
            SessionMessage(role: .assistant, text: "answer", rowID: "88"),
        ])
        try await Task.sleep(for: .milliseconds(50))

        scripted.reactionsBox.failure = .messageNotFound("message not found in this session")

        await viewModel.react(rowID: "88", emoji: "👍")
        await flush()

        let row = viewModel.transcript.first { $0.text == "answer" }
        XCTAssertEqual(row?.reactions ?? [], [], "optimistic update rolled back on error")
        XCTAssertNotNil(viewModel.reactionError, "failure surfaces — never silent")
        XCTAssertTrue(viewModel.reactionError?.contains("message not found") ?? false)
    }

    func testClearSendsNullAndClearsOwnReaction() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-9", resumeMessages: [
            SessionMessage(role: .user, text: "q", rowID: "5",
                           reactions: [MessageReaction(emoji: "👍", author: "user")]),
        ])
        try await Task.sleep(for: .milliseconds(50))

        scripted.reactionsBox.results = [
            MessageReactionResult(rowID: "5", reactions: []),
        ]

        await viewModel.clearReaction(rowID: "5")
        await flush()

        let calls = scripted.reactionsBox.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls[0].emoji, "clear sends emoji:null")
        let row = viewModel.transcript.first { $0.text == "q" }
        XCTAssertEqual(row?.reactions ?? [], [], "own reaction cleared")
    }

    // MARK: - History render

    func testHistoryCarriedReactionsRenderOnRow() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-9", resumeMessages: [
            SessionMessage(role: .user, text: "hey", rowID: "11", reactions: [
                MessageReaction(emoji: "👀", author: "user", at: 1.5),
            ]),
            SessionMessage(role: .assistant, text: "hello", rowID: "12"),
        ])
        try await Task.sleep(for: .milliseconds(50))

        let reacted = viewModel.transcript.first { $0.text == "hey" }
        XCTAssertEqual(reacted?.reactions?.map(\.emoji), ["👀"],
                      "durable history reactions render on the row")
        let bare = viewModel.transcript.first { $0.text == "hello" }
        XCTAssertEqual(bare?.reactions ?? [], [], "rows without reactions render none")
    }

    // MARK: - Live-row (newest_role) path — QA round-1 defect coverage

    /// QA defect (round 1): a live row (streamed this session, no durable
    /// row_id) addressed via newest_role lost its reaction chip the moment
    /// the message.react SUCCEEDED — settle keyed server truth under the
    /// durable id and dropped the live-* key while the row still projected
    /// through it. The chip must survive settle.
    func testReactOnLiveRowKeepsChipVisibleAfterSuccessfulSettle() async throws {
        let (scripted, viewModel) = try await makeFixture(sessionID: "s-9")
        try await Task.sleep(for: .milliseconds(50))

        // A live user row: appended by send(), never round-tripped through
        // a resume — no durable row_id.
        await viewModel.send("live question")
        await flush()

        // Default scripted result: durable row 42 + the user's 👍.
        await viewModel.react(rowID: nil, kind: .user, emoji: "👍")
        await flush()

        let calls = scripted.reactionsBox.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].target, .newest(role: "user"),
                       "live row addresses newest_role on the wire")

        let row = viewModel.transcript.first { $0.text == "live question" }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.reactions?.map(\.emoji), ["👍"],
                       "chip must SURVIVE a successful settle on a live row")
    }

    /// The settled live row is PROMOTED to the durable id the server
    /// assigned — it projects through the durable key (so Clear Reaction
    /// stays reachable) and later durable-keyed writes target the same row.
    func testReactOnLiveRowPromotesRowToDurableID() async throws {
        let (_, viewModel) = try await makeFixture(sessionID: "s-9")
        try await Task.sleep(for: .milliseconds(50))

        await viewModel.send("live question")
        await flush()
        await viewModel.react(rowID: nil, kind: .user, emoji: "👍")
        await flush()

        let row = viewModel.transcript.first { $0.text == "live question" }
        XCTAssertEqual(row?.rowID, "42",
                       "live row adopts the durable id from message.react's result")
        XCTAssertEqual(viewModel.reactionsByRowID["42"]?.reactions.map(\.emoji), ["👍"],
                       "server truth is keyed under the durable id")
    }

    /// Clear on a live row after a settled react: the chip clears and the
    /// Clear affordance's precondition (a visible own reaction) held.
    func testClearOnLiveRowAfterSettledReactClearsChip() async throws {
        let (_, viewModel) = try await makeFixture(sessionID: "s-9")
        try await Task.sleep(for: .milliseconds(50))

        await viewModel.send("live question")
        await flush()
        await viewModel.react(rowID: nil, kind: .user, emoji: "👍")
        await flush()

        // After promotion the row is durable — clear addresses row_id.
        await viewModel.clearReaction(rowID: nil, kind: .user)
        await flush()

        let row = viewModel.transcript.first { $0.text == "live question" }
        XCTAssertEqual(row?.reactions ?? [], [], "cleared live-row reaction renders none")
    }

    // MARK: - Fail-closed default

    func testReactWithoutCapableSessionSurfacesHonestError() async throws {
        // A session WITHOUT ReactionCapable (the ReactionCapableSession's
        // base double shape, capability omitted): the VM must keep the
        // fail-closed default and surface its honest error.
        let session = PlainSession()
        let cache = try SwiftDataCacheStore.makeInMemory()
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default"))
        let viewModel = ConversationViewModel(
            session: session,
            cache: cache,
            route: route,
            sessionID: "s-1",
            statusInterval: .milliseconds(10))
        await viewModel.start()

        await viewModel.react(rowID: "1", emoji: "👍")
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertNotNil(viewModel.reactionError, "fail-closed seam surfaces an honest error")
        XCTAssertTrue(viewModel.reactionError?.contains("gateway not configured") ?? false)
    }

    /// Minimal non-capable session double — ConversationSessionProviding
    /// only (no ReactionCapable), so the VM's one-cast falls through to the
    /// fail-closed default.
    private final class PlainSession: ConversationSessionProviding, @unchecked Sendable {
        let gatewayID = GatewayID(rawValue: "workstation")
        var status: GatewayStatus { .online }
        var liveness: ConnectionLivenessSnapshot? { nil }
        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "epoch-1", heartbeatEnabled: false, changeEventsEnabled: true)
        }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: "MacBook") }
        func reauthenticate() async throws {}
        var conversation: any ConversationProviding { PlainConversation() }
        var replay: any ReplayProviding { PlainReplay() }
        var history: any SessionHistoryProviding { PlainHistory() }

        private struct PlainConversation: ConversationProviding {
            func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
                ConversationSession(sessionID: "s-1", profileName: "default")
            }
            func resumeSession(sessionID: String, lastEventID: Int? = nil) async throws -> ConversationSession {
                ConversationSession(sessionID: sessionID, profileName: "default")
            }
            func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
                PromptSubmission(status: "streaming")
            }
            func interrupt(sessionID: String) async throws -> InterruptResult {
                InterruptResult(status: "interrupted")
            }
            var events: AsyncStream<ConversationEvent> { AsyncStream { _ in } }
            func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
        }
        private struct PlainReplay: ReplayProviding {
            let gatewayID = GatewayID(rawValue: "workstation")
            func watermarks() async -> [SessionEventWatermark] { [] }
            func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }
        }
        private struct PlainHistory: SessionHistoryProviding {
            func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
                SessionHistory(sessionID: sessionID, count: 0, messages: [])
            }
            func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
                SessionStatus.parse(output: "Session ID: \(sessionID)")
            }
        }
    }
}
