import XCTest
@testable import FleetCore

/// M9 Routing Collision Hardening — traversal guards on routing keys.
///
/// Covers: the pure `RoutingGuard` validators (route components + session
/// keys), the `Route`/`GatewayID`/`ProfileSlug` safety surfaces, the failable
/// validating `Route` initializer, and the fail-closed ingest of unsafe
/// slugs in `FleetRoster.setBots`.
final class RoutingGuardTests: XCTestCase {

    // MARK: route components — valid tokens pass

    func testValidRouteComponentsPass() {
        for raw in ["default", "researcher", "apple-dev", "gateway-a",
                    "192.168.50.58", "192.168.50.58:8642", "workstation",
                    "arch", "render-box", "a_b_c", "0"] {
            XCTAssertTrue(RoutingGuard.isValidRouteComponent(raw),
                          "expected '\(raw)' to be a safe route component")
        }
    }

    // MARK: route components — traversal / separator / id-collision rejected

    func testPathSeparatorsRejected() {
        for raw in ["a/b", "/etc/passwd", "a\\b", "dir\\..\\file"] {
            XCTAssertFalse(RoutingGuard.isValidRouteComponent(raw),
                           "expected '\(raw)' to be rejected")
        }
    }

    func testTraversalSequencesRejected() {
        for raw in ["..", ".", "../etc", "a/../b", "a..b", "..hidden", "a.."] {
            XCTAssertFalse(RoutingGuard.isValidRouteComponent(raw),
                           "expected '\(raw)' to be rejected")
        }
    }

    func testRouteIDSeparatorRejected() {
        // `#` is the Route.id separator — a component containing it would make
        // the route id ambiguous (a#b/c vs a/b#c both → a#b#c).
        for raw in ["a#b", "#", "a#"] {
            XCTAssertFalse(RoutingGuard.isValidRouteComponent(raw),
                           "expected '\(raw)' to be rejected")
        }
    }

    func testWhitespaceAndControlRejected() {
        for raw in ["a b", " a", "a ", "a\tb", "a\nb", "a\u{0}b", "a\u{7F}"] {
            XCTAssertFalse(RoutingGuard.isValidRouteComponent(raw),
                           "expected '\(raw)' to be rejected")
        }
    }

    func testEmptyRejected() {
        XCTAssertFalse(RoutingGuard.isValidRouteComponent(""))
    }

    // MARK: session keys

    func testValidSessionKeysPass() {
        for raw in ["sess-001", "abc12345", "s1", "a1b2c3d4", "stale"] {
            XCTAssertTrue(RoutingGuard.isValidSessionKey(raw),
                          "expected '\(raw)' to be a safe session key")
        }
    }

    func testSessionKeyTraversalRejected() {
        for raw in ["a/b", "..", "../etc", "a..b", "a\\b", "a b", "a\tb", "", "a\u{0}"] {
            XCTAssertFalse(RoutingGuard.isValidSessionKey(raw),
                           "expected '\(raw)' to be rejected")
        }
    }

    // MARK: value-type safety surfaces

    func testGatewayIDSafetySurface() {
        XCTAssertTrue(GatewayID(rawValue: "workstation").isRoutingSafe)
        XCTAssertTrue(GatewayID(rawValue: "192.168.50.58:8642").isRoutingSafe)
        XCTAssertFalse(GatewayID(rawValue: "../gateway").isRoutingSafe)
        XCTAssertFalse(GatewayID(rawValue: "a/b").isRoutingSafe)
        XCTAssertFalse(GatewayID(rawValue: "a#b").isRoutingSafe)
    }

    func testProfileSlugSafetySurface() {
        XCTAssertTrue(ProfileSlug(rawValue: "researcher").isRoutingSafe)
        XCTAssertFalse(ProfileSlug(rawValue: "../researcher").isRoutingSafe)
        XCTAssertFalse(ProfileSlug(rawValue: "a#b").isRoutingSafe)
    }

    func testRouteSafetySurface() {
        let safe = Route(gatewayID: .init(rawValue: "workstation"),
                         profileSlug: .init(rawValue: "default"))
        XCTAssertTrue(safe.isRoutingSafe)

        let unsafeSlug = Route(gatewayID: .init(rawValue: "workstation"),
                               profileSlug: .init(rawValue: "../default"))
        XCTAssertFalse(unsafeSlug.isRoutingSafe)

        let unsafeGateway = Route(gatewayID: .init(rawValue: "a#b"),
                                  profileSlug: .init(rawValue: "default"))
        XCTAssertFalse(unsafeGateway.isRoutingSafe)
    }

    func testRouteValidatingInitializerFailsClosed() {
        let valid = Route(validating: .init(rawValue: "workstation"),
                          profileSlug: .init(rawValue: "default"))
        XCTAssertNotNil(valid)

        XCTAssertNil(Route(validating: .init(rawValue: "workstation"),
                           profileSlug: .init(rawValue: "../default")))
        XCTAssertNil(Route(validating: .init(rawValue: "a/b"),
                           profileSlug: .init(rawValue: "default")))
        XCTAssertNil(Route(validating: .init(rawValue: "a#b"),
                           profileSlug: .init(rawValue: "c#d")))
    }

    // MARK: fail-closed ingest — unsafe slugs never become routes

    func testSetBotsDropsUnsafeSlugs() {
        var roster = FleetRoster()
        let gateway = GatewayID(rawValue: "workstation")

        roster.setBots(on: gateway, from: [
            ProfileDescriptor(name: "researcher", path: "/home/r"),
            ProfileDescriptor(name: "../etc", path: "/etc"),          // traversal
            ProfileDescriptor(name: "a#b", path: "/home/ab"),         // id collision
            ProfileDescriptor(name: "a/b", path: "/home/ab"),         // separator
        ])

        XCTAssertEqual(roster.bots(on: gateway).count, 1)
        XCTAssertEqual(roster.bots(on: gateway).first?.profileSlug.rawValue, "researcher")
    }

    func testUpsertBotDropsUnsafeRoute() {
        var roster = FleetRoster()
        let gateway = GatewayID(rawValue: "workstation")

        // The safe bot is ingested; the unsafe one is dropped — the union
        // aggregation path (FleetRosterService) uses upsertBot, so this guard
        // matters for a malicious gateway reporting a traversal slug.
        roster.upsertBot(FleetBot(
            route: Route(gatewayID: gateway, profileSlug: .init(rawValue: "researcher")),
            displayName: "R"))
        roster.upsertBot(FleetBot(
            route: Route(gatewayID: gateway, profileSlug: .init(rawValue: "../etc")),
            displayName: "evil"))

        XCTAssertEqual(roster.allBots.count, 1)
        XCTAssertEqual(roster.allBots.first?.profileSlug.rawValue, "researcher")
    }
}
