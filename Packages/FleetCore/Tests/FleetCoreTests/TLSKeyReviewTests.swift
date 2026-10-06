import XCTest
@testable import FleetCore

final class TLSKeyReviewTests: XCTestCase {
    private let endpoint = URL(string: "https://gateway.example.invalid:8642")!
    private let key = SPKIFingerprint(rawBytes: Array(0..<32).map { UInt8($0) })

    func testDisplayFingerprintIsFullColonSeparatedUppercaseHex() {
        let review = TLSKeyReview(endpoint: endpoint, fingerprint: key)
        XCTAssertTrue(review.displayFingerprint.hasPrefix("00:01:02:03"))
        XCTAssertEqual(review.displayFingerprint.split(separator: ":").count, 32)
    }

    func testValidatesSameOriginIgnoringCaseAndDefaultPortAndTrailingSlash() throws {
        let review = TLSKeyReview(endpoint: URL(string: "https://Gateway.Example.invalid")!, fingerprint: key)
        try review.validate(for: URL(string: "https://gateway.example.invalid:443/")!)
    }

    func testRejectsDifferentHostPortSchemeOrPath() {
        let review = TLSKeyReview(endpoint: endpoint, fingerprint: key)
        for other in ["https://other.example.invalid:8642", "https://gateway.example.invalid:9999",
                      "http://gateway.example.invalid:8642", "https://gateway.example.invalid:8642/gw"] {
            XCTAssertThrowsError(try review.validate(for: URL(string: other)!), other) {
                XCTAssertEqual($0 as? TLSKeyReviewError, .endpointChanged)
            }
        }
    }

    func testExpiryBoundary() throws {
        let now = Date()
        let review = TLSKeyReview(endpoint: endpoint, fingerprint: key, reviewedAt: now)
        try review.validate(for: endpoint, now: now.addingTimeInterval(TLSKeyReview.maxAge))
        XCTAssertThrowsError(try review.validate(for: endpoint, now: now.addingTimeInterval(TLSKeyReview.maxAge + 1)))
        XCTAssertThrowsError(try review.validate(for: endpoint, now: now.addingTimeInterval(-1)))
    }
}
