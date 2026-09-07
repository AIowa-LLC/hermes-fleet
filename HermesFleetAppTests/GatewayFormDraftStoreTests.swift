import XCTest
import FleetUI
import FleetCore

/// P0-2 — `GatewayFormDraftStore` tests: the in-memory draft that lets the
/// Add/Edit-Gateway form survive the H1 biometric lock / scenePhase teardown.
///
/// The store is the single source of truth for the form's field state while
/// the sheet is open, so the acceptance hinges on: a draft starts in-progress
/// on `begin`, holds every typed field, survives `clear()` semantics (wiped
/// only on intentional Cancel / successful Save), and never persists anywhere
/// (plain in-memory object, no storage seam).
@MainActor
final class GatewayFormDraftStoreTests: XCTestCase {

    // MARK: - begin / isInProgress

    func testBeginAddStartsInProgressWithEmptyFields() {
        let store = GatewayFormDraftStore()
        XCTAssertFalse(store.isInProgress, "fresh store has no draft")

        store.begin(pendingSheet: .add, initial: nil)

        XCTAssertTrue(store.isInProgress)
        XCTAssertEqual(store.pendingSheet, .add)
        XCTAssertEqual(store.displayName, "")
        XCTAssertEqual(store.endpointText, "")
        XCTAssertEqual(store.strategy, .none)
        // Secrets always start empty — never prefilled.
        XCTAssertEqual(store.tokenText, "")
        XCTAssertEqual(store.usernameText, "")
        XCTAssertEqual(store.passwordText, "")
    }

    func testBeginEditSeedsNonSecretFieldsFromGateway() throws {
        let store = GatewayFormDraftStore()
        let gateway = FleetGateway(
            id: GatewayID(rawValue: "workstation"),
            displayName: "Workstation",
            endpoint: URL(string: "http://192.168.1.50:8642"),
            authConfiguration: GatewayAuthConfiguration(strategy: .usernamePassword, credentialStored: true)
        )

        store.begin(pendingSheet: .edit(gateway.id), initial: gateway)

        XCTAssertTrue(store.isInProgress)
        XCTAssertEqual(store.pendingSheet, .edit(GatewayID(rawValue: "workstation")))
        XCTAssertEqual(store.displayName, "Workstation")
        XCTAssertEqual(store.endpointText, "http://192.168.1.50:8642")
        XCTAssertEqual(store.strategy, .usernamePassword)
        // Secrets are never prefilled from the stored gateway.
        XCTAssertEqual(store.passwordText, "")
        XCTAssertEqual(store.usernameText, "")
    }

    // MARK: - Draft holds typed fields while the sheet is open

    func testDraftHoldsTypedFieldsWhileInProgress() {
        let store = GatewayFormDraftStore()
        store.begin(pendingSheet: .add, initial: nil)

        store.displayName = "Tailnet Gateway"
        store.endpointText = "http://100.100.200.61:8642"
        store.strategy = .sessionToken
        store.tokenText = "long-generated-session-token-42chars..."
        store.saveError = "connection failed"

        // The exact scenario the user hit in dogfood: background mid-form,
        // FaceID re-locks, view teardown — the ROOT-OWNED store still holds
        // every field so the re-presented sheet restores them.
        XCTAssertEqual(store.displayName, "Tailnet Gateway")
        XCTAssertEqual(store.endpointText, "http://100.100.200.61:8642")
        XCTAssertEqual(store.strategy, .sessionToken)
        XCTAssertEqual(store.tokenText, "long-generated-session-token-42chars...")
        XCTAssertEqual(store.saveError, "connection failed")
        XCTAssertTrue(store.isInProgress)
    }

    // MARK: - clear() wipes everything (Cancel / successful Save)

    func testClearWipesDraftIncludingSecrets() {
        let store = GatewayFormDraftStore()
        store.begin(pendingSheet: .add, initial: nil)
        store.displayName = "Render Box"
        store.endpointText = "http://192.168.1.77:8642"
        store.strategy = .usernamePassword
        store.usernameText = "fleetuser"
        store.passwordText = "supersecret-password-42chars..."
        store.confirmsCleartextSend = true
        store.saveError = "boom"

        store.clear()

        XCTAssertFalse(store.isInProgress, "clear() ends the draft (Cancel / Save)")
        XCTAssertNil(store.pendingSheet)
        XCTAssertEqual(store.displayName, "")
        XCTAssertEqual(store.endpointText, "")
        XCTAssertEqual(store.strategy, .none)
        XCTAssertEqual(store.tokenText, "")
        XCTAssertEqual(store.usernameText, "")
        XCTAssertEqual(store.passwordText, "", "secret must not linger after clear")
        XCTAssertFalse(store.confirmsCleartextSend)
        XCTAssertNil(store.saveError)
    }

    // MARK: - begin() re-seeds an already-cleared draft (fresh form)

    func testBeginAfterClearStartsFresh() {
        let store = GatewayFormDraftStore()
        store.begin(pendingSheet: .add, initial: nil)
        store.displayName = "Old"
        store.clear()

        // Second form session must NOT resurrect the previous draft.
        store.begin(pendingSheet: .add, initial: nil)
        XCTAssertEqual(store.displayName, "", "new session starts clean")
        XCTAssertTrue(store.isInProgress)
    }
}
