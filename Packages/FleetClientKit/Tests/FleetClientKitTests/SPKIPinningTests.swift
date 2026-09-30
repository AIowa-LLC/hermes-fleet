import XCTest
import Security
import FleetCore
@testable import FleetClientKit

/// Known-answer tests for the extension-safe SPKI pin computation. The P-256
/// vector is the same synthetic certificate/pin pair FleetNetworking's
/// `SPKIExtractionTests` use (computed with openssl), so the two independent
/// implementations are pinned to one reference. The RSA vector is an additional
/// synthetic certificate generated with openssl.
final class SPKIPinningTests: XCTestCase {
    // Synthetic fixtures — no real hosts, keys, or identities.
    static let p256CertificateDER = Data(base64Encoded: "MIIBVzCB/aADAgECAgkA+oIUXbGapFUwCgYIKoZIzj0EAwIwITEfMB0GA1UEAwwWaGVybWVzLWdhdGV3YXktZml4dHVyZTAeFw0yNjA5MjQwNzM3MjlaFw00NjA5MTkwNzM3MjlaMCExHzAdBgNVBAMMFmhlcm1lcy1nYXRld2F5LWZpeHR1cmUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATt4VVvBVvVgRZI/bm+2uSXZsnM3s7zJ1bLg5MujC84+TXgx2ng0Lhd7BFTP/6R+OsoXPM0ofqDD6mjXoyITMc4ox4wHDAaBgNVHREEEzARhwR/AAABgglsb2NhbGhvc3QwCgYIKoZIzj0EAwIDSQAwRgIhAIkRUZslTUw+15Yr2qYlN0Zx2jSzWH7X15hFAa5r+9YfAiEAiixZ5EBqlmJjMVCo7RQJpnFoqxkCilGa8DTJfiXk4RE=")!
    static let p256SPKIBase64 = "cVHgL9Z89Wbfc7y4S2AypmccSjn5Ac89WLNwSN37zAI="

    static let rsaCertificateDER = Data(base64Encoded: "MIICyDCCAbACCQDse6BIc4+d/DANBgkqhkiG9w0BAQsFADAmMSQwIgYDVQQDDBtmbGVldC1jbGllbnRraXQtcnNhLWZpeHR1cmUwHhcNMjYwOTMwMTcxOTE4WhcNNDYwOTI1MTcxOTE4WjAmMSQwIgYDVQQDDBtmbGVldC1jbGllbnRraXQtcnNhLWZpeHR1cmUwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDTVbzw2grpZrEb/GFCEW5dCaLDn2m5mGawnyIk56N2iiD/mxxsRLRCrNu+q1iqW6T2FAR8eKeTtERk9qTgdE9h13BCW604hf5qoqqPrF2wBo5i8A9BTBAs+iXXouqlZONTe22qcBz8+2Du7hdEwpsq5rGT7ePEvH1a6XGA/rgAyJoCeSpADQwUTQ3l5nXookrRI+d415/tsq57gij1GsZ3FfhKTzE3xfDKLorXnT5QePgSsaP7WkNATThhAhNFjUB0EOrsqgR67G9oEaQ7br4Z41HvPTzcnMRo3bXTIMJOVFCquzrNYsUy3i9wyErlIqkWd3KOhB3j2Md7XGw9J9orAgMBAAEwDQYJKoZIhvcNAQELBQADggEBAE2Uy/sV8Aral5SgK+3FCnSlOF2yzeOYtR+gebfu3Qnn0PeqHvS4cij1AI0n4JhtMhSVdexqM3A/04zBeMCUnG1XxNRltsEujN1S9fFiJa9G96SP1XdRznA0oV9h0lX7XuOULUmXIE16fKRRSUPh4NEcM3iGoMU20d6VaS5F0hWoCprujwJ0orSp9eD8NeoaPLYNdL9AxYXAyM12Zoh00TTG2SuX8rfy6jOSVAZ5tyJV6QzLj2iaWcHiEJMfvqxi0FOZNs0wHcjnOQBXgk6m1UAwVPMuwwEAC/WIIze8q7A2M9FoYre1ZbUal4vJOI/0R4b5KDunB/WQzQlKrqhZUdk=")!
    static let rsaSPKIBase64 = "HHqi+KVUaPdO7Y7uqn1I+qNEoI2whPbEjYpjaCefNzQ="

