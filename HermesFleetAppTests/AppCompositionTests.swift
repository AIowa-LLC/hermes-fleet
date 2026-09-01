import XCTest
import FleetUI
import FleetCore
@testable import HermesFleetApp

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

// MARK: P0-5 — default environment selection (scripted fleet = simulator only)

extension AppCompositionTests {

    /// P0-5 regression: on the SIMULATOR the default environment must remain
    /// the scripted fleet (CI deterministic suites + local dev walkthrough).
    /// The device-Debug branch (production graph) cannot be unit-tested here
    /// — it is enforced by `#if DEBUG && targetEnvironment(simulator)` around
    /// FleetSimulator (the fake fleet cannot even COMPILE into a device
    /// build) and by the device-binary check in scripts/p05_device_deploy.sh.
    @MainActor
    func testDefaultEnvironmentOnSimulatorIsScriptedFleet() async {
        let environment = FleetServiceGraph.makeDefaultEnvironment()
        await environment.load()
        let ids = environment.gateways.map(\.id.rawValue)
        XCTAssertTrue(
            ids.contains("<dev-workstation>"),
            "simulator default environment must seed the scripted fleet (got: \(ids))"
        )
    }
}
