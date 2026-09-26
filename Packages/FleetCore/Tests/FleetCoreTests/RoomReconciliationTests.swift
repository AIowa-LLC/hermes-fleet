import XCTest
@testable import FleetCore

final class RoomReconciliationTests: XCTestCase {
    func testVerifiedLegacyProjectionsCollapseBehindHostedPrimary() {
        let hosted = makeHosted(gateway: "arch", key: "room-brainstorm", name: "iOS App Brainstorming Crew")
        let archProjection = makeLegacy(gateway: "arch", key: "room-brainstorm", name: hosted.name)
        let macProjection = makeLegacy(gateway: "mac", key: "room-brainstorm", name: hosted.name)

        let snapshot = FleetRoomReconciler.reconcile(
            rooms: [macProjection, hosted, archProjection])

        XCTAssertEqual(snapshot.primaryRooms.map(\.id), [hosted.id])
        XCTAssertEqual(snapshot.legacyArchiveRooms.map(\.id), [archProjection.id, macProjection.id])
        XCTAssertEqual(snapshot.relationships.count, 1)
        XCTAssertEqual(snapshot.relationships[0].representationIDs.count, 3)
    }

    func testSameNameDifferentHostedKeysRemainSeparate() {
        let first = makeHosted(gateway: "arch", key: "room-one", name: "Planning")
        let second = makeHosted(gateway: "mac", key: "room-two", name: "Planning")

        let snapshot = FleetRoomReconciler.reconcile(rooms: [second, first])

        XCTAssertEqual(snapshot.primaryRooms.map(\.id), [first.id, second.id])
        XCTAssertTrue(snapshot.relationships.isEmpty)
    }

    func testMatchingBareIDWithoutSameGatewayAnchorDoesNotLink() {
        let hosted = makeHosted(gateway: "arch", key: "room-collision", name: "Planning")
        let unrelatedProjection = makeLegacy(gateway: "mac", key: "room-collision", name: "Planning")

        let snapshot = FleetRoomReconciler.reconcile(rooms: [hosted, unrelatedProjection])

        XCTAssertEqual(snapshot.primaryRooms.map(\.id), [hosted.id])
        XCTAssertEqual(snapshot.legacyArchiveRooms.map(\.id), [unrelatedProjection.id])
        XCTAssertTrue(snapshot.relationships.isEmpty)
    }

    func testRenamePreservesRelationshipByDurableID() {
        let hosted = makeHosted(gateway: "arch", key: "room-renamed", name: "New name")
        let oldProjection = makeLegacy(gateway: "arch", key: "room-renamed", name: "Old name")

        let snapshot = FleetRoomReconciler.reconcile(rooms: [oldProjection, hosted])

        XCTAssertEqual(snapshot.primaryRooms.map(\.name), ["New name"])
        XCTAssertEqual(snapshot.relationships.count, 1)
    }

    func testRefreshOrderDoesNotChangePrimaryIdentity() {
        let hosted = makeHosted(gateway: "arch", key: "room-stable", name: "Stable")
        let archProjection = makeLegacy(gateway: "arch", key: "room-stable", name: "Stable")
        let macProjection = makeLegacy(gateway: "mac", key: "room-stable", name: "Stable")
        let rows = [hosted, archProjection, macProjection]

        let first = FleetRoomReconciler.reconcile(rooms: rows)
        let second = FleetRoomReconciler.reconcile(rooms: rows.reversed())

        XCTAssertEqual(first.primaryRooms.map(\.id), second.primaryRooms.map(\.id))
        XCTAssertEqual(first.relationships, second.relationships)
    }

    func testDisbandTombstonePreventsLegacyResurrection() {
        let hosted = makeHosted(gateway: "arch", key: "room-gone", name: "Gone")
        let projection = makeLegacy(gateway: "arch", key: "room-gone", name: "Gone")
        let tombstone = FleetRoom(
            id: hosted.id,
            name: hosted.name,
            revision: hosted.revision + 1,
            isDeleted: true,
            hosted: HostedRoomState(
                authorityGatewayID: "install:arch",
                authorityEpoch: 1,
                disbandedAt: 1))

        var union = FleetRoomUnion()
        union.ingest([hosted, projection])
        union.ingest([tombstone])

        XCTAssertTrue(union.primaryRooms.isEmpty)
        XCTAssertTrue(union.legacyArchiveRooms.isEmpty)
    }

    private func makeHosted(gateway: String, key: String, name: String) -> FleetRoom {
        FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: gateway), key: key),
            name: name,
            members: [member("default"), member("researcher")],
            revision: 7,
            hosted: HostedRoomState(
                authorityGatewayID: "install:" + gateway,
                authorityEpoch: 1,
                latestSeq: 6,
                advertisedMethods: ["groups.send", "groups.log"],
                driverAvailable: true))
    }

    private func makeLegacy(gateway: String, key: String, name: String) -> FleetRoom {
        FleetRoom(
            id: FleetRoomID(
                provenance: .desktopLegacy,
                gatewayID: GatewayID(rawValue: gateway),
                key: "id:" + key),
            name: name,
            members: [member("default"), member("researcher")],
            revision: 7)
    }

    private func member(_ name: String) -> FleetRoomMember {
        FleetRoomMember(name: name, handle: name, connectionID: "local")
    }
}
