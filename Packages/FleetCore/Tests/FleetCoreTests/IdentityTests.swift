import XCTest
@testable import FleetCore

final class IdentityTests: XCTestCase {
    func testGatewayIDEqualityAndHash() {
        let a = GatewayID(rawValue: "workstation")
        let b = GatewayID(rawValue: "workstation")
        let c = GatewayID(rawValue: "render-box")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(Set([a, b, c]).count, 2)
    }

    func testGatewayIDDescriptionIsRawValue() {
        XCTAssertEqual(String(describing: GatewayID(rawValue: "workstation")), "workstation")
    }

    func testProfileSlugAndGatewayIDAreDistinctTypes() {
        // Canonical identity = GatewayID + ProfileSlug; equal raw values across
        // the two types are still distinct identities.
        let slug = ProfileSlug(rawValue: "researcher")
        let gid = GatewayID(rawValue: "researcher")
        XCTAssertEqual(slug.rawValue, gid.rawValue)
        XCTAssertNotEqual(String(reflecting: type(of: slug)), String(reflecting: type(of: gid)))
    }

    func testGatewayIDCodableRoundTrip() throws {
        let value = GatewayID(rawValue: "workstation")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(GatewayID.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}
