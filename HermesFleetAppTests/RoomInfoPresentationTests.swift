import XCTest
import FleetCore
@testable import FleetUI

/// P1 (RC-84) — Group Info presentation mapping: provenance/status/authority/
/// participants/capability lines over real `FleetRoom` fields, with honest
/// "Unknown" for unreported data.
final class RoomInfoPresentationTests: XCTestCase {

    private func room(
        provenance: RoomProvenance = .hosted,
        name: String = "Design Room",
        isDeleted: Bool = false,
        members: [FleetRoomMember] = [],
        hosted: HostedRoomState? = nil
    ) -> FleetRoom {
        FleetRoom(
            id: FleetRoomID(provenance: provenance, gatewayID: GatewayID(rawValue: "gw-a"), key: "k1"),
            name: name,
            members: members,
            isDeleted: isDeleted,
            hosted: hosted)
    }

    // MARK: - Provenance / status

    func testProvenanceText() {
        XCTAssertEqual(RoomInfoPresentation.provenanceText(room(provenance: .hosted)), "Hosted Group")
        let legacy = RoomInfoPresentation.provenanceText(room(provenance: .desktopLegacy))
        XCTAssertTrue(legacy.localizedCaseInsensitiveContains("desktop"))
        XCTAssertTrue(legacy.localizedCaseInsensitiveContains("read only"))
    }

    func testStatusText() {
        XCTAssertEqual(RoomInfoPresentation.statusText(room()), "Active")
        XCTAssertEqual(RoomInfoPresentation.statusText(room(isDeleted: true)), "Disbanded")
        XCTAssertEqual(
            RoomInfoPresentation.statusText(room(hosted: HostedRoomState(
                authorityGatewayID: "install:gw-a", authorityEpoch: 1, disbandedAt: 1_700_000_000))),
            "Disbanded",
            "a disbandedAt timestamp is truth regardless of the isDeleted flag")
    }

    // MARK: - Gateways

    func testAuthorityAndDriverText() {
        XCTAssertEqual(RoomInfoPresentation.authorityText(room()), "Unknown")
        XCTAssertEqual(RoomInfoPresentation.driverText(room()), "Unknown")

        let hosted = room(hosted: HostedRoomState(
            authorityGatewayID: "install:gw-a", authorityEpoch: 3, driverAvailable: true))
        XCTAssertEqual(RoomInfoPresentation.authorityText(hosted), "install:gw-a")
        XCTAssertEqual(RoomInfoPresentation.driverText(hosted), "Available")

        let driverDown = room(hosted: HostedRoomState(
            authorityGatewayID: "install:gw-a", authorityEpoch: 3, driverAvailable: false))
        XCTAssertEqual(RoomInfoPresentation.driverText(driverDown), "Unavailable")
    }

    // MARK: - Participants

    func testParticipantDetailPrefersConnectionLabel() {
        let member = FleetRoomMember(
            name: "Researcher",
            handle: "researcher",
            connectionID: "c1",
            connectionLabel: "4090 (RoomLink)",
            sourceScoped: true)
        XCTAssertEqual(RoomInfoPresentation.participantDetail(member), "4090 (RoomLink)")
    }

    func testParticipantDetailFallsBackToHandleThenScopedNote() {
        XCTAssertEqual(
            RoomInfoPresentation.participantDetail(FleetRoomMember(name: "a", handle: "alpha")),
            "alpha")
        XCTAssertEqual(
            RoomInfoPresentation.participantDetail(FleetRoomMember(name: "a", sourceScoped: true)),
            "Source-scoped participant")
        XCTAssertNil(RoomInfoPresentation.participantDetail(FleetRoomMember(name: "a")),
                     "nothing known must be nil — never filler")
    }

    // MARK: - State

    func testLastUpdateText() {
        XCTAssertEqual(RoomInfoPresentation.lastUpdateText(room()), "Unknown")
        let updated = room(hosted: HostedRoomState(
            authorityGatewayID: "install:gw-a", authorityEpoch: 1, updatedAt: 1_700_000_000))
        XCTAssertNotEqual(RoomInfoPresentation.lastUpdateText(updated), "Unknown")
    }

    // MARK: - Capability lines

    func testLegacyRoomCapabilityLinesAllFalse() {
        let lines = RoomInfoPresentation.capabilityLines(.desktopLegacyObservational)
        XCTAssertEqual(lines.count, 8)
        XCTAssertTrue(lines.allSatisfy { !$0.supported })
    }

    func testHostedCapabilityLinesFollowAdvertisedMethods() {
        let caps = RoomCapabilities.hosted(
            methods: ["groups.send", "groups.rename", "groups.log"], driverAvailable: true)
        let lines = RoomInfoPresentation.capabilityLines(caps)
        let byLabel = Dictionary(uniqueKeysWithValues: lines.map { ($0.label, $0.supported) })
        XCTAssertEqual(byLabel["Send messages"], true)
        XCTAssertEqual(byLabel["Rename"], true)
        XCTAssertEqual(byLabel["Replay history"], true)
        XCTAssertEqual(byLabel["Disband"], false)
        XCTAssertEqual(byLabel["Stop a running turn"], false)
        XCTAssertEqual(byLabel["Approve requests"], false)
    }

    func testDriverDownDisablesEveryCapabilityLine() {
        let caps = RoomCapabilities.hosted(
            methods: ["groups.send", "groups.rename", "groups.disband", "groups.log"],
            driverAvailable: false)
        XCTAssertTrue(RoomInfoPresentation.capabilityLines(caps).allSatisfy { !$0.supported },
                      "driver unavailable means the room is observational — honest, not aspirational")
    }

    func testCapabilityLineIdsAreStableAndComplete() {
        let lines = RoomInfoPresentation.capabilityLines(.desktopLegacyObservational)
        XCTAssertEqual(lines.map(\.label), [
            "Send messages", "Rename", "Disband", "Stop a running turn",
            "Retry a failed turn", "Approve requests", "Replay history", "Manage members",
        ])
        XCTAssertEqual(lines.map(\.id), [
            "send", "rename", "disband", "stop", "retry", "approve", "replay", "manage-members",
        ], "ids are stable machine keys for accessibility identifiers")
    }
}