import XCTest
@testable import FleetCore

/// P0-7 multiplexer presence: bot online/offline derives from the OWNING
/// GATEWAY's roster outcome — never from `gateway_running` (own-process
/// badge) and never from unobserved `BotActivity`.
///
/// Model (verified in gateway source, gateway/config.py:430 / run.py:2426):
/// the gateway is a PROFILE MULTIPLEXER — every profile it lists is
/// chat-reachable through the one shared connection. A bot is ONLINE when
/// its owning gateway answered `profiles.list` this refresh.
final class BotPresenceTests: XCTestCase {

    private let gatewayA = GatewayID(rawValue: "gw-a")
    private let gatewayB = GatewayID(rawValue: "gw-b")

    private func descriptor(_ name: String, gatewayRunning: Bool = false) -> ProfileDescriptor {
        ProfileDescriptor(
            name: name,
            path: "/home/\(name)",
            gatewayRunning: gatewayRunning
        )
    }

    private func bot(on gatewayID: GatewayID, name: String, gatewayRunning: Bool = false) -> FleetBot {
        FleetBot.bot(
            on: gatewayID,
            descriptor: descriptor(name, gatewayRunning: gatewayRunning)
        )
    }

    private func gateway(_ id: GatewayID) -> FleetGateway {
        FleetGateway(id: id, displayName: id.rawValue, endpoint: nil)
    }

    private func loadedSnapshot() -> FleetRosterSnapshot {
        var roster = FleetRoster()
        roster.upsertGateway(gateway(gatewayA))
        roster.setBots(on: gatewayA, from: [descriptor("default"), descriptor("researcher")])
        return FleetRosterSnapshot(
            roster: roster,
            gatewayOutcomes: [gatewayA: .loaded(profileCount: 2)]
        )
    }

    // MARK: snapshot.botPresence

    func testLoadedGatewayMakesAllItsBotsReachable() {
        let snapshot = loadedSnapshot()
        XCTAssertEqual(snapshot.botPresence(on: gatewayA), .reachable)
        XCTAssertEqual(snapshot.botPresence(for: Route(gatewayID: gatewayA, profileSlug: ProfileSlug(rawValue: "default"))), .reachable)
        XCTAssertEqual(snapshot.botPresence(for: Route(gatewayID: gatewayA, profileSlug: ProfileSlug(rawValue: "researcher"))), .reachable)
    }

    func testFailedGatewayMakesItsBotsUnreachable() {
        var roster = FleetRoster()
        roster.upsertGateway(gateway(gatewayB))
        roster.setBots(on: gatewayB, from: [descriptor("default")])
        let snapshot = FleetRosterSnapshot(
            roster: roster,
            gatewayOutcomes: [gatewayB: .failed(status: .offline, detail: nil)]
        )
        XCTAssertEqual(snapshot.botPresence(on: gatewayB), .unreachable)
        XCTAssertEqual(snapshot.botPresence(for: Route(gatewayID: gatewayB, profileSlug: ProfileSlug(rawValue: "default"))), .unreachable)
    }

    func testMixedFleetPresenceFollowsEachOwnGateway() {
        var roster = FleetRoster()
        roster.upsertGateway(gateway(gatewayA))
        roster.upsertGateway(gateway(gatewayB))
        roster.setBots(on: gatewayA, from: [descriptor("default")])
        roster.setBots(on: gatewayB, from: [descriptor("default")])
        let snapshot = FleetRosterSnapshot(
            roster: roster,
            gatewayOutcomes: [
                gatewayA: .loaded(profileCount: 1),
                gatewayB: .failed(status: .offline, detail: nil),
            ]
        )
        XCTAssertEqual(snapshot.botPresence(on: gatewayA), .reachable)
        XCTAssertEqual(snapshot.botPresence(on: gatewayB), .unreachable)
    }

    func testUnknownGatewayOrMissingOutcomeIsUnknownFailClosed() {
        let snapshot = loadedSnapshot()
        // Gateway not in the roster at all.
        XCTAssertEqual(snapshot.botPresence(on: gatewayB), .unknown)
        // Gateway present but no outcome yet (no refresh classified it).
        var roster = FleetRoster()
        roster.upsertGateway(gateway(gatewayB))
        let unclassified = FleetRosterSnapshot(roster: roster, gatewayOutcomes: [:])
        XCTAssertEqual(unclassified.botPresence(on: gatewayB), .unknown)
        // Route not in the roster.
        let absentRoute = Route(gatewayID: gatewayA, profileSlug: ProfileSlug(rawValue: "ghost"))
        XCTAssertEqual(snapshot.botPresence(for: absentRoute), .unknown)
    }

    // MARK: gateway_running is decoded + carried, but never presence

    func testGatewayRunningCarriesFromDescriptorToBot() {
        let withOwn = bot(on: gatewayA, name: "default", gatewayRunning: true)
        let withoutOwn = bot(on: gatewayA, name: "researcher", gatewayRunning: false)
        XCTAssertTrue(withOwn.gatewayRunning)
        XCTAssertFalse(withoutOwn.gatewayRunning)
        // And it does NOT leak into activity or affect presence semantics:
        XCTAssertEqual(withOwn.activity, .unknown)
        let snapshot = loadedSnapshot()
        XCTAssertEqual(snapshot.botPresence(for: withOwn.route), .reachable)
        XCTAssertEqual(snapshot.botPresence(for: withoutOwn.route), .reachable)
    }
}
