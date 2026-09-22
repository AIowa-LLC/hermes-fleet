import XCTest
import FleetCore
@testable import FleetUI

@MainActor
final class BridgedRoomRelayTests: XCTestCase {
    private func store() -> BridgedRooms.Store {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return BridgedRooms.Store(url: directory.appendingPathComponent("rooms.json"))
    }

    private func member(_ gateway: String, _ profile: String) -> BridgedRooms.MemberRef {
        .init(gatewayID: gateway, profile: profile, displayName: profile, routeID: "\(gateway)/\(profile)")
    }

    func testImmediateRepliesReachCorrectMembersAcrossGateways() async throws {
        let store = store()
        let first = ImmediateConversation()
        let second = ImmediateConversation()
        let sessions = ["alpha": Session(gatewayID: .init(rawValue: "alpha"), client: first),
                        "beta": Session(gatewayID: .init(rawValue: "beta"), client: second)]
        try await store.upsert(.init(roomKey: "room", name: "Test", members: [member("alpha", "research"), member("beta", "writer")], createdAt: 0))
        let relay = BridgedRoomRelay(store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await relay.send(roomID: "room", text: "Hello", threadID: nil)
        // The fan-out is detached (F1): replies land shortly AFTER send
        // returns. Bounded wait for both, then assert attribution.
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return (record?.events.filter { $0.kind == "message.member" }.count ?? 0) == 2
        }
        let stored = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(record.events.filter { $0.kind == "message.user" }.count, 1)
        let replies = record.events.filter { $0.kind == "message.member" }
        XCTAssertEqual(Set(replies.compactMap(\.payloadText)), ["reply-research", "reply-writer"])
        XCTAssertEqual(Set(replies.map(\.actorID)), ["alpha/research", "beta/writer"])
        XCTAssertFalse(record.events.contains { $0.kind == "turn.failed" })
    }

    func testMemberSessionsResumeAcrossReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rooms.json")
        let store = BridgedRooms.Store(url: url)
        let conversation = ImmediateConversation()
        let sessions = ["alpha": Session(
            gatewayID: .init(rawValue: "alpha"), client: conversation)]
        try await store.upsert(.init(
            roomKey: "room", name: "Test", members: [member("alpha", "research")],
            createdAt: 0))

        let firstRelay = BridgedRoomRelay(
            store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await firstRelay.send(roomID: "room", text: "First", threadID: nil)

        // A new relay instance models app relaunch; the persisted route map
        // must select resumeSession rather than creating a fresh context.
        let secondRelay = BridgedRoomRelay(
            store: BridgedRooms.Store(url: url),
            resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        // Wait for the FIRST fan-out to persist its bridge session before
        // sending again — the fan-out is detached (F1), so an immediate
        // second send would race the route-map write.
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return record?.bridgeSessionIDs["alpha/research"] != nil
        }
        _ = try await secondRelay.send(roomID: "room", text: "Second", threadID: nil)
        try await waitUntil(timeout: 5) { conversation.resumeIDs.count == 1 }
        XCTAssertEqual(conversation.createCount, 1)
        XCTAssertEqual(conversation.resumeIDs, ["research"])
    }

