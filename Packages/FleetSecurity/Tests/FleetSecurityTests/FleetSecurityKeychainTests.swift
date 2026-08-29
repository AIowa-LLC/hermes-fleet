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

    private let gatewayID = GatewayID(rawValue: "<dev-workstation>")

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

    func testInMemoryStoreIsolationPerGateway() async throws {
        let store = InMemoryCredentialStore()
        let other = GatewayID(rawValue: "gaming-4090")
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
            "<legacy-personal-bundle-id>.gateway-credentials")
    }

    func testKeychainAccountIsGatewayID() {
        let attributes = KeychainCredentialStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "<dev-workstation>")
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
