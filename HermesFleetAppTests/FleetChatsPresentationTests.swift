import XCTest
import FleetUI
import FleetCore

/// Dogfood finding 1 (chat-list polish) — how the Chats screen reports a
/// PARTIAL refresh failure.
///
/// A refresh can fail for some routes while other routes still hold usable
/// cached/retained sessions. The failure must stay truthful and retryable,
/// but it must not push a list the user can actually use off the screen.
/// These are pure presentation decisions, so they are unit-testable without
/// a UI host; navigation, protocol, and gateway semantics are untouched.
final class FleetChatsPresentationTests: XCTestCase {

    private let workstation = GatewayID(rawValue: "workstation")
    private let arch = GatewayID(rawValue: "arch")

    private func route(_ gateway: GatewayID, _ slug: String) -> Route {
        Route(gatewayID: gateway, profileSlug: ProfileSlug(rawValue: slug))
    }

    // MARK: - Failure surface decision

    func testNoFailuresRendersNoFailureSurface() {
        XCTAssertEqual(
            FleetChatsPresentation.refreshFailureSurface(
                failedRouteCount: 0, hasUsableSessions: false),
            .none)
        XCTAssertEqual(
            FleetChatsPresentation.refreshFailureSurface(
                failedRouteCount: 0, hasUsableSessions: true),
            .none)
    }

    func testFailureWithUsableSessionsStaysCompactAndInline() {
        XCTAssertEqual(
            FleetChatsPresentation.refreshFailureSurface(
                failedRouteCount: 1, hasUsableSessions: true),
            .inline,
            "a partial failure must not displace conversations the user can still read")
    }

    func testFailureWithNothingUsableRaisesTheStrongerSurface() {
        XCTAssertEqual(
            FleetChatsPresentation.refreshFailureSurface(
                failedRouteCount: 2, hasUsableSessions: false),
            .prominent)
    }

    // MARK: - Failure scoping (report only what Chats can retry)

    /// A route that has LEFT the roster cannot be re-read by the Chats
    /// `Retry` (the refresh walks the current roster), so its stale error must
    /// not pin the failure banner on screen forever.
    func testStaleFailuresOnRoutesOutsideTheRosterAreNotReported() {
        let inRoster = route(workstation, "default")
        let stale = route(arch, "default")
        let reported = FleetChatsPresentation.currentFailureRoutes(
            failedRoutes: [inRoster, stale],
            rosterRoutes: [inRoster])
        XCTAssertEqual(reported, [inRoster], "only the retryable failure is reported")
    }

    /// ...but a real, still-retryable failure is never swallowed.
    func testInRosterFailuresAreNeverSwallowed() {
        let a = route(workstation, "default")
        let b = route(workstation, "researcher")
        let reported = FleetChatsPresentation.currentFailureRoutes(
            failedRoutes: [a, b],
            rosterRoutes: [a, b])
        XCTAssertEqual(reported, [a, b])
    }

    func testNoFailuresReportsEmptySet() {
        XCTAssertTrue(
            FleetChatsPresentation.currentFailureRoutes(
                failedRoutes: [], rosterRoutes: [route(workstation, "default")]).isEmpty)
    }

    // MARK: - Truthful prominent copy

    func testProminentCopyDistinguishesTotalFromPartialOutage() {
        let total = FleetChatsPresentation.prominentFailureDetail(
            failedRouteCount: 2, totalRouteCount: 2)
        let partial = FleetChatsPresentation.prominentFailureDetail(
            failedRouteCount: 1, totalRouteCount: 2)
        XCTAssertNotEqual(total, partial, "partial vs total copy must be truthful")
        XCTAssertTrue(total.localizedCaseInsensitiveContains("none of your gateways"),
                      "total outage may claim no gateway returned conversations (got: \(total))")
        XCTAssertFalse(partial.localizedCaseInsensitiveContains("none of your gateways"),
                       "a partial outage must not claim the whole fleet is down (got: \(partial))")
        for copy in [total, partial] {
            XCTAssertTrue(copy.localizedCaseInsensitiveContains("retry"),
                          "the failure copy must offer the retry path (got: \(copy))")
        }
    }

    func testProminentCopyTreatsMoreFailuresThanRoutesAsTotal() {
        // Defensive: never under-claim when the counts disagree.
        XCTAssertEqual(
            FleetChatsPresentation.prominentFailureDetail(failedRouteCount: 3, totalRouteCount: 2),
            FleetChatsPresentation.prominentFailureDetail(failedRouteCount: 2, totalRouteCount: 2))
    }

    // MARK: - Issue 3: bottom breathing room is a design token, not a magic number

    func testBottomBreathingRoomComesFromTheDesignTokenScale() {
        XCTAssertEqual(FleetChatsListLayout.bottomBreathingRoom, FleetTheme.spacingXl,
                       "the reserve must come from the design-token scale, never a device constant")
        XCTAssertGreaterThan(FleetChatsListLayout.bottomBreathingRoom, 0)
    }
}