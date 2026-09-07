import XCTest
@testable import FleetCore

/// M8 Fleet Roster domain: the union-roster snapshot value, per-gateway
/// outcomes, and the §13/§30 partial-availability vocabulary (spec §31
/// Multi-Gateway — one unavailable gateway must not break another; the fleet
/// stays useful partially).
final class FleetRosterDomainTests: XCTestCase {

    private let gwA = GatewayID(rawValue: "workstation")
    private let gwB = GatewayID(rawValue: "arch")

    private func bot(_ slug: String, on gatewayID: GatewayID) -> FleetBot {
        FleetBot(
            route: Route(gatewayID: gatewayID, profileSlug: ProfileSlug(rawValue: slug)),
            displayName: slug
        )
    }

    private func loadedGateway(_ id: GatewayID, name: String) -> FleetGateway {
        FleetGateway(id: id, displayName: name, connectionState: .connected)
    }

    // MARK: snapshot defaults

    func testSnapshotDefaultsAreEmpty() {
        let snapshot = FleetRosterSnapshot()
        XCTAssertTrue(snapshot.roster.allGateways.isEmpty)
        XCTAssertTrue(snapshot.roster.allBots.isEmpty)
        XCTAssertTrue(snapshot.gatewayOutcomes.isEmpty)
        XCTAssertTrue(snapshot.reachableGateways.isEmpty)
        XCTAssertTrue(snapshot.unreachableGateways.isEmpty)
    }

    // MARK: outcomes

    func testOutcomeCasesAreEquatable() {
        XCTAssertEqual(GatewayRosterOutcome.loaded(profileCount: 3), .loaded(profileCount: 3))
        XCTAssertNotEqual(GatewayRosterOutcome.loaded(profileCount: 3), .loaded(profileCount: 4))
        XCTAssertEqual(
            GatewayRosterOutcome.failed(status: .offline, detail: nil),
            .failed(status: .offline, detail: nil))
        XCTAssertNotEqual(
            GatewayRosterOutcome.failed(status: .offline, detail: nil),
            .failed(status: .authenticationRequired, detail: nil))
        XCTAssertNotEqual(GatewayRosterOutcome.loaded(profileCount: 1), .failed(status: .offline, detail: nil))
    }

    // MARK: reachability / partial availability (spec §13, §30)

    func testReachableAndUnreachableGatewaysSplitByOutcome() {
        var snapshot = FleetRosterSnapshot()
        snapshot.roster.upsertGateway(loadedGateway(gwA, name: "MacBook"))
        snapshot.roster.upsertGateway(loadedGateway(gwB, name: "Arch"))
        snapshot.gatewayOutcomes = [
            gwA: .loaded(profileCount: 2),
            gwB: .failed(status: .offline, detail: "unreachable"),
        ]
        XCTAssertEqual(snapshot.reachableGateways.map(\.id), [gwA])
        XCTAssertEqual(snapshot.unreachableGateways.map(\.id), [gwB])
    }

    func testOutcomeAccessorFailsClosedForUnknownGateway() {
        let snapshot = FleetRosterSnapshot()
        XCTAssertNil(snapshot.outcome(for: gwA))
    }

    // MARK: union roster preserves owning gateway (spec §31)

    func testSnapshotBotLookupPreservesOwningGateway() {
        var snapshot = FleetRosterSnapshot()
        snapshot.roster.upsertBot(bot("default", on: gwA))
        snapshot.roster.upsertBot(bot("default", on: gwB)) // same slug, two owners

        let routeA = Route(gatewayID: gwA, profileSlug: ProfileSlug(rawValue: "default"))
        let routeB = Route(gatewayID: gwB, profileSlug: ProfileSlug(rawValue: "default"))
        XCTAssertEqual(snapshot.bot(for: routeA)?.gatewayID, gwA)
        XCTAssertEqual(snapshot.bot(for: routeB)?.gatewayID, gwB)
        XCTAssertNil(snapshot.bot(for: Route(
            gatewayID: GatewayID(rawValue: "missing"), profileSlug: ProfileSlug(rawValue: "default"))))
    }

    func testSnapshotBotsOnGatewayScopedByOwner() {
        var snapshot = FleetRosterSnapshot()
        snapshot.roster.upsertBot(bot("a1", on: gwA))
        snapshot.roster.upsertBot(bot("a2", on: gwA))
        snapshot.roster.upsertBot(bot("b1", on: gwB))
        XCTAssertEqual(snapshot.bots(on: gwA).map(\.profileSlug.rawValue).sorted(), ["a1", "a2"])
        XCTAssertEqual(snapshot.bots(on: gwB).map(\.profileSlug.rawValue), ["b1"])
        // An unreachable/absent gateway has no bots — fail closed, never the
        // other gateway's bots.
        XCTAssertTrue(snapshot.bots(on: GatewayID(rawValue: "missing")).isEmpty)
    }

    // MARK: gateway entry carries last-known connection state (§30 "which
    // gateway failed" + what is still available)

    func testSnapshotGatewayEntriesCarryConnectionState() {
        var snapshot = FleetRosterSnapshot()
        snapshot.roster.upsertGateway(loadedGateway(gwA, name: "MacBook"))
        var failedB = loadedGateway(gwB, name: "Arch")
        failedB.connectionState = .failed(GatewayStatus.offline.rawValue)
        snapshot.roster.upsertGateway(failedB)
        snapshot.gatewayOutcomes = [
            gwA: .loaded(profileCount: 1),
            gwB: .failed(status: .offline, detail: "unreachable"),
        ]
        XCTAssertEqual(snapshot.roster.gateway(for: gwA)?.connectionState, .connected)
        XCTAssertEqual(snapshot.roster.gateway(for: gwB)?.connectionState, .failed("offline"))
    }

    // MARK: deterministic ordering for rendering

    func testSnapshotGatewaysAndBotsOrdered() {
        var snapshot = FleetRosterSnapshot()
        snapshot.roster.upsertGateway(loadedGateway(gwB, name: "Arch"))
        snapshot.roster.upsertGateway(loadedGateway(gwA, name: "MacBook"))
        snapshot.roster.upsertBot(bot("b", on: gwB))
        snapshot.roster.upsertBot(bot("a", on: gwA))
        XCTAssertEqual(snapshot.roster.allGateways.map(\.id.rawValue), ["arch", "workstation"])
        XCTAssertEqual(
            snapshot.roster.allBots.map(\.route.id),
            ["arch#b", "workstation#a"])
    }
}
