import XCTest
@testable import FleetCore

final class DomainTests: XCTestCase {
    func testAuthorizationClassRawValues() {
        XCTAssertEqual(AuthorizationClass.readOnly.rawValue, "readOnly")
        XCTAssertEqual(AuthorizationClass.reversibleWrite.rawValue, "reversibleWrite")
        XCTAssertEqual(AuthorizationClass.highImpact.rawValue, "highImpact")
    }

    func testAuthorizationClassLatticeSurface() {
        // Lattice: none < readOnly < reversibleWrite < highImpact.
        XCTAssertEqual(AuthorizationClass.allCases.count, 3)
        XCTAssertEqual(AuthorizationClass.allCases.first, .readOnly)
        XCTAssertEqual(AuthorizationClass.allCases.last, .highImpact)
    }

    func testFleetGatewayIdentifiable() {
        let id = GatewayID(rawValue: "workstation")
        let gateway = FleetGateway(id: id, displayName: "MacBook")
        XCTAssertEqual(gateway.id, id)
        XCTAssertEqual(gateway.displayName, "MacBook")
    }

    func testTransportStateEquality() {
        XCTAssertEqual(TransportState.disconnected, .disconnected)
        XCTAssertNotEqual(TransportState.connected, .connecting)
        XCTAssertEqual(TransportState.failed("boom"), .failed("boom"))
        XCTAssertNotEqual(TransportState.failed("boom"), .failed("bang"))
    }
}
