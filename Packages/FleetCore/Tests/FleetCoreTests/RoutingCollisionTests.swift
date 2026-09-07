import XCTest
@testable import FleetCore

/// M2 acceptance (synthesis §20 Phase 2, spec §36 routing tests):
/// "Gateway A / default" and "Gateway B / default" must be distinct routes, and
/// routing must fail closed on ambiguity — a bare slug can never address a bot.
final class RoutingCollisionTests: XCTestCase {

    private let gatewayA = GatewayID(rawValue: "gateway-a")
    private let gatewayB = GatewayID(rawValue: "gateway-b")
    private let slug = ProfileSlug(rawValue: "default")

    // MARK: route identity — collisions are distinct

    func testSameSlugDifferentGatewaysAreDistinctRoutes() {
        let routeA = Route(gatewayID: gatewayA, profileSlug: slug)
        let routeB = Route(gatewayID: gatewayB, profileSlug: slug)

        XCTAssertNotEqual(routeA, routeB)
        XCTAssertEqual(Set([routeA, routeB]).count, 2)
    }

    func testSameGatewaySameSlugIsOneRoute() {
        let a1 = Route(gatewayID: gatewayA, profileSlug: slug)
        let a2 = Route(gatewayID: gatewayA, profileSlug: slug)
        XCTAssertEqual(a1, a2)
        XCTAssertEqual(Set([a1, a2]).count, 1)
    }

    func testRouteIdentityStringIsCollisionFree() {
        let routeA = Route(gatewayID: gatewayA, profileSlug: slug)
        let routeB = Route(gatewayID: gatewayB, profileSlug: slug)
        XCTAssertNotEqual(routeA.id, routeB.id)
        XCTAssertEqual(routeA.id, "gateway-a#default")
    }

    func testRouteCodableRoundTrip() throws {
        let route = Route(gatewayID: gatewayA, profileSlug: slug)
        let data = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(Route.self, from: data)
        XCTAssertEqual(decoded, route)
    }

    func testRouteOrderingGroupsByGateway() {
        let r1 = Route(gatewayID: gatewayA, profileSlug: ProfileSlug(rawValue: "z"))
        let r2 = Route(gatewayID: gatewayA, profileSlug: slug)
        let r3 = Route(gatewayID: gatewayB, profileSlug: slug)
        XCTAssertLessThan(r2, r1)   // same gateway → slug order
        XCTAssertLessThan(r1, r3)   // gateway order dominates
    }

    // MARK: roster routing — collision never misroutes

    func testTwoGatewaysSameSlugResolveDistinctBots() throws {
        var roster = FleetRoster()
        roster.upsertGateway(FleetGateway(id: gatewayA, displayName: "A"))
        roster.upsertGateway(FleetGateway(id: gatewayB, displayName: "B"))

        roster.setBots(on: gatewayA, from: [
            ProfileDescriptor(name: "default", path: "/home/a")
        ])
        roster.setBots(on: gatewayB, from: [
            ProfileDescriptor(name: "default", path: "/home/b")
        ])

        let routeA = Route(gatewayID: gatewayA, profileSlug: slug)
        let routeB = Route(gatewayID: gatewayB, profileSlug: slug)

        let botA = try XCTUnwrap(roster.bot(for: routeA))
        let botB = try XCTUnwrap(roster.bot(for: routeB))

        // Distinct identity, same slug, different owners.
        XCTAssertNotEqual(botA, botB)
        XCTAssertEqual(botA.profileSlug, botB.profileSlug)
        XCTAssertEqual(botA.gatewayID, gatewayA)
        XCTAssertEqual(botB.gatewayID, gatewayB)
        // Provenance preserved through aggregation.
        XCTAssertEqual(roster.bots(on: gatewayA).count, 1)
        XCTAssertEqual(roster.bots(on: gatewayB).count, 1)
        XCTAssertEqual(roster.allBots.count, 2)
    }

