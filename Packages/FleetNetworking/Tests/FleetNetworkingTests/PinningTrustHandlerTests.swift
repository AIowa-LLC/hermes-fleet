import XCTest
import Security
import Foundation
import FleetCore
@testable import FleetNetworking

/// T3 — the URLSession challenge handler applies the TOFU verdict:
/// accept trusts the (self-signed) credential, mismatch REJECTS, first use
/// trusts-and-pins, non-server-trust challenges fall through to default
/// handling. The trust-level decisions drive the `evaluate(serverTrust:)`
/// seam (a synthetic URLProtectionSpace cannot carry a serverTrust; the
/// challenge-extraction path is proven by the live TLS fixture suite).
final class PinningTrustHandlerTests: XCTestCase {

    private let gatewayID = GatewayID(rawValue: "workstation")

    private var gatewayPin: SPKIFingerprint {
        get throws { try XCTUnwrap(SPKIFingerprint(base64: TLSFixtureIdentities.gatewaySPKIBase64)) }
    }

    private func makeTrust(certDER: Data) -> SecTrust {
        let cert = SecCertificateCreateWithData(nil, certDER as CFData)!
        var trust: SecTrust?
        SecTrustCreateWithCertificates(cert, SecPolicyCreateSSL(true, nil), &trust)
        return trust!
    }

    private func evaluate(_ handler: PinningTrustHandler, trust: SecTrust)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        final class Box: @unchecked Sendable {
            var disposition: URLSession.AuthChallengeDisposition = .performDefaultHandling
            var credential: URLCredential?
        }
        let box = Box()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            handler.evaluate(serverTrust: trust) { disposition, credential in
                box.disposition = disposition
                box.credential = credential
                cont.resume()
            }
        }
        return (box.disposition, box.credential)
    }

    func testChallengeWithMatchingPinIsAccepted() async throws {
        let store = InMemoryPinStore()
        try await store.savePin(try gatewayPin, for: gatewayID)
        let handler = PinningTrustHandler(gatewayID: gatewayID, pinStore: store)

        let (disposition, credential) = await evaluate(
            handler,
            trust: makeTrust(certDER: TLSFixtureIdentities.gatewayCertificateDER))

        XCTAssertEqual(disposition, .useCredential, "matching pin must trust the self-signed cert")
        XCTAssertNotNil(credential)
    }

    func testChallengeWithMismatchedPinIsRejected() async throws {
        let store = InMemoryPinStore()
        try await store.savePin(try gatewayPin, for: gatewayID)
        let handler = PinningTrustHandler(gatewayID: gatewayID, pinStore: store)

        let (disposition, _) = await evaluate(
            handler,
            trust: makeTrust(certDER: TLSFixtureIdentities.mitmCertificateDER))

        XCTAssertEqual(disposition, .cancelAuthenticationChallenge,
                       "a different key (MITM) must be REJECTED")
    }

    func testFirstUseTOFUAcceptsSelfSignedAndPins() async throws {
        let store = InMemoryPinStore()
        let handler = PinningTrustHandler(gatewayID: gatewayID, pinStore: store)

        let (disposition, credential) = await evaluate(
            handler,
            trust: makeTrust(certDER: TLSFixtureIdentities.gatewayCertificateDER))

        XCTAssertEqual(disposition, .useCredential, "first use must trust-and-pin")
        XCTAssertNotNil(credential)
        let stored = try await store.loadPin(for: gatewayID)
        XCTAssertEqual(stored?.base64String, TLSFixtureIdentities.gatewaySPKIBase64)
    }

    func testLastVerdictRecordsMismatch() async throws {
        let store = InMemoryPinStore()
        try await store.savePin(try gatewayPin, for: gatewayID)
        let handler = PinningTrustHandler(gatewayID: gatewayID, pinStore: store)

        _ = await evaluate(handler, trust: makeTrust(certDER: TLSFixtureIdentities.mitmCertificateDER))

        guard case .pinMismatch(let expected, let presented) = handler.lastVerdict else {
            return XCTFail("expected pinMismatch verdict, got \(String(describing: handler.lastVerdict))")
        }
        XCTAssertEqual(expected, try gatewayPin)
        XCTAssertEqual(presented.base64String, TLSFixtureIdentities.mitmSPKIBase64)
    }
}
