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

    func testExpiredMemberSessionStaysExplicitlyFailed() async throws {
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
        // Wait for the first fan-out to persist its bridge session; the
        // fan-out is detached (F1), so an immediate second send would race
        // the route-map write and create a second session.
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return record?.bridgeSessionIDs["alpha/research"] != nil
        }
        conversation.expireOnResume = true
        _ = try await relay.send(roomID: "room", text: "Second", threadID: nil)
        _ = try await relay.send(roomID: "room", text: "Third", threadID: nil)
        try await waitUntil(timeout: 5) {
            let record = await store.record(roomKey: "room")
            return (record?.events.filter {
                $0.reasonCode == "bridge_session_expired_context_lost" }.count ?? 0) == 2
        }
        XCTAssertEqual(conversation.createCount, 1, "expired context is never silently replaced")
        let stored = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(
            record.events.filter { $0.reasonCode == "bridge_session_expired_context_lost" }.count,
            2)
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
            .init(sessionID: sessionID)
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
            .init(sessionID: sessionID)
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
