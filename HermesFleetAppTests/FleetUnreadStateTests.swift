import XCTest
import FleetCore
@testable import FleetUI

/// Regression contracts for device-local unread state and the gateway's
/// runtime-vs-stored conversation identities.
@MainActor
final class FleetUnreadStateTests: XCTestCase {
    func testFirstObservationBaselinesExistingSessionsButFutureSessionIsUnread() {
        let defaults = UserDefaults(suiteName: "FleetUnreadStateTests.baseline")!
        defaults.removePersistentDomain(forName: "FleetUnreadStateTests.baseline")
        defer { defaults.removePersistentDomain(forName: "FleetUnreadStateTests.baseline") }

        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default"))
        let existing = SessionSummary(
            id: "stored-existing", title: "Existing", lastActive: 100)
        let future = SessionSummary(
            id: "stored-future", title: "Future", lastActive: 200)

        FleetUnreadStore.baseline(
            route: route,
            sessions: [existing],
            defaults: defaults)

        XCTAssertTrue(FleetUnreadStore.isRouteBaselined(route, defaults: defaults))
        XCTAssertFalse(FleetUnreadStore.isUnread(route: route, session: existing, defaults: defaults))
        XCTAssertTrue(FleetUnreadStore.isUnread(route: route, session: future, defaults: defaults))
    }

    func testUnknownActivityNeverLightsAfterBaseline() {
        let defaults = UserDefaults(suiteName: "FleetUnreadStateTests.unknown")!
        defaults.removePersistentDomain(forName: "FleetUnreadStateTests.unknown")
        defer { defaults.removePersistentDomain(forName: "FleetUnreadStateTests.unknown") }

        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default"))
        let unknown = SessionSummary(id: "stored-unknown", title: "Unknown", lastActive: 0)

        FleetUnreadStore.baseline(route: route, sessions: [unknown], defaults: defaults)

        XCTAssertFalse(FleetUnreadStore.isUnread(route: route, session: unknown, defaults: defaults))
    }

    func testDurableConversationIdentityPrefersListedRowThenStoredResponse() {
        let opened = ConversationSession(
            sessionID: "runtime-1",
            storedSessionID: "stored-1")

        XCTAssertEqual(
            ConversationViewModel.durableSessionID(listedSessionID: "listed-1", opened: opened),
            "listed-1")
        XCTAssertEqual(
            ConversationViewModel.durableSessionID(listedSessionID: nil, opened: opened),
            "stored-1")
    }
}
