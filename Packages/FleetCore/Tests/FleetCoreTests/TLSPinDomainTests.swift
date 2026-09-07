import XCTest
import Foundation
@testable import FleetCore

/// T3 TLS TOFU pinning — the `SPKIFingerprint` value type and the
/// `TLSPinStoring` seam (per-gateway expected SPKI pin, Keychain-backed in
/// production, in-memory in tests).
final class TLSPinDomainTests: XCTestCase {

    private let gatewayID = GatewayID(rawValue: "workstation")
    private let otherGateway = GatewayID(rawValue: "node-a")

    // MARK: SPKIFingerprint value type

    func testFingerprintRoundTripsThroughBase64() {
        let raw = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        guard let pin = SPKIFingerprint(sha256Digest: raw) else {
            return XCTFail("32-byte digest must initialize")
        }
        XCTAssertEqual(pin.sha256Digest, raw)
        XCTAssertEqual(SPKIFingerprint(base64: pin.base64String), pin)
    }

    func testFingerprintFromRawBytesMatchesDigestInit() {
        let raw: [UInt8] = Array(UInt8(0)...UInt8(31))
        let pin = SPKIFingerprint(rawBytes: raw)
        XCTAssertEqual(pin.sha256Digest, Data(raw))
    }

    func testFingerprintEqualityAndHashing() {
        let a = SPKIFingerprint(base64: "0sshb6QBdnSVmS4d7pNB5MC4rowmN+JUeF0KQS/kpOk=")
        let b = SPKIFingerprint(base64: "0sshb6QBdnSVmS4d7pNB5MC4rowmN+JUeF0KQS/kpOk=")
        let c = SPKIFingerprint(base64: "85yFqwhKWLa3bnAIOCtS/8bmZ4pznYYnPPp7l9MD65o=")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(Set([a, b, c]).count, 2)
    }

    func testFingerprintDescriptionIsNotSecretButIdentifying() {
        // The SPKI pin is public key material (not a secret) — it must print
        // stably for logs/UI, and never be redacted away to uselessness.
        guard let pin = SPKIFingerprint(base64: "0sshb6QBdnSVmS4d7pNB5MC4rowmN+JUeF0KQS/kpOk=") else {
            return XCTFail("valid fixture pin must initialize")
        }
        XCTAssertTrue(pin.description.contains("0sshb6QB"), "description should include the pin prefix for identification")
    }

    func testInvalidBase64ProducesNil() {
        XCTAssertNil(SPKIFingerprint(base64: "not!!valid~~base64==="))
        XCTAssertNil(SPKIFingerprint(base64: ""))
    }

    // MARK: InMemoryPinStore (the seam contract double)

    func testInMemoryPinStoreSaveLoadDeleteRoundTrip() async throws {
        let store = InMemoryPinStore()
        guard let pin = SPKIFingerprint(base64: "0sshb6QBdnSVmS4d7pNB5MC4rowmN+JUeF0KQS/kpOk=") else {
            return XCTFail("valid fixture pin must initialize")
        }

        // TOFU: no pin stored yet → nil (first use)
        let first = try await store.loadPin(for: gatewayID)
        XCTAssertNil(first)

        // First use pins it
        try await store.savePin(pin, for: gatewayID)
        let loaded = try await store.loadPin(for: gatewayID)
        XCTAssertEqual(loaded, pin)

        // Pins are per-gateway (the Arch gateway is unpinned)
        let other = try await store.loadPin(for: otherGateway)
        XCTAssertNil(other)

        // Delete (gateway removal) — missing is a no-op
        try await store.deletePin(for: gatewayID)
        let afterDelete = try await store.loadPin(for: gatewayID)
        XCTAssertNil(afterDelete)
        try await store.deletePin(for: gatewayID) // no throw
    }

    func testInMemoryPinStoreUpsertReplaces() async throws {
        let store = InMemoryPinStore()
        guard let first = SPKIFingerprint(base64: "0sshb6QBdnSVmS4d7pNB5MC4rowmN+JUeF0KQS/kpOk="),
              let replacement = SPKIFingerprint(base64: "85yFqwhKWLa3bnAIOCtS/8bmZ4pznYYnPPp7l9MD65o=") else {
            return XCTFail("valid fixture pins must initialize")
        }
        try await store.savePin(first, for: gatewayID)
        try await store.savePin(replacement, for: gatewayID)
        let loaded = try await store.loadPin(for: gatewayID)
        XCTAssertEqual(loaded, replacement,
                       "an accepted pin change replaces the stored pin")
    }
}
