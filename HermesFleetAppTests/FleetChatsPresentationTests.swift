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

    // MARK: - Finding 5: settled claims only after the refresh completes

    /// While the refresh is still running, other routes have not returned yet,
    /// so the prominent surface must NOT claim they "returned no
    /// conversations"; once it settles, the settled wording returns.
    func testProminentPartialCopyGatesSettledClaimUntilRefreshCompletes() {
        let settled = FleetChatsPresentation.prominentFailureDetail(
            failedRouteCount: 1, totalRouteCount: 2, isRefreshing: false)
        let loading = FleetChatsPresentation.prominentFailureDetail(
            failedRouteCount: 1, totalRouteCount: 2, isRefreshing: true)
        XCTAssertNotEqual(loading, settled,
                          "the partial copy must change while other routes are still loading")
        XCTAssertTrue(settled.localizedCaseInsensitiveContains("returned no conversations"),
                      "settled partial copy states the honest settled claim (got: \(settled))")
        XCTAssertFalse(loading.localizedCaseInsensitiveContains("returned no conversations"),
                       "a still-refreshing surface must not claim the rest returned nothing (got: \(loading))")
        for copy in [settled, loading] {
            XCTAssertTrue(copy.localizedCaseInsensitiveContains("retry"),
                          "the failure copy must keep the retry path visible (got: \(copy))")
        }
    }

    /// With EVERY current route failed there is nothing left loading, so the
    /// total-outage claim is already settled and identical either way.
    func testProminentTotalCopyIsUnchangedWhileRefreshing() {
        XCTAssertEqual(
            FleetChatsPresentation.prominentFailureDetail(
                failedRouteCount: 2, totalRouteCount: 2, isRefreshing: true),
            FleetChatsPresentation.prominentFailureDetail(
                failedRouteCount: 2, totalRouteCount: 2, isRefreshing: false))
    }

    /// Default preserves the historical (settled) signature for callers that
    /// do not pass a refresh state.
    func testProminentCopyDefaultsToSettled() {
        XCTAssertEqual(
            FleetChatsPresentation.prominentFailureDetail(failedRouteCount: 1, totalRouteCount: 2),
            FleetChatsPresentation.prominentFailureDetail(
                failedRouteCount: 1, totalRouteCount: 2, isRefreshing: false))
    }

    // MARK: - Finding 4: truthful, filter-scoped empty state

    /// The first-run copy may only appear when nothing filters the list.
    func testEmptyStateKeepsFirstRunCopyOnlyWithoutAnyFilter() {
        let state = FleetChatsPresentation.emptyState(
            hasQuery: false, hasGatewayFilter: false, hasUsableSessions: false)
        XCTAssertEqual(state.title, "Your next idea starts here")
    }

    /// A gateway filter that hides usable conversations must NOT claim the user
    /// has no data — the copy is scoped to the filtered gateway.
    func testEmptyStateIsFilterScopedWhenGatewayFilterHidesUsableData() {
        let state = FleetChatsPresentation.emptyState(
            hasQuery: false, hasGatewayFilter: true, hasUsableSessions: true)
        XCTAssertNotEqual(state.title, "Your next idea starts here",
                          "a filtered-empty screen must not claim there is no data")
        XCTAssertTrue(state.title.localizedCaseInsensitiveContains("gateway"),
                      "the empty copy must name the filtered scope (got: \(state.title))")
        XCTAssertTrue(state.description.localizedCaseInsensitiveContains("gateway"),
                      "the empty description must offer the gateway-scoped path (got: \(state.description))")
    }

    /// The gateway-filter copy is truthful whether or not data exists
    /// elsewhere — it never claims absence of usable data.
    func testEmptyStateGatewayScopeNeverClaimsNoData() {
        for usable in [true, false] {
            let state = FleetChatsPresentation.emptyState(
                hasQuery: false, hasGatewayFilter: true, hasUsableSessions: usable)
            XCTAssertFalse(state.title.localizedCaseInsensitiveContains("next idea"))
            XCTAssertFalse(state.description.localizedCaseInsensitiveContains("choose a bot to begin"))
        }
    }

    /// A query keeps its own copy — and wins over the gateway scope — but still
    /// never falls back to the first-run claim.
    func testEmptyStateQueryCopyIsUnchangedAndNeverFirstRun() {
        let queryOnly = FleetChatsPresentation.emptyState(
            hasQuery: true, hasGatewayFilter: false, hasUsableSessions: false)
        XCTAssertEqual(queryOnly.title, "No matching conversations")
        let both = FleetChatsPresentation.emptyState(
            hasQuery: true, hasGatewayFilter: true, hasUsableSessions: true)
        XCTAssertEqual(both.title, "No matching conversations")
    }

    /// Defensive: with no filter, usable sessions hidden by something else must
    /// still not be reported as "no data".
    func testEmptyStateWithoutFilterAndUsableSessionsNeverClaimsFirstRun() {
        let state = FleetChatsPresentation.emptyState(
            hasQuery: false, hasGatewayFilter: false, hasUsableSessions: true)
        XCTAssertNotEqual(state.title, "Your next idea starts here",
                          "usable (if unrendered) conversations must not be denied")
    }
}