    /// B76 round 2: an expired bridge session is REBUILT with a fresh
    /// gateway session (the room log re-establishes context) — the B75
    /// "explicitly failed / create a new Group" contract is replaced.
    func testExpiredMemberSessionIsRebuiltWithFreshContext() async throws {
        let store = store()
        let conversation = ImmediateConversation()
        let sessions = ["alpha": Session(
            gatewayID: .init(rawValue: "alpha"), client: conversation)]
        try await store.upsert(.init(
            roomKey: "room", name: "Test", members: [member("alpha", "research")],
            createdAt: 0))
        let relay = BridgedRoomRelay(
            store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await relay.send(roomID: "room", text: "First", threadID: nil)
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return record?.bridgeSessionIDs["alpha/research"] != nil
        }
        // The gateway loses the session; the room must survive it.
        conversation.expireOnResume = true
        _ = try await relay.send(roomID: "room", text: "Second", threadID: nil)
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return record?.events.contains { $0.reasonCode == "bridge_session_rebuilt" } == true
        }
        XCTAssertEqual(conversation.createCount, 2, "expired context is rebuilt, not bricked")
        let stored = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored)
        XCTAssertFalse(record.events.contains {
            $0.reasonCode == "bridge_session_expired_context_lost"
        }, "the brick contract is gone")
        // The gateway stabilizes: the next turn RESUMES the rebuilt session.
        conversation.expireOnResume = false
        _ = try await relay.send(roomID: "room", text: "Third", threadID: nil)
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return (record?.events.filter { $0.kind == "message.member" }.count ?? 0) == 3
        }
        XCTAssertEqual(conversation.createCount, 2, "a stable gateway resumes the rebuilt session")
    }

    func testReplayDrainsAllPagesOnReentry() async throws {
        let store = store()
        let events = (1...205).map { seq in
            BridgedRooms.EventRecord(seq: seq, eventID: "event-\(seq)", kind: "message.user", actorKind: "user", actorID: "user", payloadText: "Message \(seq)", createdAt: Double(seq))
        }
        let record = BridgedRooms.RoomRecord(roomKey: "room", name: "Test", members: [], createdAt: 0, events: events)
        try await store.upsert(record)
        let relay = BridgedRoomRelay(store: store, resolver: { _ in nil })
        let first = try await relay.replay(roomID: "room", sinceSeq: 0, limit: 100)
        XCTAssertEqual(first.events.count, 100)
        XCTAssertTrue(first.hasMore)
        let vm = RoomChatViewModel(room: BridgedRooms.fleetRoom(for: record), commands: relay)
        await vm.start()
        XCTAssertEqual(vm.transcript.count, 205)
        XCTAssertNil(vm.errorMessage)
    }

    func testUITestResetClearsPersistedRoomsBeforeHydration() async throws {
        let store = store()
        try await store.upsert(.init(roomKey: "old", name: "Old", members: [], createdAt: 0))
        await store.resetForUITests()
        let rooms = await store.roomsSnapshot()
        XCTAssertTrue(rooms.isEmpty)
    }

    func testUITestResetClearsOnlyRoomDrafts() throws {
        let name = "draft-reset-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("stale", forKey: "fleet.room.draft.v1.room")
        defaults.set("keep", forKey: "unrelated")
        RoomDraftStore.resetForUITests(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: "fleet.room.draft.v1.room"))
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
    }

    func testUnavailableMemberIsAnAttributedFailure() async throws {
        let store = store()
        try await store.upsert(.init(roomKey: "room", name: "Test", members: [member("missing", "writer")], createdAt: 0))
        let relay = BridgedRoomRelay(store: store, resolver: { _ in nil })
        _ = try await relay.send(roomID: "room", text: "Hello", threadID: nil)
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return record?.events.last?.reasonCode == "bridge_member_unreachable"
        }
        let stored = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(record.events.last?.reasonCode, "bridge_member_unreachable")
        XCTAssertEqual(record.events.last?.actorID, "missing/writer")
    }

    // MARK: - F1: non-blocking send

    func testSendReturnsImmediatelyWithoutMemberReplies() async throws {
        let store = store()
        let slow = NeverCompletingConversation()
        let sessions = ["alpha": Session(
            gatewayID: .init(rawValue: "alpha"), client: slow)]
        try await store.upsert(.init(
            roomKey: "room", name: "Test", members: [member("alpha", "research")],
            createdAt: 0))
        let relay = BridgedRoomRelay(
            store: store, resolver: { sessions[$0.rawValue] },
            memberTimeout: 3600, lateCollectionWindow: 7200)
        let start = Date()
        _ = try await relay.send(roomID: "room", text: "Hello", threadID: nil)
        // The user message is durable and send returned WITHOUT waiting for
        // the (never-arriving) member reply: a full hour window must not
        // hold the composer.
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5, "send must not block on member turns")
        let stored = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(record.events.filter { $0.kind == "message.user" }.count, 1)
        _ = try? await relay.stop(roomID: "room")
    }

    // MARK: - F3: late reply after a timeout note

    func testLateReplyLandsAfterTimeoutNote() async throws {
        let store = store()
        let late = LateReplyConversation(delay: 0.6)
        let sessions = ["alpha": Session(
            gatewayID: .init(rawValue: "alpha"), client: late)]
        try await store.upsert(.init(
            roomKey: "room", name: "Test", members: [member("alpha", "research")],
            createdAt: 0))
        let relay = BridgedRoomRelay(
            store: store, resolver: { sessions[$0.rawValue] },
            memberTimeout: 0.3, lateCollectionWindow: 30)
        _ = try await relay.send(roomID: "room", text: "Hello", threadID: nil)
        // Interim: the timeout note lands quickly...
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return record?.events.contains { $0.reasonCode == "member_timeout" } == true
        }
        // ...and the late reply appends after the fact.
        try await waitUntil(timeout: 5, diagnostics: { await self.debugEvents(store) }) {
            let record = await store.record(roomKey: "room")
            return record?.events.contains {
                $0.kind == "message.member" && $0.payloadText == "late-reply"
            } == true
        }
        _ = try? await relay.stop(roomID: "room")
    }

    // MARK: - F2: live transcript notification

    func testStoreAppendNotifiesChangeSubscribers() async throws {
        let store = store()
        try await store.upsert(.init(roomKey: "room", name: "Test", members: [], createdAt: 0))
        let changes = await store.changes()
        try await store.append(events: [.init(
            seq: 1, eventID: "e1", kind: "message.member", actorKind: "member",
            actorID: "alpha/research", payloadText: "hi", createdAt: 1)], to: "room")
        // The stream buffers yields; consume on a detached task (the
        // iterator is not Sendable) with a bounded race against a timeout.
        let received: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var iterator = changes.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        XCTAssertEqual(received, "room", "store appends must notify subscribers")
    }

    func testLiveTailUpdatesTranscriptWithoutReentry() async throws {
        let store = store()
        let late = LateReplyConversation(delay: 0.4)
        let sessions = ["alpha": Session(
            gatewayID: .init(rawValue: "alpha"), client: late)]
        try await store.upsert(.init(
            roomKey: "room", name: "Test", members: [member("alpha", "research")],
            createdAt: 0))
        let relay = BridgedRoomRelay(
            store: store, resolver: { sessions[$0.rawValue] },
            memberTimeout: 0.2, lateCollectionWindow: 30)
        let stored0 = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored0)
        let vm = RoomChatViewModel(room: BridgedRooms.fleetRoom(for: record), commands: relay)
        await vm.start()
        XCTAssertEqual(vm.transcript.count, 0, "room starts empty")
        _ = try await relay.send(roomID: "room", text: "Hello", threadID: nil)
        // The user row renders via the live tail WITHOUT any re-entry call.
        try await waitUntil(timeout: 5, diagnostics: { await self.debugEvents(store) }) {
            vm.transcript.contains { $0.text == "Hello" }
        }
        // And the late member reply too.
        try await waitUntil(timeout: 5, diagnostics: { await self.debugEvents(store) }) {
            vm.transcript.contains { $0.text == "late-reply" }
        }
        _ = try? await relay.stop(roomID: "room")
    }

    // MARK: - F5: stop cancels tails; retry re-sends the last user message

    func testStopCancelsLiveTails() async throws {
        let store = store()
        let slow = NeverCompletingConversation()
        let sessions = ["alpha": Session(
            gatewayID: .init(rawValue: "alpha"), client: slow)]
        try await store.upsert(.init(
            roomKey: "room", name: "Test", members: [member("alpha", "research")],
            createdAt: 0))
        let relay = BridgedRoomRelay(
            store: store, resolver: { sessions[$0.rawValue] },
            memberTimeout: 3600, lateCollectionWindow: 7200)
        _ = try await relay.send(roomID: "room", text: "Hello", threadID: nil)
        let cancelled = try await relay.stop(roomID: "room")
        XCTAssertEqual(cancelled, 1)
        try await Task.sleep(for: .milliseconds(200))
        let stored = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored)
        XCTAssertFalse(record.events.contains { $0.kind == "turn.failed" },
                      "cancelling a live tail must not fabricate a failure note")
    }

    func testRetryResendsLastUserMessage() async throws {
        let store = store()
        let conversation = ImmediateConversation()
        let sessions = ["alpha": Session(
            gatewayID: .init(rawValue: "alpha"), client: conversation)]
        try await store.upsert(.init(
            roomKey: "room", name: "Test", members: [member("alpha", "research")],
            createdAt: 0))
        let relay = BridgedRoomRelay(
            store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await relay.send(roomID: "room", text: "Original", threadID: nil)
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return (record?.events.filter { $0.kind == "message.member" }.count ?? 0) == 1
        }
        _ = try await relay.retry(roomID: "room", taskID: "latest")
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return (record?.events.filter { $0.kind == "message.member" }.count ?? 0) == 2
        }
        let stored = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(record.events.filter { $0.kind == "message.user" }.count, 2,
                       "retry re-sends the room's last user message")
        XCTAssertEqual(record.events.filter { $0.kind == "message.member" }.count, 2)
    }

    // MARK: - Build 76: group-context parity

    /// Captures every prompt submitted to a member's bridge session and
    /// replies with configurable text (the mock gateway for group-context
    /// assertions — the SUBMITTED text is the artifact under test).
    private final class RecordingConversation: ConversationProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var subscribers: [AsyncStream<ConversationEvent>.Continuation] = []
        private var _submittedTexts: [String] = []
        private(set) var createCount = 0
        var replyText: String = "real reply"
        var submitError: Error?
        var expireOnResume = false

        var submittedTexts: [String] { lock.withLock { _submittedTexts } }

        var events: AsyncStream<ConversationEvent> {
            let pair = AsyncStream<ConversationEvent>.makeStream()
            lock.withLock { subscribers.append(pair.continuation) }
            return pair.stream
        }
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            lock.withLock { createCount += 1 }
            return ConversationSession(sessionID: profile ?? "default")
        }
        func resumeSession(sessionID: String, lastEventID: Int?, profile: String?) async throws -> ConversationSession {
            if expireOnResume { throw ConversationError.sessionNotFound(sessionID) }
            return .init(sessionID: sessionID)
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
            lock.withLock { _submittedTexts.append(text) }
            if let submitError { throw submitError }
            let streams = lock.withLock { subscribers }
            for stream in streams {
                stream.yield(.messageComplete(sessionID: sessionID, text: replyText, status: nil, error: nil))
            }
            return .init(status: "streaming")
        }
        func interrupt(sessionID: String) async throws -> InterruptResult { .init(status: "interrupted") }
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
    }

    /// Blocks `wait()` until `open()` — gates the relay's session resolver so
    /// store mutations between fan-out and turn start are deterministic.
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    private func contextRoom(
        _ store: BridgedRooms.Store, name: String = "Launch Crew"
    ) async throws {
        try await store.upsert(.init(
            roomKey: "room", name: name,
            members: [
                member("alpha", "research"),
                member("beta", "writer"),
            ], createdAt: 0))
    }

    // Test group B: the relay submits the FRAMED group prompt, not raw text.

    func testRelaySubmitsFramedGroupPromptToEveryMember() async throws {
        let store = store()
        try await contextRoom(store)
        let research = RecordingConversation()
        let writer = RecordingConversation()
        let sessions = ["alpha": Session(gatewayID: .init(rawValue: "alpha"), client: research),
                        "beta": Session(gatewayID: .init(rawValue: "beta"), client: writer)]
        let relay = BridgedRoomRelay(store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await relay.send(roomID: "room", text: "Who is in this chat?", threadID: nil)
        try await waitUntil(timeout: 5) {
            (research.submittedTexts.count == 1) && (writer.submittedTexts.count == 1)
        }
        // Each member's prompt frames the room, its own identity, the peer
        // roster, and the user message — with itself distinguished from its
        // peer (FR-01/FR-02).
        let researchPrompt = try XCTUnwrap(research.submittedTexts.first)
        XCTAssertTrue(researchPrompt.contains("[Group chat: \"Launch Crew\"]"))
        XCTAssertTrue(researchPrompt.contains("You are @research,"))
        XCTAssertTrue(researchPrompt.contains("writer (@writer) [on beta]"))
        XCTAssertTrue(researchPrompt.contains("User (user): Who is in this chat?"))
        let writerPrompt = try XCTUnwrap(writer.submittedTexts.first)
        XCTAssertTrue(writerPrompt.contains("You are @writer,"))
        XCTAssertTrue(writerPrompt.contains("research (@research) [on alpha]"))
        // Raw user text must NOT be the submitted payload (FR-06).
        XCTAssertEqual(researchPrompt == "Who is in this chat?", false)
    }

    func testRawUserMessagePersistsUnchanged() async throws {
        let store = store()
        try await contextRoom(store)
        let research = RecordingConversation()
        let sessions = ["alpha": Session(gatewayID: .init(rawValue: "alpha"), client: research),
                        "beta": Session(gatewayID: .init(rawValue: "beta"), client: RecordingConversation())]
        let relay = BridgedRoomRelay(store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await relay.send(roomID: "room", text: "plain words only", threadID: nil)
        try await waitUntil(timeout: 5) { research.submittedTexts.count == 1 }
        let stored = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(
            record.events.first { $0.kind == "message.user" }?.payloadText, "plain words only",
            "the user's original text persists unchanged (FR-06)")
        XCTAssertFalse(record.events.contains {
            $0.kind == "message.user" && $0.payloadText?.contains("[Group chat:") == true
        }, "the internal prompt wrapper must never be persisted as the user's message")
    }

    // Test group C: shared transcript delivery across turns.

    func testEachMemberReceivesPeerReplyOnNextTurnWithoutRedelivery() async throws {
        let store = store()
        try await contextRoom(store)
        let research = RecordingConversation()
        let writer = RecordingConversation()
        research.replyText = "from research"
        writer.replyText = "from writer"
        let sessions = ["alpha": Session(gatewayID: .init(rawValue: "alpha"), client: research),
                        "beta": Session(gatewayID: .init(rawValue: "beta"), client: writer)]
        let relay = BridgedRoomRelay(store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await relay.send(roomID: "room", text: "first turn", threadID: nil)
        try await waitUntil(timeout: 5) {
            (research.submittedTexts.count == 1) && (writer.submittedTexts.count == 1)
        }
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return (record?.events.filter { $0.kind == "message.member" }.count ?? 0) == 2
        }
        _ = try await relay.send(roomID: "room", text: "second turn", threadID: nil)
        try await waitUntil(timeout: 5) {
            (research.submittedTexts.count == 2) && (writer.submittedTexts.count == 2)
        }
        // The researcher's second prompt carries the peer's reply with
        // attribution and the new user message — but NOT the first turn's
        // already-delivered user message (no full-history injection). Its
        // own reply may appear as "(you)" when the peer spoke after it
        // (Desktop's contiguous-only advance).
        let second = try XCTUnwrap(research.submittedTexts.last)
        XCTAssertTrue(second.contains("writer [beta]: from writer"), "peer reply must be delivered with attribution")
        XCTAssertFalse(second.contains("research:"),
                      "own already-acknowledged reply must not be re-delivered un-attributed")
        XCTAssertTrue(second.contains("User (user): second turn"))
        XCTAssertFalse(second.contains("User (user): first turn"),
                      "already-delivered events must not be re-injected (FR-04)")
        XCTAssertEqual(second.components(separatedBy: "User (user):").count - 1, 1,
                       "exactly one user line in the second delta")
    }

    // Test group D: persistence and recovery of delivery state.

    func testDeliveryWatermarksSurviveRelayReconstruction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rooms.json")
        let store = BridgedRooms.Store(url: url)
        try await contextRoom(store)
        let research = RecordingConversation()
        let sessions = ["alpha": Session(gatewayID: .init(rawValue: "alpha"), client: research),
                        "beta": Session(gatewayID: .init(rawValue: "beta"), client: RecordingConversation())]
        let firstRelay = BridgedRoomRelay(store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await firstRelay.send(roomID: "room", text: "before restart", threadID: nil)
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return (record?.events.filter { $0.kind == "message.member" }.count ?? 0) == 2
        }
        // A new relay over the SAME persisted file models an app relaunch.
        let secondRelay = BridgedRoomRelay(
            store: BridgedRooms.Store(url: url),
            resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await secondRelay.send(roomID: "room", text: "after restart", threadID: nil)
        try await waitUntil(timeout: 5) { research.submittedTexts.count == 2 }
        let postRestart = try XCTUnwrap(research.submittedTexts.last)
        XCTAssertTrue(postRestart.contains("User (user): after restart"))
        XCTAssertFalse(postRestart.contains("User (user): before restart"),
                       "delivery state must survive restart without full-history re-injection")
        // Own-reply acknowledgment is contiguous-only (Desktop): when the
        // peer's reply landed first, the member's own reply is legitimately
        // re-delivered — but always attributed "(you)", never un-attributed.
        XCTAssertFalse(postRestart.contains("research:"),
                       "own reply never re-delivered un-attributed")
    }

    // Test group E: failures, passes, membership.

    func testFailedSubmissionDoesNotDiscardTranscriptEvents() async throws {
        let store = store()
        try await contextRoom(store)
        let research = RecordingConversation()
        research.submitError = ConversationError.notConnected
        let writer = RecordingConversation()
        let sessions = ["alpha": Session(gatewayID: .init(rawValue: "alpha"), client: research),
                        "beta": Session(gatewayID: .init(rawValue: "beta"), client: writer)]
        let relay = BridgedRoomRelay(store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await relay.send(roomID: "room", text: "lost turn", threadID: nil)
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return record?.events.contains { $0.reasonCode == "gateway_unreachable" } == true
        }
        // Recovery: the same member succeeds on the next turn and STILL
        // receives the missed user message (watermark was not advanced).
        research.submitError = nil
        _ = try await relay.send(roomID: "room", text: "recovery turn", threadID: nil)
        try await waitUntil(timeout: 5) { research.submittedTexts.count == 2 }
        let recovery = try XCTUnwrap(research.submittedTexts.last)
        XCTAssertTrue(recovery.contains("User (user): lost turn"),
                      "a failed submission must not silently discard transcript events (FR-04)")
        XCTAssertTrue(recovery.contains("User (user): recovery turn"))
    }

    func testPassReplyIsNotAppendedToTranscript() async throws {
        let store = store()
        try await contextRoom(store)
        let research = RecordingConversation()
        research.replyText = "(pass)"
        let writer = RecordingConversation()
        let sessions = ["alpha": Session(gatewayID: .init(rawValue: "alpha"), client: research),
                        "beta": Session(gatewayID: .init(rawValue: "beta"), client: writer)]
        let relay = BridgedRoomRelay(store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await relay.send(roomID: "room", text: "anyone?", threadID: nil)
        try await waitUntil(timeout: 5) { research.submittedTexts.count == 1 }
        try await Task.sleep(for: .milliseconds(300))
        let stored = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored)
        XCTAssertFalse(record.events.contains {
            $0.kind == "message.member" && $0.actorID == "alpha/research"
        }, "a (pass) is silence, not a transcript reply (FR-07)")
        XCTAssertFalse(record.events.contains {
            $0.kind == "turn.failed" && $0.actorID == "alpha/research"
        }, "passing is not a failure")
        XCTAssertEqual(record.events.filter { $0.kind == "message.member" }.count, 1,
                       "the non-passing peer still replies")
    }

    func testMemberWithNoUndeliveredEventsSkipsItsTurn() async throws {
        let store = store()
        try await contextRoom(store)
        let research = RecordingConversation()
        let sessions = ["alpha": Session(gatewayID: .init(rawValue: "alpha"), client: research),
                        "beta": Session(gatewayID: .init(rawValue: "beta"), client: RecordingConversation())]
        let relay = BridgedRoomRelay(store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await relay.send(roomID: "room", text: "one", threadID: nil)
        try await waitUntil(timeout: 5) { research.submittedTexts.count == 1 }
        // Force the researcher's watermark past the whole log — every event
        // already delivered. The next fan-out must SKIP its turn entirely
        // (Desktop: `if (!delta.length) return null`) — no submission, no
        // failure note, no transcript churn.
        try await store.advanceDeliveryWatermark(roomKey: "room", routeID: "alpha/research", to: 999)
        _ = try await relay.send(roomID: "room", text: "two", threadID: nil)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(research.submittedTexts.count, 1,
                       "a member with no undelivered events must not be submitted a turn")
        let stored = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored)
        XCTAssertFalse(record.events.contains {
            $0.kind == "turn.failed" && $0.actorID == "alpha/research"
        }, "a skipped turn is not a failure")
    }

    // MARK: Build 76 dogfood round 2: recovery + identity rendering

    func testExpiredBridgeSessionIsRebuiltNotBricked() async throws {
        let store = store()
        try await contextRoom(store)
        let research = ImmediateConversation()
        let sessions = ["alpha": Session(gatewayID: .init(rawValue: "alpha"), client: research)]
        let relay = BridgedRoomRelay(store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await relay.send(roomID: "room", text: "first turn", threadID: nil)
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return record?.bridgeSessionIDs["alpha/research"] != nil
        }
        // The gateway loses the session (restart / store rotation).
        research.expireOnResume = true
        _ = try await relay.send(roomID: "room", text: "who is in this chat?", threadID: nil)
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return (record?.events.filter { $0.kind == "message.member" }.count ?? 0) == 2
        }
        let stored = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored)
        // NO brick: the expired-context failure contract is gone.
        XCTAssertFalse(record.events.contains {
            $0.reasonCode == "bridge_session_expired_context_lost"
        }, "an expired bridge session must be rebuilt, never bricked")
        // The rebuild is honestly noted as room activity, not an error row.
        XCTAssertTrue(record.events.contains {
            $0.kind == "room.activity" && $0.reasonCode == "bridge_session_rebuilt"
        }, "the rebuild lands a durable activity note")
        // A fresh session was created and persisted.
        XCTAssertEqual(research.createCount, 2, "rebuild creates a replacement session")
        let record2Value = await store.record(roomKey: "room")
        let record2 = try XCTUnwrap(record2Value)
        XCTAssertNotNil(record2.bridgeSessionIDs["alpha/research"])
        // The reply landed normally.
        XCTAssertTrue(record.events.contains {
            $0.kind == "message.member" && $0.payloadText == "reply-research"
        })
    }

    func testRebuiltSessionReceivesBoundedRecentHistoryIgnoringWatermark() async throws {
        let store = store()
        try await contextRoom(store)
        let research = RecordingConversation()
        research.expireOnResume = true
        let sessions = ["alpha": Session(gatewayID: .init(rawValue: "alpha"), client: research)]
        let relay = BridgedRoomRelay(store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        // Seed delivered history the old session already consumed.
        try await store.upsert(BridgedRooms.RoomRecord(
            roomKey: "room", name: "Launch Crew",
            members: [member("alpha", "research"), member("beta", "writer")],
            createdAt: 0,
            events: (1...30).map { seq in
                BridgedRooms.EventRecord(
                    seq: seq, eventID: "e\(seq)", kind: "message.user", actorKind: "user",
                    actorID: "local-user", payloadText: "m\(seq)", createdAt: Double(seq))
            },
            bridgeSessionIDs: ["alpha/research": "old-session"],
            deliveryWatermarks: ["alpha/research": 30]))
        _ = try await relay.send(roomID: "room", text: "after expiry", threadID: nil)
        try await waitUntil(timeout: 5) { research.submittedTexts.count == 1 }
        let rebuilt = try XCTUnwrap(research.submittedTexts.first)
        // A context-less session needs history even though the watermark
        // says delivered — but bounded to the 24-line history window.
        XCTAssertTrue(rebuilt.contains("User (user): m30"), "the newest line rides the rebuild")
        XCTAssertTrue(rebuilt.contains("omitted since your last turn"),
                      "the over-long tail is marked as truncated")
        XCTAssertFalse(rebuilt.contains("User (user): m5"), "lines beyond the bound are cut")
        XCTAssertTrue(rebuilt.contains("User (user): after expiry"))
        // And the watermark re-anchors so the NEXT turn is incremental:
        // after the reply lands, the contiguous advance puts it on the
        // reply's own seq (well past the stale pre-rebuild value of 30).
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            guard let replySeq = record?.events.first(where: { $0.kind == "message.member" })?.seq else { return false }
            return record?.deliveryWatermarks["alpha/research"] == replySeq
        }
    }

    func testTwinDisplayNamesAreQualifiedAtPersistTime() async throws {
        let store = store()
        // Two bots named "default" on different gateways — the dogfood twin.
        try await store.upsert(.init(roomKey: "room", name: "Twins", members: [
            .init(gatewayID: "macbook-m5", profile: "default", displayName: "default",
                  routeID: "macbook-m5#default", gatewayLabel: "macbook-m5"),
            .init(gatewayID: "gaming-rig", profile: "default", displayName: "default",
                  routeID: "gaming-rig#default", gatewayLabel: "gaming-rig"),
        ], createdAt: 0))
        let macbook = RecordingConversation()
        let rig = RecordingConversation()
        let sessions = ["macbook-m5": Session(gatewayID: .init(rawValue: "macbook-m5"), client: macbook),
                        "gaming-rig": Session(gatewayID: .init(rawValue: "gaming-rig"), client: rig)]
        let relay = BridgedRoomRelay(store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await relay.send(roomID: "room", text: "hello", threadID: nil)
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return (record?.events.filter { $0.kind == "message.member" }.count ?? 0) == 2
        }
        let recordValue = await store.record(roomKey: "room")
        let record = try XCTUnwrap(recordValue)
        let speakers = Set(record.events
            .filter { $0.kind == "message.member" }
            .compactMap { $0.actorDisplayName })
        XCTAssertEqual(speakers, ["default · macbook-m5", "default · gaming-rig"],
                       "roster-duplicate display names persist qualified by source")
        // And the unique-name room stays plain.
        let store2 = self.store()
        try await contextRoom(store2)
        let research2 = RecordingConversation()
        let sessions2 = ["alpha": Session(gatewayID: .init(rawValue: "alpha"), client: research2),
                         "beta": Session(gatewayID: .init(rawValue: "beta"), client: RecordingConversation())]
        let relay2 = BridgedRoomRelay(store: store2, resolver: { sessions2[$0.rawValue] }, memberTimeout: 1)
        _ = try await relay2.send(roomID: "room", text: "hello", threadID: nil)
        try await waitUntil(timeout: 5) {
            let record = await store2.record(roomKey: "room")
            return (record?.events.filter { $0.kind == "message.member" }.count ?? 0) == 2
        }
        let plainValue = await store2.record(roomKey: "room")
        let plain = try XCTUnwrap(plainValue)
        XCTAssertEqual(Set(plain.events.filter { $0.kind == "message.member" }.compactMap { $0.actorDisplayName }),
                       ["research", "writer"],
                       "unique names are never decorated")
    }

    func testRemovedMemberDoesNotReceiveGroupSubmissions() async throws {
        let store = store()
        try await contextRoom(store)
        let research = RecordingConversation()
        let writer = RecordingConversation()
        let sessions = ["alpha": Session(gatewayID: .init(rawValue: "alpha"), client: research),
                        "beta": Session(gatewayID: .init(rawValue: "beta"), client: writer)]
        let gate = Gate()
        let relay = BridgedRoomRelay(store: store, resolver: { gatewayID in
            await gate.wait()
            return sessions[gatewayID.rawValue]
        }, memberTimeout: 1)
        _ = try await relay.send(roomID: "room", text: "roster changed", threadID: nil)
        // Remove the researcher from the authoritative roster while the
        // fan-out is still connecting (FR-09): the fresh record read at turn
        // start must skip the removed member.
        let currentRecord = await store.record(roomKey: "room")
        let current = try XCTUnwrap(currentRecord)
        try await store.upsert(.init(
            roomKey: "room", name: current.name,
            members: current.members.filter { $0.routeID != "alpha/research" },
            createdAt: current.createdAt, events: current.events,
            bridgeSessionIDs: current.bridgeSessionIDs,
            deliveryWatermarks: current.deliveryWatermarks))
        await gate.open()
        try await waitUntil(timeout: 5) { writer.submittedTexts.count == 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(research.submittedTexts.count, 0,
                       "a removed member must not receive future group submissions")
    }

    /// Poll until `condition` holds (bounded) — async store reads make
    /// deterministic event-order assertions brittle otherwise. On timeout,
    /// print the diagnostics string so failures are diagnosable from logs.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval,
        diagnostics: (() async -> String)? = nil,
        _ condition: @escaping () async -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let diagnostics {
            print("WAIT-DBG:", await diagnostics())
        }
        XCTFail("condition not met within \(timeout)s")
        return false
    }

    /// Diagnostic snapshot of one room's persisted event sequence.
    private func debugEvents(_ store: BridgedRooms.Store) async -> String {
        guard let record = await store.record(roomKey: "room") else { return "<no record>" }
        return record.events
            .map { "\($0.seq):\($0.kind)\($0.reasonCode.map { "/\($0)" } ?? "")=\(($0.payloadText ?? "").prefix(28))" }
            .joined(separator: " | ")
    }

    private final class ImmediateConversation: ConversationProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var subscribers: [AsyncStream<ConversationEvent>.Continuation] = []
        private(set) var createCount = 0
        private(set) var resumeIDs: [String] = []
        var expireOnResume = false
        var events: AsyncStream<ConversationEvent> {
            let pair = AsyncStream<ConversationEvent>.makeStream()
            lock.withLock { subscribers.append(pair.continuation) }
            return pair.stream
        }
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            lock.withLock { createCount += 1 }
            return ConversationSession(sessionID: profile ?? "default")
        }
        func resumeSession(sessionID: String, lastEventID: Int?, profile: String?) async throws -> ConversationSession {
            lock.withLock { resumeIDs.append(sessionID) }
            if expireOnResume { throw ConversationError.sessionNotFound(sessionID) }
            return .init(sessionID: sessionID)
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
            // Complete before returning, with an unrelated session event first.
            let streams = lock.withLock { subscribers }
            for stream in streams {
                stream.yield(.messageComplete(sessionID: "unrelated", text: "wrong", status: nil, error: nil))
                stream.yield(.messageComplete(sessionID: sessionID, text: "reply-\(sessionID)", status: nil, error: nil))
            }
            return .init(status: "streaming")
        }
        func interrupt(sessionID: String) async throws -> InterruptResult { .init(status: "interrupted") }
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
    }

    /// A conversation whose reply completes only after `delay` seconds —
    /// models a real gateway turn outlasting the relay's window.
    private final class LateReplyConversation: ConversationProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var subscribers: [AsyncStream<ConversationEvent>.Continuation] = []
        private let delay: TimeInterval
        init(delay: TimeInterval) { self.delay = delay }
        var events: AsyncStream<ConversationEvent> {
            let pair = AsyncStream<ConversationEvent>.makeStream()
            lock.withLock { subscribers.append(pair.continuation) }
            return pair.stream
        }
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            ConversationSession(sessionID: profile ?? "default")
        }
        func resumeSession(sessionID: String, lastEventID: Int?, profile: String?) async throws -> ConversationSession {
            return .init(sessionID: sessionID)
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                // Read the subscriber list AT FIRE TIME — mirrors the real
                // client's synchronous fan-out registration, where a
                // subscription taken after submitPrompt still receives the
                // terminal event.
                let streams = lock.withLock { subscribers }
                for stream in streams {
                    stream.yield(.messageComplete(
                        sessionID: sessionID, text: "late-reply", status: nil, error: nil))
                }
            }
            return .init(status: "streaming")
        }
        func interrupt(sessionID: String) async throws -> InterruptResult { .init(status: "interrupted") }
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
    }

    /// A conversation that never emits anything — models a member whose
    /// turn runs indefinitely (or whose events never match).
    private final class NeverCompletingConversation: ConversationProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var subscribers: [AsyncStream<ConversationEvent>.Continuation] = []
        var events: AsyncStream<ConversationEvent> {
            let pair = AsyncStream<ConversationEvent>.makeStream()
            lock.withLock { subscribers.append(pair.continuation) }
            return pair.stream
        }
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            ConversationSession(sessionID: profile ?? "default")
        }
        func resumeSession(sessionID: String, lastEventID: Int?, profile: String?) async throws -> ConversationSession {
            return .init(sessionID: sessionID)
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
            .init(status: "streaming")
        }
        func interrupt(sessionID: String) async throws -> InterruptResult { .init(status: "interrupted") }
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
    }

    private struct Session: ConversationSessionProviding {
        let gatewayID: GatewayID
        let client: any ConversationProviding
        var status: GatewayStatus { .online }
        var conversation: any ConversationProviding { client }
        var replay: any ReplayProviding { EmptyReplay(gatewayID: gatewayID) }
        var history: any SessionHistoryProviding { EmptyHistory() }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func reauthenticate() async throws {}
        func currentGateway() async -> FleetGateway { .init(id: gatewayID, displayName: "Test", endpoint: nil) }
    }
    private struct EmptyReplay: ReplayProviding {
        let gatewayID: GatewayID
        func watermarks() async -> [SessionEventWatermark] { [] }
        func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }
    }
    private struct EmptyHistory: SessionHistoryProviding {
        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory { .init(sessionID: sessionID, count: 0, messages: []) }
        func fetchSessionStatus(sessionID: String) async throws -> SessionStatus { .parse(output: "") }
    }
}