    func testBareSlugCannotAddressABot() {
        var roster = FleetRoster()
        roster.upsertGateway(FleetGateway(id: gatewayA, displayName: "A"))
        roster.setBots(on: gatewayA, from: [ProfileDescriptor(name: "default", path: "/home/a")])

        // There is no API that resolves a slug alone — the route carries the
        // gateway. Fail closed: an unknown gateway + known slug returns nil.
        let wrongGateway = Route(gatewayID: GatewayID(rawValue: "other"), profileSlug: slug)
        XCTAssertNil(roster.bot(for: wrongGateway))
    }

    func testDisplayNameIsNeverSubstitutedForSlug() {
        let descriptor = ProfileDescriptor(
            name: "researcher",
            path: "/home/r",
            displayName: "The Researcher"
        )
        let bot = FleetBot.bot(on: gatewayA, descriptor: descriptor)
        // Routing identity is the slug, not the display name.
        XCTAssertEqual(bot.route.profileSlug.rawValue, "researcher")
        XCTAssertNotEqual(bot.route.profileSlug.rawValue, "The Researcher")
        // Display name is presentation-only.
        XCTAssertEqual(bot.displayName, "The Researcher")
    }

    // MARK: roster mutation — removal invalidates routes (fail closed)

    func testRemovingGatewayInvalidatesItsBots() {
        var roster = FleetRoster()
        roster.upsertGateway(FleetGateway(id: gatewayA, displayName: "A"))
        roster.setBots(on: gatewayA, from: [ProfileDescriptor(name: "default", path: "/home/a")])

        let routeA = Route(gatewayID: gatewayA, profileSlug: slug)
        XCTAssertNotNil(roster.bot(for: routeA))

        roster.removeGateway(gatewayA)
        XCTAssertNil(roster.bot(for: routeA))
        XCTAssertTrue(roster.allBots.isEmpty)
    }

    // MARK: gateway registry

    func testRegistryRegistersAndResolves() {
        var registry = GatewayRegistry()
        registry.register(FleetGateway(id: gatewayA, displayName: "A"))
        XCTAssertEqual(registry.gateway(for: gatewayA)?.displayName, "A")
        XCTAssertNil(registry.gateway(for: gatewayB))
    }

    func testRegistryUpdateConnectionState() {
        var registry = GatewayRegistry()
        registry.register(FleetGateway(id: gatewayA, displayName: "A"))
        registry.updateConnectionState(gatewayA, .connecting)
        XCTAssertEqual(registry.gateway(for: gatewayA)?.connectionState, .connecting)
        // Unknown gateway: no-op, no crash.
        registry.updateConnectionState(gatewayB, .connected)
        XCTAssertNil(registry.gateway(for: gatewayB))
    }

    func testRegistryRemove() {
        var registry = GatewayRegistry()
        registry.register(FleetGateway(id: gatewayA, displayName: "A"))
        registry.remove(gatewayA)
        XCTAssertNil(registry.gateway(for: gatewayA))
    }

    // MARK: profile descriptor

    func testProfileDescriptorDisplayNameFallback() {
        XCTAssertEqual(
            ProfileDescriptor(name: "r", path: "/").resolvedDisplayName, "r")
        XCTAssertEqual(
            ProfileDescriptor(name: "r", path: "/", displayName: "Rob").resolvedDisplayName,
            "Rob")
    }

    func testProfileDescriptorCodableRoundTrip() throws {
        let d = ProfileDescriptor(
            name: "researcher", path: "/home/r", isDefault: false,
            model: "claude", provider: "anthropic",
            displayName: "R", skillCount: 4, hasAvatar: true,
            lastSession: SessionSummary(id: "s1", title: "hi", preview: "…",
                                        startedAt: 1_700_000_000, messageCount: 3,
                                        source: "tui"))
        let data = try JSONEncoder().encode(d)
        let decoded = try JSONDecoder().decode(ProfileDescriptor.self, from: data)
        XCTAssertEqual(decoded, d)
        XCTAssertEqual(decoded.lastSession?.id, "s1")
    }

