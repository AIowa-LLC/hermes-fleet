import XCTest
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

/// M0: proves every module boundary compiles and links in the iOS app context,
/// and that each seam exercises its declared dependency direction.
@MainActor
final class ModuleBoundaryTests: XCTestCase {
    func testNetworkingDependsOnCore() {
        let gateway = FleetGateway(id: GatewayID(rawValue: "<dev-workstation>"), displayName: "MacBook")
        XCTAssertEqual(
            FleetNetworkingPlaceholder.describe(gateway),
            "<dev-workstation> · MacBook"
        )
    }

    func testSecurityDependsOnCore() {
        XCTAssertEqual(FleetSecurityPlaceholder.label(for: .readOnly), "readOnly")
    }

    func testPersistenceDependsOnCore() {
        let gateway = FleetGateway(id: GatewayID(rawValue: "gaming-4090"), displayName: "4090")
        XCTAssertEqual(FleetPersistencePlaceholder.displayName(of: gateway), "4090")
    }

    func testUIModelStartsEmpty() {
        let model = FleetDashboardModel()
        XCTAssertTrue(model.gateways.isEmpty)
        XCTAssertFalse(model.isLoading)
    }
}
