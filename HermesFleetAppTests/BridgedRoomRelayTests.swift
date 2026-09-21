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
        await store.upsert(.init(roomKey: "room", name: "Test", members: [member("alpha", "research"), member("beta", "writer")], createdAt: 0))
        let relay = BridgedRoomRelay(store: store, resolver: { sessions[$0.rawValue] }, memberTimeout: 1)
        _ = try await relay.send(roomID: "room", text: "Hello", threadID: nil)
        let stored = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(record.events.filter { $0.kind == "message.user" }.count, 1)
        let replies = record.events.filter { $0.kind == "message.member" }
        XCTAssertEqual(Set(replies.compactMap(\.payloadText)), ["reply-research", "reply-writer"])
        XCTAssertEqual(Set(replies.map(\.actorID)), ["alpha/research", "beta/writer"])
        XCTAssertFalse(record.events.contains { $0.kind == "turn.failed" })
    }

    func testReplayDrainsAllPagesOnReentry() async throws {
        let store = store()
        let events = (1...205).map { seq in
            BridgedRooms.EventRecord(seq: seq, eventID: "event-\(seq)", kind: "message.user", actorKind: "user", actorID: "user", payloadText: "Message \(seq)", createdAt: Double(seq))
        }
        let record = BridgedRooms.RoomRecord(roomKey: "room", name: "Test", members: [], createdAt: 0, events: events)
        await store.upsert(record)
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
        await store.upsert(.init(roomKey: "old", name: "Old", members: [], createdAt: 0))
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
        await store.upsert(.init(roomKey: "room", name: "Test", members: [member("missing", "writer")], createdAt: 0))
        let relay = BridgedRoomRelay(store: store, resolver: { _ in nil })
        _ = try await relay.send(roomID: "room", text: "Hello", threadID: nil)
        let stored = await store.record(roomKey: "room")
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(record.events.last?.reasonCode, "gateway_unavailable")
        XCTAssertEqual(record.events.last?.actorID, "missing/writer")
    }

    private final class ImmediateConversation: ConversationProviding, @unchecked Sendable {
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
        func resumeSession(sessionID: String, lastEventID: Int?, profile: String?) async throws -> ConversationSession { .init(sessionID: sessionID) }
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

    private struct Session: ConversationSessionProviding {
        let gatewayID: GatewayID
        let client: ImmediateConversation
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
