import XCTest
import Security
import FleetCore
@testable import FleetSecurity

/// M7 Keychain credential storage: the "Keychain safe" acceptance (spec §16,
/// §27, §31 Security "no secret values appear in application logs").
///
/// The in-memory store exercises the `CredentialStoring` contract; the
/// Keychain store's *query construction* is asserted without touching a live
/// keychain (account/service/accessibility/no-sync), so CI stays hermetic.
final class FleetSecurityKeychainTests: XCTestCase {

    private let gatewayID = GatewayID(rawValue: "workstation")

    // MARK: InMemoryCredentialStore — contract semantics

    func testInMemoryStoreSaveLoadDelete() async throws {
        let store = InMemoryCredentialStore()
        try await store.saveCredential(GatewayCredential(rawValue: "token-1"), for: gatewayID)

        let loaded = try await store.loadCredential(for: gatewayID)
        XCTAssertEqual(loaded, GatewayCredential(rawValue: "token-1"))

        try await store.deleteCredential(for: gatewayID)
        let afterDelete = try await store.loadCredential(for: gatewayID)
        XCTAssertNil(afterDelete, "deleted credential is gone")
    }

    func testInMemoryStoreMissingIsNilAndDeleteIsNoOp() async throws {
        let store = InMemoryCredentialStore()
        let missing = try await store.loadCredential(for: gatewayID)
        XCTAssertNil(missing)
        // Deleting a missing credential is a no-op, not an error.
        try await store.deleteCredential(for: gatewayID)
    }

    func testInMemoryStoreUpsertOverwrites() async throws {
        let store = InMemoryCredentialStore()
        try await store.saveCredential(GatewayCredential(rawValue: "first"), for: gatewayID)
        try await store.saveCredential(GatewayCredential(rawValue: "second"), for: gatewayID)
        let loaded = try await store.loadCredential(for: gatewayID)
        XCTAssertEqual(loaded?.rawValue, "second")
    }

    // MARK: username/password composite (P3 LAN-gateway fix, t_eb5455f2)

    func testUsernamePasswordCompositeRoundTripsThroughStore() async throws {
        // The .usernamePassword strategy stores BOTH halves as one Keychain
        // item: username + password must round-trip through the same
        // CredentialStoring seam the UI writes.
        let store = InMemoryCredentialStore()
        try await store.saveCredential(
            GatewayCredential(rawValue: "pw-123", username: "tony"),
            for: gatewayID)

        let loaded = try await store.loadCredential(for: gatewayID)
        XCTAssertEqual(loaded?.username, "tony", "username half preserved")
        XCTAssertEqual(loaded?.rawValue, "pw-123", "password half preserved")
        XCTAssertEqual(loaded, GatewayCredential(rawValue: "pw-123", username: "tony"))
    }

    func testTokenOnlyCredentialStillRoundTrips() async throws {
        // Legacy token-only shape must be unchanged by the composite encoding.
        let store = InMemoryCredentialStore()
        try await store.saveCredential(GatewayCredential(rawValue: "tok-1"), for: gatewayID)
        let loaded = try await store.loadCredential(for: gatewayID)
        XCTAssertEqual(loaded, GatewayCredential(rawValue: "tok-1"))
        XCTAssertNil(loaded?.username)
    }

    func testCredentialEncodingBackwardCompat() throws {
        // Bytes written as a legacy raw token (no composite prefix) decode as
        // a token-only credential — previously-stored Keychain items survive.
        let legacy = Data("legacy-token".utf8)
        let decoded = try CredentialEncoding.decode(legacy)
        XCTAssertEqual(decoded, GatewayCredential(rawValue: "legacy-token"))
        XCTAssertNil(decoded.username)
    }

    func testCredentialEncodingCompositeDoesNotLeakPrefixBytes() throws {
        // Round-trip through the versioned encoding; the raw value stored is
        // the composite (username + password), never just the password.
        let credential = GatewayCredential(rawValue: "pw", username: "u")
        let encoded = CredentialEncoding.encode(credential)
        XCTAssertNotEqual(encoded, Data("pw".utf8), "password alone must not be stored")
        let decoded = try CredentialEncoding.decode(encoded)
        XCTAssertEqual(decoded, credential)
    }

    func testInMemoryStoreIsolationPerGateway() async throws {
        let store = InMemoryCredentialStore()
        let other = GatewayID(rawValue: "render-box")
        try await store.saveCredential(GatewayCredential(rawValue: "token-m5"), for: gatewayID)
        let otherCredential = try await store.loadCredential(for: other)
        XCTAssertNil(otherCredential, "gateways do not share credentials")
    }

    // MARK: KeychainCredentialStore — query construction (hermetic, no live keychain)

    func testKeychainAttributesAreGenericPassword() {
        let attributes = KeychainCredentialStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }

    func testKeychainServiceNameScopedToApp() {
        let attributes = KeychainCredentialStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(
            attributes[kSecAttrService as String] as? String,
            "com.aiowa.hermesfleet.gateway-credentials")
    }

    func testKeychainAccountIsGatewayID() {
        let attributes = KeychainCredentialStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "workstation")
    }

    func testKeychainAccessibilityWhenUnlockedThisDeviceOnly() {
        // synthesis §12: accessibility WhenUnlockedThisDeviceOnly, no iCloud
        // sync, no backup migration. Assert the exact constant is used.
        let attributes = KeychainCredentialStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testKeychainSynchronizableDisabled() {
        // No iCloud Keychain sync for gateway credentials (synthesis §12).
        let attributes = KeychainCredentialStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testKeychainStoreConstructible() async {
        // Construction is side-effect free; the store is Sendable.
        let store = KeychainCredentialStore()
        let _: any CredentialStoring = store
    }
}
