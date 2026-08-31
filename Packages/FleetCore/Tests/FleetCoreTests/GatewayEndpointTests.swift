import XCTest
import FleetCore

/// P1-6 — endpoint-as-origin normalization at the registry boundary.
final class GatewayEndpointTests: XCTestCase {

    func testNormalizedOriginKeepsCleanURL() throws {
        let url = try GatewayEndpoint.normalizedOrigin(from: URL(string: "http://127.0.0.1:8642")!)
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8642")
    }

    func testNormalizedOriginStripsQueryAndFragment() throws {
        let url = try GatewayEndpoint.normalizedOrigin(
            from: URL(string: "https://gw.example.com/api?token=secret&a=1#frag")!)
        XCTAssertEqual(url.absoluteString, "https://gw.example.com/api")
        XCTAssertFalse(url.absoluteString.contains("secret"))
    }

    func testNormalizedOriginRejectsUserInfo() {
        XCTAssertThrowsError(
            try GatewayEndpoint.normalizedOrigin(from: URL(string: "http://user:pass@127.0.0.1:8642")!)
        ) { error in
            XCTAssertEqual(error as? GatewayRegistryError, .invalidEndpoint)
        }
    }

    func testNormalizedOriginRejectsNonHTTPS() {
        XCTAssertThrowsError(
            try GatewayEndpoint.normalizedOrigin(from: URL(string: "ftp://host")!)
        ) { error in
            XCTAssertEqual(error as? GatewayRegistryError, .invalidEndpoint)
        }
    }
}
