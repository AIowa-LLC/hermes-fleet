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

    // MARK: M3 — one-gateway connectivity seam usable from the app

    func testConnectivitySeamIsUsableFromAppComposition() async {
        // The app composition root is the ONLY consumer allowed to depend on
        // FleetNetworking. Prove the M3 seam (FleetCore protocol) is
        // constructible here and reports the expected offline start state,
        // without touching the UI layer.
        let base = URL(string: "http://127.0.0.1:9119")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30), inboundDeadline: .seconds(30),
            connectTimeout: .seconds(2), requestTimeout: .seconds(10)
        )
        let transport = GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticAppTicketMinter(),
            configuration: config
        )
        let connection: any GatewayConnectivityProviding = SingleGatewayConnection(
            gatewayID: GatewayID(rawValue: "<dev-workstation>"),
            displayName: "MacBook",
            endpoint: base,
            transport: transport
        )
        XCTAssertEqual(connection.status, .offline, "newly-registered gateway is offline")
        // Disconnect before any connect: must not crash (spec §31).
        await connection.disconnect()
        XCTAssertEqual(connection.status, .offline)
    }

    /// Minimal ticket minter for the app-level boundary test (no network).
    private struct StaticAppTicketMinter: WSTicketMinting {
        func mintTicket() async throws -> WSTicket {
            WSTicket(token: "fixture-ticket", ttlSeconds: 30)
        }
    }
}