    // MARK: M9 — fail-closed resolution on ambiguity (spec §5.6, §36)

    private func makeCollisionRoster() -> FleetRoster {
        var roster = FleetRoster()
        roster.upsertGateway(FleetGateway(id: gatewayA, displayName: "A"))
        roster.upsertGateway(FleetGateway(id: gatewayB, displayName: "B"))
        roster.setBots(on: gatewayA, from: [ProfileDescriptor(name: "default", path: "/home/a")])
        roster.setBots(on: gatewayB, from: [ProfileDescriptor(name: "default", path: "/home/b")])
        return roster
    }

    func testResolveAmbiguousSlugReturnsBothCandidates() {
        let roster = makeCollisionRoster()
        let result = roster.resolve(profileSlug: slug)
        guard case .ambiguous(let routes) = result else {
            return XCTFail("expected .ambiguous, got \(result)")
        }
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(Set(routes), Set([
            Route(gatewayID: gatewayA, profileSlug: slug),
            Route(gatewayID: gatewayB, profileSlug: slug),
        ]))
    }

    func testResolveUniqueSlugReturnsResolvedRoute() {
        var roster = makeCollisionRoster()
        roster.upsertGateway(FleetGateway(id: gatewayA, displayName: "A"))
        roster.setBots(on: gatewayA, from: [
            ProfileDescriptor(name: "default", path: "/home/a"),
            ProfileDescriptor(name: "researcher", path: "/home/a/r"),
        ])
        let result = roster.resolve(profileSlug: ProfileSlug(rawValue: "researcher"))
        XCTAssertEqual(result, .resolved(
            Route(gatewayID: gatewayA, profileSlug: ProfileSlug(rawValue: "researcher"))))
    }

    func testResolveUnknownSlugReturnsNotFound() {
        let roster = makeCollisionRoster()
        XCTAssertEqual(roster.resolve(profileSlug: ProfileSlug(rawValue: "nope")), .notFound)
    }

    func testResolveUnsafeSlugFailsClosed() {
        let roster = makeCollisionRoster()
        // A traversal slug is never interpreted — even though ".." matches
        // nothing, it must be .invalid, not .notFound, so a caller can
        // distinguish "not registered" from "do not use this key".
        guard case .invalid = roster.resolve(profileSlug: ProfileSlug(rawValue: "../default")) else {
            return XCTFail("expected .invalid for an unsafe slug")
        }
    }

    func testResolveDisplayNameAmbiguityNeverGuesses() {
        var roster = FleetRoster()
        roster.upsertGateway(FleetGateway(id: gatewayA, displayName: "A"))
        roster.upsertGateway(FleetGateway(id: gatewayB, displayName: "B"))
        roster.setBots(on: gatewayA, from: [
            ProfileDescriptor(name: "default", path: "/home/a", displayName: "Main Bot")])
        roster.setBots(on: gatewayB, from: [
            ProfileDescriptor(name: "default", path: "/home/b", displayName: "Main Bot")])

        guard case .ambiguous(let routes) = roster.resolve(displayName: "Main Bot") else {
            return XCTFail("expected .ambiguous for a shared display name, got \(roster.resolve(displayName: "Main Bot"))")
        }
        XCTAssertEqual(routes.count, 2)
    }

    func testResolveDisplayNameUniqueReturnsRoute() {
        var roster = makeCollisionRoster()
        roster.upsertGateway(FleetGateway(id: gatewayA, displayName: "A"))
        roster.setBots(on: gatewayA, from: [
            ProfileDescriptor(name: "default", path: "/home/a", displayName: "Main")])
        let result = roster.resolve(displayName: "Main")
        XCTAssertEqual(result, .resolved(
            Route(gatewayID: gatewayA, profileSlug: slug)))
    }

    func testResolveDisplayNameUnknownReturnsNotFound() {
        let roster = makeCollisionRoster()
        XCTAssertEqual(roster.resolve(displayName: "Ghost Bot"), .notFound)
    }
}
