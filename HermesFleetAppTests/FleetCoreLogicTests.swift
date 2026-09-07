import XCTest
import FleetCore

/// FleetCore value-type logic, exercised through the iOS app test host.
final class FleetCoreLogicTests: XCTestCase {
    func testGatewayIDEqualityAndHash() {
        let a = GatewayID(rawValue: "workstation")
        let b = GatewayID(rawValue: "workstation")
        let c = GatewayID(rawValue: "render-box")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(Set([a, b, c]).count, 2)
    }

    func testGatewayIDCodableRoundTrip() throws {
        let value = GatewayID(rawValue: "workstation")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(GatewayID.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testAuthorizationClassSurface() {
        XCTAssertEqual(AuthorizationClass.readOnly.rawValue, "readOnly")
        XCTAssertEqual(AuthorizationClass.reversibleWrite.rawValue, "reversibleWrite")
        XCTAssertEqual(AuthorizationClass.highImpact.rawValue, "highImpact")
        XCTAssertEqual(AuthorizationClass.allCases.count, 3)
    }

    func testProfileSlugAndGatewayIDAreDistinctTypes() {
        let slug = ProfileSlug(rawValue: "researcher")
        let gid = GatewayID(rawValue: "researcher")
        XCTAssertEqual(slug.rawValue, gid.rawValue)
        XCTAssertNotEqual(String(reflecting: type(of: slug)), String(reflecting: type(of: gid)))
    }

    func testTransportStateEquality() {
        XCTAssertEqual(TransportState.connected, .connected)
        XCTAssertNotEqual(TransportState.connected, .connecting)
        XCTAssertEqual(TransportState.failed("boom"), .failed("boom"))
    }
}
