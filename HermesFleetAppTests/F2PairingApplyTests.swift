import XCTest
import FleetUI
import FleetCore

/// F2 — QR pairing apply tests: one scanned payload fills the whole
/// Add-Gateway draft (endpoint + username/password strategy + credentials),
/// through the same decode + normalization path the camera scanner uses.
@MainActor
final class F2PairingApplyTests: XCTestCase {

    private func makeStoreWithAddDraft() -> GatewayFormDraftStore {
        let store = GatewayFormDraftStore()
        store.begin(pendingSheet: .add, initial: nil)
        return store
    }

    // MARK: Happy path — one scan fills the form

    func testApplyPairingFillsEntireDraft() throws {
        let store = makeStoreWithAddDraft()
        let payload = PairingPayload(
            url: "http://192.168.50.37:8642",
            username: "fleet-operator",
            password: "test-pairing-secret-00000000000000000000000000001"
        )

        try store.applyPairing(payload.encoded())

        XCTAssertEqual(store.displayName, "192.168.50.37", "display name derives from the endpoint host")
        XCTAssertEqual(store.endpointText, "http://192.168.50.37:8642")
        XCTAssertEqual(store.strategy, .usernamePassword)
        XCTAssertEqual(store.usernameText, "fleet-operator")
        XCTAssertEqual(store.passwordText, "test-pairing-secret-00000000000000000000000000001")
        XCTAssertEqual(store.tokenText, "", "token field unused by the pairing strategy")
        XCTAssertFalse(store.confirmsCleartextSend)
        XCTAssertNil(store.saveError)
        XCTAssertEqual(store.pendingSheet, .add, "apply keeps the draft in progress — Save is still explicit")
    }

    func testApplyPairingOverwritesPreviouslyTypedValues() throws {
        let store = makeStoreWithAddDraft()
        store.displayName = "Typed Name"
        store.endpointText = "http://typed.example.com:1"
        store.strategy = .bearerToken
        store.tokenText = "old-token"

        try store.applyPairing(PairingPayload(url: "http://10.0.0.5:8642", username: "u", password: "p").encoded())

        XCTAssertEqual(store.displayName, "10.0.0.5")
        XCTAssertEqual(store.endpointText, "http://10.0.0.5:8642")
        XCTAssertEqual(store.strategy, .usernamePassword)
        XCTAssertEqual(store.tokenText, "", "stale token from a previous strategy must not survive")
        XCTAssertEqual(store.usernameText, "u")
        XCTAssertEqual(store.passwordText, "p")
    }

    // MARK: Endpoint hygiene (P1-6 invariants preserved through pairing)

    func testApplyPairingRejectsUserInfoInEndpoint() {
        let store = makeStoreWithAddDraft()
        // A QR must not smuggle user:pass@host — same rule as typed input.
        let hostile = PairingPayload(url: "http://evil:pass@10.0.0.5:8642", username: "u", password: "p")
        XCTAssertThrowsError(try store.applyPairing(hostile.encoded()))
        XCTAssertEqual(store.endpointText, "", "a rejected scan must not partially fill the form")
        XCTAssertEqual(store.passwordText, "")
    }

    func testApplyPairingStripsQueryAndFragment() throws {
        let store = makeStoreWithAddDraft()
        let payload = PairingPayload(url: "http://10.0.0.5:8642/ws?token=x#frag", username: "u", password: "p")
        try store.applyPairing(payload.encoded())
        XCTAssertEqual(store.endpointText, "http://10.0.0.5:8642/ws", "query/fragment stripped by normalizedOrigin")
    }

    // MARK: Decode failures leave the draft untouched

    func testApplyPairingRejectsNonPairingJSON() {
        let store = makeStoreWithAddDraft()
        store.displayName = "Kept"
        XCTAssertThrowsError(try store.applyPairing("{\"hello\":\"world\"}")) { error in
            XCTAssertEqual(error as? PairingPayload.DecodeError, .notAPairingPayload)
        }
        XCTAssertEqual(store.displayName, "Kept", "a bad scan never clobbers typed state")
    }

    func testApplyPairingRejectsFutureVersion() {
        let store = makeStoreWithAddDraft()
        XCTAssertThrowsError(
            try store.applyPairing("{\"password\":\"p\",\"url\":\"http://h\",\"username\":\"u\",\"v\":2}")
        ) { error in
            XCTAssertEqual(error as? PairingPayload.DecodeError, .unsupportedVersion(2))
        }
    }

    // MARK: Draft lifecycle still holds

    func testClearAfterPairingWipesSecrets() throws {
        let store = makeStoreWithAddDraft()
        try store.applyPairing(PairingPayload(url: "http://10.0.0.5:8642", username: "u", password: "secret").encoded())
        store.clear()
        XCTAssertEqual(store.usernameText, "")
        XCTAssertEqual(store.passwordText, "")
        XCTAssertFalse(store.isInProgress)
    }
}
