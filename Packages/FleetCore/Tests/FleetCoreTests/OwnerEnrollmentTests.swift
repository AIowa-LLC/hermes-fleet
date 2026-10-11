import XCTest
@testable import FleetCore

final class OwnerEnrollmentTests: XCTestCase {
    func testOwnerAuthorizationPrintableFormsAreRedacted() {
        let bearer = OwnerAuthorization.bearer("synthetic-access-token")
        let cookie = OwnerAuthorization.sessionCookie(name: "session", value: "synthetic-cookie")
        XCTAssertEqual(bearer.description, "[REDACTED]")
        XCTAssertFalse(bearer.debugDescription.contains("synthetic"))
        XCTAssertEqual(cookie.description, "[REDACTED]")
        XCTAssertFalse(cookie.debugDescription.contains("synthetic"))
    }

    func testDeviceCredentialIsAFirstClassAuthStrategy() throws {
        let data = try JSONEncoder().encode(GatewayAuthConfiguration.Strategy.deviceCredential)
        let decoded = try JSONDecoder().decode(GatewayAuthConfiguration.Strategy.self, from: data)
        XCTAssertEqual(decoded, .deviceCredential)
        XCTAssertTrue(GatewayAuthConfiguration.Strategy.allCases.contains(.deviceCredential))
    }

    func testPendingIdentityPrintableFormsAreRedacted() {
        let identity = PendingOwnerDeviceIdentity(
            deviceID: "0123456789abcdef0123456789abcdef",
            secret: "abcdefghijklmnopqrstuv-0123456789ABCDEFGH")
        XCTAssertEqual(identity.description, "[REDACTED]")
        XCTAssertFalse(identity.debugDescription.contains(identity.secret))
    }
}
