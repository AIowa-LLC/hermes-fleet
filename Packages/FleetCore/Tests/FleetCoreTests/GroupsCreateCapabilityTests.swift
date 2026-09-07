import XCTest
@testable import FleetCore

/// F1: the gateway-level create-room capability tri-state and its pure
/// mapping from `groups.capabilities` truth — the Create Room gate is a
/// GATEWAY property, never derived from a room row.
final class GroupsCreateCapabilityTests: XCTestCase {

    func testSupportedWhenDriverAndCreateAdvertised() {
        let capability = GroupsCreateCapability(capabilities: GroupsCapabilityTruth(
            driver: true,
            methods: [
                "groups.capabilities", "groups.list", "groups.create",
                "groups.state", "groups.send", "groups.log",
            ]))
        XCTAssertEqual(capability, .supported)
    }

    func testUnsupportedWhenCreateMethodMissing() {
        let capability = GroupsCreateCapability(capabilities: GroupsCapabilityTruth(
            driver: true,
            methods: ["groups.capabilities", "groups.list", "groups.send"]))
        XCTAssertEqual(capability, .unsupported,
                       "no groups.create advertised → honest absence")
    }

    func testUnsupportedWhenDriverUnavailable() {
        let capability = GroupsCreateCapability(capabilities: GroupsCapabilityTruth(
            driver: false,
            methods: ["groups.capabilities", "groups.list", "groups.create"]))
        XCTAssertEqual(capability, .unsupported,
                       "groups.create without the room driver is not creatable")
    }

    func testDefaultProbeAnswerFailsClosed() async {
        // A source that does not implement the probe (legacy-projection
        // only, empty source) reports .unknown — never flips the gate.
        struct BareSource: FleetRoomSourceProviding {
            func rooms() async -> [FleetRoom] { [] }
        }
        let answer = await BareSource().createRoomCapability()
        XCTAssertEqual(answer, .unknown)
    }
}
