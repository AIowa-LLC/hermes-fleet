import XCTest
import Security
import Foundation
import FleetCore
@testable import FleetNetworking

/// T3 — the TOFU trust decision logic: given the presented certificate and
/// the per-gateway pin store, produce a typed verdict.
final class TLSTrustEvaluatorTests: XCTestCase {

    private let gatewayID = GatewayID(rawValue: "workstation")

    private var gatewayPin: SPKIFingerprint {
        get throws {
            try XCTUnwrap(SPKIFingerprint(base64: TLSFixtureIdentities.gatewaySPKIBase64))
        }
    }

    private var mitmPin: SPKIFingerprint {
        get throws {
            try XCTUnwrap(SPKIFingerprint(base64: TLSFixtureIdentities.mitmSPKIBase64))
        }
    }

    private func gatewayCert() throws -> SecCertificate {
        try XCTUnwrap(SecCertificateCreateWithData(
            nil, TLSFixtureIdentities.gatewayCertificateDER as CFData))
    }

    private func mitmCert() throws -> SecCertificate {
        try XCTUnwrap(SecCertificateCreateWithData(
            nil, TLSFixtureIdentities.mitmCertificateDER as CFData))
    }

    func testFirstUseIsTOFUAccept() throws {
        let store = InMemoryPinStore()
        let evaluator = TLSTrustEvaluator(gatewayID: gatewayID, pinStore: store)

        let verdict = evaluator.verdict(forPresentedCertificate: try gatewayCert())

        XCTAssertEqual(verdict, .tofuAccept(try gatewayPin))
    }

    func testTOFUAcceptWritesThePin() async throws {
        let store = InMemoryPinStore()
        let evaluator = TLSTrustEvaluator(gatewayID: gatewayID, pinStore: store)

        _ = evaluator.verdict(forPresentedCertificate: try gatewayCert())

        let stored = try await store.loadPin(for: gatewayID)
        XCTAssertEqual(stored?.base64String, TLSFixtureIdentities.gatewaySPKIBase64)
    }

    func testPinnedCertificateMatchesOnReconnect() async throws {
        let store = InMemoryPinStore()
        try await store.savePin(try gatewayPin, for: gatewayID)
        let evaluator = TLSTrustEvaluator(gatewayID: gatewayID, pinStore: store)

        let verdict = evaluator.verdict(forPresentedCertificate: try gatewayCert())

        XCTAssertEqual(verdict, .pinMatched(try gatewayPin))
    }

    func testDifferentCertificateIsPinMismatch() async throws {
        let store = InMemoryPinStore()
        try await store.savePin(try gatewayPin, for: gatewayID)
        let evaluator = TLSTrustEvaluator(gatewayID: gatewayID, pinStore: store)

        let verdict = evaluator.verdict(forPresentedCertificate: try mitmCert())

        XCTAssertEqual(verdict, .pinMismatch(expected: try gatewayPin, presented: try mitmPin))
    }

    func testPinStoreFailureFailsClosed() throws {
        // A keychain read failure must REJECT, never fall through to accept
        // (fail closed — an unavailable pin store is not "no pin").
        let store = FailingPinStore()
        let evaluator = TLSTrustEvaluator(gatewayID: gatewayID, pinStore: store)

        let verdict = evaluator.verdict(forPresentedCertificate: try gatewayCert())

        guard case .internalError = verdict else {
            return XCTFail("expected internalError (fail closed), got \(verdict)")
        }
    }

    func testUnextractableKeyFailsClosed() throws {
        let store = InMemoryPinStore()
        let evaluator = TLSTrustEvaluator(gatewayID: gatewayID, pinStore: store)
        // A certificate with an unsupported key type (RSA-1024) — the SPKI
        // extractor must fail closed rather than pin a weak key.
        let badCert = try XCTUnwrap(SecCertificateCreateWithData(
            nil, TLSFixtureIdentities.weakCertificateDER as CFData))
        guard case .internalError = evaluator.verdict(forPresentedCertificate: badCert) else {
            return XCTFail("expected internalError for unsupported key type")
        }
    }

    // A store whose load ALWAYS fails (keychain unavailable).
    private struct FailingPinStore: SynchronousPinStoring {
        func syncSavePin(_ pin: SPKIFingerprint, for gatewayID: GatewayID) throws {
            throw PinStoreError.unexpectedStatus(-25291)
        }
        func syncLoadPin(for gatewayID: GatewayID) throws -> SPKIFingerprint? {
            throw PinStoreError.unexpectedStatus(-25291)
        }
        func syncDeletePin(for gatewayID: GatewayID) throws {
            throw PinStoreError.unexpectedStatus(-25291)
        }
    }
}