    private let gateway = GatewayID(rawValue: "synthetic-gateway")

    private func certificate(_ der: Data) throws -> SecCertificate {
        try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
    }

    func testP256PinMatchesOpensslReference() throws {
        let pin = try XCTUnwrap(SPKIPinExtractor.fingerprint(from: certificate(Self.p256CertificateDER)))
        XCTAssertEqual(pin.base64String, Self.p256SPKIBase64)
    }

    func testRSA2048PinMatchesOpensslReference() throws {
        let pin = try XCTUnwrap(SPKIPinExtractor.fingerprint(from: certificate(Self.rsaCertificateDER)))
        XCTAssertEqual(pin.base64String, Self.rsaSPKIBase64)
    }

    func testVerifierMatchesOnlyTheStoredPin() throws {
        let cert = try certificate(Self.p256CertificateDER)
        let good = try XCTUnwrap(SPKIFingerprint(base64: Self.p256SPKIBase64))
        let other = try XCTUnwrap(SPKIFingerprint(base64: Self.rsaSPKIBase64))

        XCTAssertEqual(
            PinVerifier(gatewayID: gateway, pinStore: FixedPinStore(pins: [gateway: good]))
                .verdict(forCertificate: cert), .matched)
        XCTAssertEqual(
            PinVerifier(gatewayID: gateway, pinStore: FixedPinStore(pins: [gateway: other]))
                .verdict(forCertificate: cert), .mismatch)
    }

    func testVerifierNeverTrustsOnFirstUse() throws {
        let cert = try certificate(Self.p256CertificateDER)
        let verifier = PinVerifier(gatewayID: gateway, pinStore: FixedPinStore(pins: [:]))
        XCTAssertEqual(verifier.verdict(forCertificate: cert), .noPinStored)
    }

    func testVerifierFailsClosedWhenTheStoreThrows() throws {
        struct FailingStore: SynchronousPinStoring {
            func syncSavePin(_ pin: SPKIFingerprint, for gatewayID: GatewayID) throws {}
            func syncLoadPin(for gatewayID: GatewayID) throws -> SPKIFingerprint? {
                throw PinStoreError.unexpectedStatus(-1)
            }
            func syncDeletePin(for gatewayID: GatewayID) throws {}
        }
        let cert = try certificate(Self.p256CertificateDER)
        XCTAssertEqual(
            PinVerifier(gatewayID: gateway, pinStore: FailingStore()).verdict(forCertificate: cert),
            .unavailable)
    }

    func testVerifierReadsThePinFromAServerTrust() throws {
        let cert = try certificate(Self.p256CertificateDER)
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let good = try XCTUnwrap(SPKIFingerprint(base64: Self.p256SPKIBase64))
        let verifier = PinVerifier(gatewayID: gateway, pinStore: FixedPinStore(pins: [gateway: good]))
        XCTAssertEqual(verifier.verdict(forServerTrust: try XCTUnwrap(trust)), .matched)
    }

    func testFixedPinStoreIsReadOnly() throws {
        let store = FixedPinStore(pins: [:])
        let pin = try XCTUnwrap(SPKIFingerprint(base64: Self.p256SPKIBase64))
        XCTAssertThrowsError(try store.syncSavePin(pin, for: gateway))
        XCTAssertThrowsError(try store.syncDeletePin(for: gateway))
        XCTAssertNil(try store.syncLoadPin(for: gateway))
    }
}
