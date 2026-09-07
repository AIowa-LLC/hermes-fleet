import XCTest
import Security
import Foundation
@testable import FleetNetworking

/// T3 — SPKI fingerprint computation from a `SecCertificate` (the pin the
/// app derives during the TLS handshake) must match the openssl-computed
/// reference for the SAME certificate (sha256 of the DER SPKI, base64).
final class SPKIExtractionTests: XCTestCase {

    func testGatewayFixturePinMatchesOpensslReference() throws {
        let cert = try XCTUnwrap(
            SecCertificateCreateWithData(nil, TLSFixtureIdentities.gatewayCertificateDER as CFData),
            "fixture cert DER must load"
        )
        let pin = try XCTUnwrap(SPKIExtractor.fingerprint(from: cert))
        XCTAssertEqual(pin.base64String, TLSFixtureIdentities.gatewaySPKIBase64,
                       "app-computed SPKI pin must equal the openssl reference")
    }

    func testMitmFixturePinDiffersFromGateway() throws {
        let gatewayCert = try XCTUnwrap(
            SecCertificateCreateWithData(nil, TLSFixtureIdentities.gatewayCertificateDER as CFData))
        let mitmCert = try XCTUnwrap(
            SecCertificateCreateWithData(nil, TLSFixtureIdentities.mitmCertificateDER as CFData))
        let gatewayPin = try XCTUnwrap(SPKIExtractor.fingerprint(from: gatewayCert))
        let mitmPin = try XCTUnwrap(SPKIExtractor.fingerprint(from: mitmCert))
        XCTAssertNotEqual(gatewayPin, mitmPin, "two different keys must pin differently")
        XCTAssertEqual(mitmPin.base64String, TLSFixtureIdentities.mitmSPKIBase64)
    }

    func testSameCertificateProducesIdenticalPin() throws {
        let cert = try XCTUnwrap(
            SecCertificateCreateWithData(nil, TLSFixtureIdentities.gatewayCertificateDER as CFData))
        let a = try XCTUnwrap(SPKIExtractor.fingerprint(from: cert))
        let b = try XCTUnwrap(SPKIExtractor.fingerprint(from: cert))
        XCTAssertEqual(a, b, "pin computation must be deterministic")
    }
}
