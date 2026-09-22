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

    func testStoreRoundTripsRecordsAndEvents() async throws {
        let store = BridgedRooms.Store(url: storeURL)
        let member = BridgedRooms.MemberRef(
            gatewayID: "gw-a", profile: "default", displayName: "Atlas", routeID: "gw-a#default")
        let record = BridgedRooms.RoomRecord(
            roomKey: "fleet-bridged-1", name: "Mixed Crew", members: [member], createdAt: 100)
        try await store.upsert(record)
        try await store.append(events: [BridgedRooms.EventRecord(
            seq: 1, eventID: "e1", kind: "message.user", actorKind: "user",
            actorID: "local-user", payloadText: "hello", createdAt: 101)], to: "fleet-bridged-1")

        // Fresh store instance = disk truth.
        let reloaded = BridgedRooms.Store(url: storeURL)
        let read = await reloaded.record(roomKey: "fleet-bridged-1")
        XCTAssertEqual(read?.name, "Mixed Crew")
        XCTAssertEqual(read?.events.count, 1)
        XCTAssertEqual(read?.events.first?.payloadText, "hello")
    }

    func testOldRecordDecodesWithoutBridgeSessionMap() throws {
        let json = """
        {"roomKey":"old","name":"Old","members":[],"createdAt":1,"events":[]}
        """.data(using: .utf8)!
        let record = try JSONDecoder().decode(BridgedRooms.RoomRecord.self, from: json)
        XCTAssertEqual(record.bridgeSessionIDs, [:])
    }

    func testWriteFailureDoesNotPublishRoom() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridged-unwritable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BridgedRooms.Store(url: directory)
        do {
            try await store.upsert(.init(roomKey: "room", name: "Room", members: [], createdAt: 1))
            XCTFail("upsert should report an unwritable destination")
        } catch {
            let read = await store.record(roomKey: "room")
            XCTAssertNil(read)
        }
    }

    func testDisbandTombstonesAndRenameUpdates() async throws {
        let store = BridgedRooms.Store(url: storeURL)
        let record = BridgedRooms.RoomRecord(
            roomKey: "fleet-bridged-2", name: "Before", members: [], createdAt: 1)
        try await store.upsert(record)
        try await store.rename(roomKey: "fleet-bridged-2", to: "After", at: 2)
        try await store.disband(roomKey: "fleet-bridged-2", at: 3)
        let read = await store.record(roomKey: "fleet-bridged-2")
        XCTAssertEqual(read?.name, "After")
        XCTAssertEqual(read?.disbandedAt, 3)
    }

    func testUnreadableStoreIsQuarantinedInsteadOfBeingOverwritten() async throws {
        // A present-but-undecodable file must never read as "no rooms": every
        // later mutation persists the in-memory snapshot with `.atomic`, so
        // treating a decode failure as empty state silently destroyed the
        // user's only copy of every bridged room.
        let corrupt = Data("{ this is not a room store".utf8)
        try corrupt.write(to: storeURL)

        let store = BridgedRooms.Store(url: storeURL)
        let snapshot = await store.roomsSnapshot()
        XCTAssertTrue(snapshot.isEmpty)

        let quarantined = await store.quarantinedURL
        let backup = try XCTUnwrap(quarantined, "an unreadable store is moved aside, never dropped")
        XCTAssertEqual(try Data(contentsOf: backup), corrupt, "the original bytes survive for recovery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))

        // The next mutation writes a FRESH store; the quarantined copy stays intact.
        try await store.upsert(.init(roomKey: "room", name: "Room", members: [], createdAt: 1))
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        let read = await store.record(roomKey: "room")
        XCTAssertNotNil(read)
    }

    func testAbsentStoreIsNotQuarantined() async throws {
        // A fresh install is NOT a decode failure: no file, no quarantine, no
        // backup left behind.
        let store = BridgedRooms.Store(url: storeURL)
        let snapshot = await store.roomsSnapshot()
        XCTAssertTrue(snapshot.isEmpty)
        let quarantined = await store.quarantinedURL
        XCTAssertNil(quarantined)
        let files = try FileManager.default.contentsOfDirectory(
            at: storeURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty)
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
        XCTAssertEqual(projection.entries.first?.speaker, "You",
                       "the room's human renders as You, never the local-user plumbing id")
        XCTAssertEqual(projection.entries.last?.failure?.message, "Niner couldn't answer.")
    }
}
