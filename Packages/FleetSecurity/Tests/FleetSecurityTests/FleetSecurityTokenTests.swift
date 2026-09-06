import XCTest
import Security
import FleetCore
@testable import FleetSecurity

/// M10 Keychain token/ticket store: the "tokens/tickets live only in Keychain"
/// acceptance (spec §16, §27, §31 Security; synthesis §12: GenericPassword,
/// per-peer, accessibility WhenUnlockedThisDeviceOnly, no iCloud sync).
///
/// The in-memory store exercises the `TokenStoring` contract; the Keychain
/// store's query construction is asserted without touching a live keychain
/// (account/service/accessibility/no-sync), so CI stays hermetic.
final class FleetSecurityTokenTests: XCTestCase {

    private let gatewayID = GatewayID(rawValue: "workstation")

    // MARK: InMemoryTokenStore — contract semantics

    func testInMemoryTokenStoreSaveLoadDelete() async throws {
        let store = InMemoryTokenStore()
        try await store.saveToken(StoredToken(rawValue: "ticket-1"), for: gatewayID)

        let loaded = try await store.loadToken(for: gatewayID)
        XCTAssertEqual(loaded, StoredToken(rawValue: "ticket-1"))
        XCTAssertEqual(loaded?.description, "[REDACTED]", "token never prints")

        try await store.deleteToken(for: gatewayID)
        let afterDelete = try await store.loadToken(for: gatewayID)
        XCTAssertNil(afterDelete, "deleted token is gone")
    }

    func testInMemoryTokenStoreMissingIsNilAndDeleteIsNoOp() async throws {
        let store = InMemoryTokenStore()
        let missing = try await store.loadToken(for: gatewayID)
        XCTAssertNil(missing)
        // Deleting a missing token is a no-op, not an error.
        try await store.deleteToken(for: gatewayID)
    }

    func testInMemoryTokenStoreUpsertOverwrites() async throws {
        let store = InMemoryTokenStore()
        try await store.saveToken(StoredToken(rawValue: "first"), for: gatewayID)
        try await store.saveToken(StoredToken(rawValue: "second"), for: gatewayID)
        let loaded = try await store.loadToken(for: gatewayID)
        XCTAssertEqual(loaded?.rawValue, "second")
    }

    func testInMemoryTokenStoreIsolationPerPeer() async throws {
        let store = InMemoryTokenStore()
        let other = GatewayID(rawValue: "render-box")
        try await store.saveToken(StoredToken(rawValue: "ticket-m5"), for: gatewayID)
        let otherToken = try await store.loadToken(for: other)
        XCTAssertNil(otherToken, "peers do not share tokens")
    }

    // MARK: KeychainTokenStore — query construction (hermetic, no live keychain)

    func testKeychainTokenAttributesAreGenericPassword() {
        let attributes = KeychainTokenStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }

    func testKeychainTokenServiceNameScopedToAppTokens() {
        let attributes = KeychainTokenStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(
            attributes[kSecAttrService as String] as? String,
            "com.aiowa.hermesfleet.tokens")
    }

    func testKeychainTokenAccountIsPeerGatewayID() {
        let attributes = KeychainTokenStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "workstation")
    }

    func testKeychainTokenAccessibilityWhenUnlockedThisDeviceOnly() {
        // synthesis §12: tokens/tickets are WhenUnlockedThisDeviceOnly, no
        // iCloud sync, no backup migration. Assert the exact constant is used.
        let attributes = KeychainTokenStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testKeychainTokenSynchronizableDisabled() {
        let attributes = KeychainTokenStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testKeychainTokenStoreConstructible() async {
        // Construction is side-effect free; the store is Sendable.
        let store = KeychainTokenStore()
        let _: any TokenStoring = store
    }
}
