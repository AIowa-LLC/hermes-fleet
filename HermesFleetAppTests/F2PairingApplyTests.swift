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
            url: "https://gateway.example.invalid:8642",
            username: "fixture-user",
            password: "NOT-A-CREDENTIAL"
        )

        try store.applyPairing(payload.encoded())

        XCTAssertEqual(store.displayName, "gateway.example.invalid", "display name derives from the endpoint host")
        XCTAssertEqual(store.endpointText, "https://gateway.example.invalid:8642")
        XCTAssertEqual(store.strategy, .usernamePassword)
        XCTAssertEqual(store.usernameText, "fixture-user")
        XCTAssertEqual(store.passwordText, "NOT-A-CREDENTIAL")
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

        try store.applyPairing(PairingPayload(url: "https://gateway.example.invalid:8642", username: "u", password: "p").encoded())

        XCTAssertEqual(store.displayName, "gateway.example.invalid")
        XCTAssertEqual(store.endpointText, "https://gateway.example.invalid:8642")
        XCTAssertEqual(store.strategy, .usernamePassword)
        XCTAssertEqual(store.tokenText, "", "stale token from a previous strategy must not survive")
        XCTAssertEqual(store.usernameText, "u")
        XCTAssertEqual(store.passwordText, "p")
    }

    // MARK: Endpoint hygiene (P1-6 invariants preserved through pairing)

    func testApplyPairingRejectsUserInfoInEndpoint() {
        let store = makeStoreWithAddDraft()
        // A QR must not smuggle user:pass@host — same rule as typed input.
        let hostile = PairingPayload(url: "http://evil:pass@gateway.example.invalid:8642", username: "u", password: "p")
        XCTAssertThrowsError(try store.applyPairing(hostile.encoded()))
        XCTAssertEqual(store.endpointText, "", "a rejected scan must not partially fill the form")
        XCTAssertEqual(store.passwordText, "")
    }

    func testApplyPairingStripsQueryAndFragment() throws {
        let store = makeStoreWithAddDraft()
        let payload = PairingPayload(url: "https://gateway.example.invalid:8642/ws?token=x#frag", username: "u", password: "p")
        try store.applyPairing(payload.encoded())
        XCTAssertEqual(store.endpointText, "https://gateway.example.invalid:8642/ws", "query/fragment stripped by normalizedOrigin")
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

    // MARK: Advanced scanner routing (#213)

    /// Synthetic invitation link in the shape `hermes fleet pair` issues.
    private let invitationLink = "https://gateway.example.invalid/pair#v=1&i=AbCdEfGhIjKlMnOpQrStUv&s=0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"

    func testAdvancedScanRoutesInvitationLinkToPairingNotJSON() throws {
        XCTAssertNoThrow(try PairingInvitationLink.parse(invitationLink))
        XCTAssertEqual(AdvancedScanRouting.route(invitationLink), .invitation)
        XCTAssertEqual(AdvancedScanRouting.route("\n  \(invitationLink)  \n"), .invitation,
                       "surrounding whitespace from a scan is tolerated")
    }

    func testAdvancedScanRoutesV1JSONToLegacyDecodeAndStillFillsDraft() throws {
        let json = PairingPayload(
            url: "https://gateway.example.invalid:8642",
            username: "fixture-user",
            password: "NOT-A-CREDENTIAL"
        ).encoded()
        XCTAssertEqual(AdvancedScanRouting.route(json), .legacyPairingJSON)

        let store = makeStoreWithAddDraft()
        try store.applyPairing(json)
        XCTAssertEqual(store.endpointText, "https://gateway.example.invalid:8642")
        XCTAssertEqual(store.usernameText, "fixture-user")
        XCTAssertEqual(store.passwordText, "NOT-A-CREDENTIAL")
    }

    func testAdvancedScanRejectsUnrelatedTextAsLegacyJSON() {
        XCTAssertEqual(AdvancedScanRouting.route("not a code"), .legacyPairingJSON)
        XCTAssertEqual(AdvancedScanRouting.route("{\"hello\":\"https://gateway.example.invalid/pair\"}"),
                       .legacyPairingJSON, "JSON never takes the invitation route")
    }

    // MARK: Draft lifecycle still holds

    func testClearAfterPairingWipesSecrets() throws {
        let store = makeStoreWithAddDraft()
        try store.applyPairing(PairingPayload(url: "https://gateway.example.invalid:8642", username: "u", password: "secret").encoded())
        store.clear()
        XCTAssertEqual(store.usernameText, "")
        XCTAssertEqual(store.passwordText, "")
        XCTAssertFalse(store.isInProgress)
    }
}
