import XCTest
import FleetNetworking

final class CloseCodeMappingTests: XCTestCase {
    func testGatewayApplicationCodes() {
        XCTAssertEqual(CloseCodeMapping.reason(forRawCode: 4400), .invalidChannel)
        XCTAssertEqual(CloseCodeMapping.reason(forRawCode: 4401), .reauthenticationRequired)
        XCTAssertEqual(CloseCodeMapping.reason(forRawCode: 4403), .hostMismatch)
        XCTAssertEqual(CloseCodeMapping.reason(forRawCode: 4404), .chatDisabled)
        XCTAssertEqual(CloseCodeMapping.reason(forRawCode: 4408), .peerNotAllowed)
        XCTAssertEqual(CloseCodeMapping.reason(forRawCode: 1011), .serverError)
    }

    func testStandardCodes() {
        XCTAssertEqual(CloseCodeMapping.reason(forRawCode: 1000), .normalClosure)
        XCTAssertEqual(CloseCodeMapping.reason(forRawCode: 1001), .goingAway)
        XCTAssertEqual(CloseCodeMapping.reason(forRawCode: 1006), .abnormalClosure)
        XCTAssertEqual(CloseCodeMapping.reason(forRawCode: 1015), .tlsHandshakeFailure)
    }

    func testUnknownCode() {
        let reason = CloseCodeMapping.reason(forRawCode: 4999)
        XCTAssertEqual(reason, .unknown(code: 4999, detail: "unclassified close code"))
    }

    func testAuthFailureFlag() {
        XCTAssertTrue(CloseCodeMapping.reason(forRawCode: 4401).isAuthFailure)
        XCTAssertFalse(CloseCodeMapping.reason(forRawCode: 1011).isAuthFailure)
        XCTAssertFalse(CloseCodeMapping.reason(forRawCode: 1000).isAuthFailure)
    }

    func testCloseCodeEnumRawValuePreserves44xx() {
        // The gateway sends 4401 as a raw integer; URLSession's CloseCode
        // enum retains the raw value through rawValue even when no named case
        // matches (verified: rawValue(4401) is non-nil). CloseCodeMapping
        // therefore maps via the raw integer path.
        let raw4401 = URLSessionWebSocketTask.CloseCode(rawValue: 4401)
        XCTAssertNotNil(raw4401)
        XCTAssertEqual(raw4401?.rawValue, 4401)
        XCTAssertEqual(CloseCodeMapping.reason(forRawCode: raw4401?.rawValue ?? 0), .reauthenticationRequired)
        XCTAssertEqual(CloseCodeMapping.reason(forCloseCode: .normalClosure), .normalClosure)
    }

    func testURLSessionCloseCodeMapping() {
        XCTAssertEqual(
            CloseCodeMapping.reason(forCloseCode: .normalClosure), .normalClosure)
        XCTAssertEqual(
            CloseCodeMapping.reason(forCloseCode: .internalServerError), .serverError)
    }

    func testErrorMappingNetworkLost() {
        let error = URLError(.networkConnectionLost)
        XCTAssertEqual(CloseCodeMapping.reason(for: error), .abnormalClosure)
    }

    func testErrorMappingTLSSelfSigned() {
        let error = URLError(.serverCertificateUntrusted)
        XCTAssertEqual(CloseCodeMapping.reason(for: error), .tlsHandshakeFailure)
    }

    func testErrorMappingUnknown() {
        let error = NSError(domain: "com.example", code: -7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        let reason = CloseCodeMapping.reason(for: error)
        XCTAssertEqual(reason, .unknown(code: -7, detail: "boom"))
    }

    func testReasonDebugDescriptions() {
        XCTAssertTrue(DisconnectReason.reauthenticationRequired.debugDescription.contains("4401"))
        XCTAssertTrue(DisconnectReason.peerNotAllowed.debugDescription.contains("4408"))
        XCTAssertTrue(DisconnectReason.serverError.debugDescription.contains("1011"))
    }
}
