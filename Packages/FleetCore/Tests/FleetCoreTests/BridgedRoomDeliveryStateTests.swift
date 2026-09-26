import XCTest
@testable import FleetCore

/// Durable per-member transcript-delivery state for bridged rooms (FR-04):
/// seq-based watermarks, schema compatibility with Build 75 records, and the
/// bounded-log semantics Desktop's `trimGroupChatLog` established.
final class BridgedRoomDeliveryStateTests: XCTestCase {
    private func member(
        _ gateway: String, _ profile: String, label: String? = nil
    ) -> BridgedRooms.MemberRef {
        .init(
            gatewayID: gateway, profile: profile, displayName: profile,
            routeID: "\(gateway)#\(profile)", gatewayLabel: label)
    }

    private func userEvent(_ seq: Int, _ text: String) -> BridgedRooms.EventRecord {
        .init(
            seq: seq, eventID: "e\(seq)", kind: "message.user", actorKind: "user",
            actorID: "local-user", payloadText: text, createdAt: Double(seq))
    }

    // MARK: schema compatibility

    func testBuild75RecordWithoutWatermarksDecodesWithEmptyState() throws {
        // Exact Build 75 persisted shape (no deliveryWatermarks, no
        // gatewayLabel on members) — decoding must not fail and must not
        // disturb existing bridge sessions.
        let json = """
        {
          "room": {
            "roomKey": "room",
            "name": "Legacy",
            "members": [
              {"gatewayID": "alpha", "profile": "research", "displayName": "Research", "routeID": "alpha#research"}
            ],
            "createdAt": 100,
            "events": [
              {"seq": 1, "eventID": "e1", "kind": "message.user", "actorKind": "user",
               "actorID": "local-user", "payloadText": "hi", "createdAt": 1}
            ],
            "bridgeSessionIDs": {"alpha#research": "session-1"}
          }
        }
        """
        let decoded = try JSONDecoder().decode([String: BridgedRooms.RoomRecord].self, from: Data(json.utf8))
        let record = try XCTUnwrap(decoded["room"])
        XCTAssertEqual(record.bridgeSessionIDs["alpha#research"], "session-1",
                       "existing bridge sessions must survive the migration")
        XCTAssertEqual(record.deliveryWatermarks.isEmpty, true,
                       "a pre-migration member starts undelivered (absent == 0 == everything is new)")
        XCTAssertEqual(record.members.first?.gatewayLabel, nil)
    }

    func testWatermarksRoundTripThroughJSON() throws {
        var record = BridgedRooms.RoomRecord(
            roomKey: "room", name: "R",
            members: [member("alpha", "research", label: "Mac Mini")], createdAt: 0)
        record.deliveryWatermarks["alpha#research"] = 7
        let data = try JSONEncoder().encode([record])
        let decoded = try JSONDecoder().decode([BridgedRooms.RoomRecord].self, from: data)
        XCTAssertEqual(decoded.first?.deliveryWatermarks["alpha#research"], 7)
        XCTAssertEqual(decoded.first?.members.first?.gatewayLabel, "Mac Mini")
    }

    // MARK: watermark semantics

    func testUndeliveredEventsForMemberAreTheSeqGap() {
        var record = BridgedRooms.RoomRecord(
            roomKey: "room", name: "R", members: [member("alpha", "research")], createdAt: 0)
        record.events = (1...5).map { userEvent($0, "m\($0)") }
        record.deliveryWatermarks["alpha#research"] = 2
        let undelivered = record.events.filter { $0.seq > (record.deliveryWatermarks["alpha#research"] ?? 0) }
        XCTAssertEqual(undelivered.map(\.seq), [3, 4, 5])
    }

    func testMissingWatermarkMeansEverythingIsNew() {
        let record = BridgedRooms.RoomRecord(
            roomKey: "room", name: "R", members: [member("alpha", "research")], createdAt: 0,
            events: (1...3).map { userEvent($0, "m\($0)") })
        let seen = record.deliveryWatermarks["alpha#research"] ?? 0
        XCTAssertEqual(seen, 0)
        XCTAssertEqual(record.events.filter { $0.seq > seen }.count, 3)
    }

    func testMembersTrackWatermarksIndependently() {
        var record = BridgedRooms.RoomRecord(
            roomKey: "room", name: "R",
            members: [member("alpha", "research"), member("beta", "writer")], createdAt: 0)
        record.events = (1...4).map { userEvent($0, "m\($0)") }
        record.deliveryWatermarks["alpha#research"] = 4
        // beta never received anything; alpha's watermark must not silence beta.
        XCTAssertEqual(record.events.filter { $0.seq > (record.deliveryWatermarks["beta#research#na"] ?? 0) }.count, 4)
    }
}
