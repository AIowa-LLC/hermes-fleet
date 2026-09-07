import XCTest
@testable import FleetCore

/// F2 — PairingPayload v1 round-trip + hardening tests.
///
/// The pairing QR encodes this exact JSON, so encoding determinism and strict
/// version handling are contract, not convenience.
final class PairingPayloadTests: XCTestCase {

    // MARK: Round-trip

    func testRoundTripThroughCompactEncoder() throws {
        let payload = PairingPayload(
            url: "http://192.168.50.37:8642",
            username: "pair-op",
            password: "test-pairing-secret-000000000001"
        )
        let encoded = payload.encoded()
        let decoded = try PairingPayload.decode(encoded)
        XCTAssertEqual(decoded, payload)
    }

    func testRoundTripThroughJSONEncoderOutput() throws {
        // A gateway may emit the payload with its own JSON encoder — decode
        // must accept any equivalent JSON object, not just our compact form.
        let payload = PairingPayload(url: "https://gw.example.com:9443", username: "u", password: "p")
        let data = try JSONEncoder().encode(payload)
        let text = String(data: data, encoding: .utf8)!
        let decoded = try PairingPayload.decode(text)
        XCTAssertEqual(decoded, payload)
    }

    // MARK: Encoding shape

    func testEncodedJSONIsCompactWithSortedKeys() {
        let payload = PairingPayload(url: "http://10.0.0.5:8642", username: "u1", password: "p1")
        XCTAssertEqual(payload.encoded(), "{\"password\":\"p1\",\"url\":\"http://10.0.0.5:8642\",\"username\":\"u1\",\"v\":1}")
    }

    func testEncodedJSONEscapesSpecialCharacters() throws {
        let payload = PairingPayload(url: "http://h", username: "a\"b\\c", password: "x\ny\tz")
        let encoded = payload.encoded()
        // The encoded string must itself be valid JSON.
        let data = try XCTUnwrap(encoded.data(using: .utf8))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["username"] as? String, "a\"b\\c")
        XCTAssertEqual(obj["password"] as? String, "x\ny\tz")
    }

    // MARK: Decode hardening

    func testDecodeRejectsNonJSON() {
        XCTAssertThrowsError(try PairingPayload.decode("hermes-fleet:connect")) { error in
            XCTAssertEqual(error as? PairingPayload.DecodeError, .notAPairingPayload)
        }
    }

    func testDecodeRejectsWrongShape() {
        XCTAssertThrowsError(try PairingPayload.decode("{\"v\":1}")) { error in
            XCTAssertEqual(error as? PairingPayload.DecodeError, .notAPairingPayload)
        }
    }

    func testDecodeRejectsFutureVersion() {
        let future = "{\"password\":\"p\",\"url\":\"http://h\",\"username\":\"u\",\"v\":2}"
        XCTAssertThrowsError(try PairingPayload.decode(future)) { error in
            XCTAssertEqual(error as? PairingPayload.DecodeError, .unsupportedVersion(2))
        }
    }

    func testDecodeRejectsEmptyRequiredField() {
        let emptyUser = "{\"password\":\"p\",\"url\":\"http://h\",\"username\":\"\",\"v\":1}"
        XCTAssertThrowsError(try PairingPayload.decode(emptyUser)) { error in
            XCTAssertEqual(error as? PairingPayload.DecodeError, .emptyField)
        }
    }

    // MARK: Realistic size

    func testRealisticPayloadFitsCompactQR() {
        // F2 sizing: endpoint + a 42-char generated secret must stay well
        // under QR version 40 numeric limits; binary/UTF-8 mode caps at 2953
        // bytes. Compact JSON keeps realistic payloads in low versions
        // (dense modules, easier scans).
        let payload = PairingPayload(
            url: "http://100.100.200.61:8642",
            username: "fleet-operator",
            password: "test-pairing-secret-00000000000000000000000000001"
        )
        XCTAssertLessThan(payload.encoded().utf8.count, 512)
    }
}
