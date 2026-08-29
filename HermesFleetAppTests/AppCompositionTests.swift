import XCTest
import FleetUI
import FleetCore

/// Composition smoke tests: the app starts with a clean, inert fleet model.
@MainActor
final class AppCompositionTests: XCTestCase {
    func testAppStartsWithEmptyFleet() {
        let model = FleetDashboardModel()
        XCTAssertTrue(model.gateways.isEmpty, "M0 app starts with no gateways")
        XCTAssertEqual(model.gateways.count, 0)
    }

    func testAppModelIsMainActorAndSendableFriendly() {
        // Constructing through the @MainActor boundary must not trap or crash.
        let model = FleetDashboardModel(gateways: [
            FleetGateway(id: GatewayID(rawValue: "<dev-workstation>"), displayName: "MacBook")
        ])
        XCTAssertEqual(model.gateways.count, 1)
        XCTAssertEqual(model.gateways.first?.displayName, "MacBook")
    }
}
