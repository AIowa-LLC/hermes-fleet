import XCTest
@testable import FleetCore

/// Phone-bridged room store + projection (GC2 follow-up).
final class BridgedRoomsTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridged-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent(BridgedRooms.storeFileName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        super.tearDown()
    }

    func testStoreRoundTripsRecordsAndEvents() async {
        let store = BridgedRooms.Store(url: storeURL)
        let member = BridgedRooms.MemberRef(
            gatewayID: "gw-a", profile: "default", displayName: "Atlas", routeID: "gw-a#default")
        let record = BridgedRooms.RoomRecord(
            roomKey: "fleet-bridged-1", name: "Mixed Crew", members: [member], createdAt: 100)
        await store.upsert(record)
        await store.append(events: [BridgedRooms.EventRecord(
            seq: 1, eventID: "e1", kind: "message.user", actorKind: "user",
            actorID: "local-user", payloadText: "hello", createdAt: 101)], to: "fleet-bridged-1")

        // Fresh store instance = disk truth.
        let reloaded = BridgedRooms.Store(url: storeURL)
        let read = await reloaded.record(roomKey: "fleet-bridged-1")
        XCTAssertEqual(read?.name, "Mixed Crew")
        XCTAssertEqual(read?.events.count, 1)
        XCTAssertEqual(read?.events.first?.payloadText, "hello")
    }

    func testDisbandTombstonesAndRenameUpdates() async {
        let store = BridgedRooms.Store(url: storeURL)
        let record = BridgedRooms.RoomRecord(
            roomKey: "fleet-bridged-2", name: "Before", members: [], createdAt: 1)
        await store.upsert(record)
        await store.rename(roomKey: "fleet-bridged-2", to: "After", at: 2)
        await store.disband(roomKey: "fleet-bridged-2", at: 3)
        let read = await store.record(roomKey: "fleet-bridged-2")
        XCTAssertEqual(read?.name, "After")
        XCTAssertEqual(read?.disbandedAt, 3)
    }

    func testProjectionRendersHostedVocabulary() {
        let member = BridgedRooms.MemberRef(
            gatewayID: "gw-a", profile: "default", displayName: "Atlas", routeID: "gw-a#default")
        let record = BridgedRooms.RoomRecord(
            roomKey: "fleet-bridged-3", name: "Crew", members: [member], createdAt: 10,
            events: [
                BridgedRooms.EventRecord(
                    seq: 1, eventID: "u1", kind: "message.user", actorKind: "user",
                    actorID: "local-user", payloadText: "hi", createdAt: 11),
                BridgedRooms.EventRecord(
                    seq: 2, eventID: "m1", kind: "message.member", actorKind: "member",
                    actorID: "gw-a#default", actorDisplayName: "Atlas",
                    actorProfile: "default", payloadText: "hey back", createdAt: 12),
                BridgedRooms.EventRecord(
                    seq: 3, eventID: "f1", kind: "turn.failed", actorKind: "member",
                    actorID: "gw-b#qa", actorDisplayName: "Niner",
                    payloadText: "Niner couldn't answer.", reasonCode: "member_timeout",
                    createdAt: 13),
            ])
        let room = BridgedRooms.fleetRoom(for: record)
        XCTAssertEqual(room.id.provenance, .hosted)
        XCTAssertEqual(room.id.gatewayID, BridgedRooms.gatewayScope)
        XCTAssertEqual(room.name, "Crew")
        XCTAssertEqual(room.members.first?.name, "Atlas")
        XCTAssertNotNil(room.hosted)
        // Capabilities from advertised methods: send/replay/rename/disband.
        XCTAssertTrue(room.capabilities.canSend)
        XCTAssertTrue(room.capabilities.canReplay)
        XCTAssertTrue(room.capabilities.canRename)
        XCTAssertTrue(room.capabilities.canDisband)
        // Projection renders both messages + the failure note.
        let projection = RoomTranscriptProjection.project(
            record.events.map { $0.hostedEvent(roomKey: record.roomKey) })
        XCTAssertEqual(projection.entries.count, 3)
        XCTAssertEqual(projection.entries.first?.speaker, "local-user")
        XCTAssertEqual(projection.entries.last?.failure?.message, "Niner couldn't answer.")
    }
}
