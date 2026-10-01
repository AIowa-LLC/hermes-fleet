import XCTest
import Security
import FleetCore
@testable import FleetSecurity

/// Keychain OAuth token store: query construction is hermetic (no live
/// keychain). Contract tests use an in-memory KeychainSession double.
final class KeychainOAuthTokenStoreTests: XCTestCase {

    private let gatewayID = GatewayID(rawValue: "workstation")

    func testKeychainOAuthAttributesAreGenericPassword() {
        let attributes = KeychainOAuthTokenStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }

    func testKeychainOAuthServiceNameIsScoped() {
        let attributes = KeychainOAuthTokenStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(
            attributes[kSecAttrService as String] as? String,
            "com.aiowa.hermesfleet.oauth-tokens")
    }

    func testKeychainOAuthAccountIsGatewayID() {
        let attributes = KeychainOAuthTokenStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "workstation")
    }

    func testKeychainOAuthAccessibilityWhenUnlockedThisDeviceOnly() {
        let attributes = KeychainOAuthTokenStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testInMemoryOAuthStoreSaveLoadDelete() async throws {
        let store = InMemoryOAuthTokenStore()
        let pair = OAuthTokenPair(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            provider: "nous",
            userId: "user"
        )
        try await store.saveTokenPair(pair, for: gatewayID)
        let loaded = try await store.loadTokenPair(for: gatewayID)
        XCTAssertEqual(loaded?.accessToken, "access-1")
        XCTAssertEqual(loaded?.refreshToken, "refresh-1")
        XCTAssertEqual(loaded?.provider, "nous")
        XCTAssertEqual(loaded?.description, "[REDACTED]")

        try await store.deleteTokenPair(for: gatewayID)
        let afterDelete = try await store.loadTokenPair(for: gatewayID)
        XCTAssertNil(afterDelete)
    }

    func testInMemoryOAuthStoreMissingIsNilAndDeleteIsNoOp() async throws {
        let store = InMemoryOAuthTokenStore()
        let missing = try await store.loadTokenPair(for: gatewayID)
        XCTAssertNil(missing)
        try await store.deleteTokenPair(for: gatewayID)
    }

    func testInMemoryOAuthStoreUpsertOverwrites() async throws {
        let store = InMemoryOAuthTokenStore()
        try await store.saveTokenPair(
            OAuthTokenPair(accessToken: "a1", refreshToken: "r1", expiresAt: 1, provider: "nous", userId: "u"),
            for: gatewayID
        )
        try await store.saveTokenPair(
            OAuthTokenPair(accessToken: "a2", refreshToken: "r2", expiresAt: 2, provider: "google", userId: "v"),
            for: gatewayID
        )
        let loaded = try await store.loadTokenPair(for: gatewayID)
        XCTAssertEqual(loaded?.accessToken, "a2")
        XCTAssertEqual(loaded?.provider, "google")
    }

    func testMockKeychainSessionSaveLoadDelete() async throws {
        let store = KeychainOAuthTokenStore(keychain: MockOAuthKeychainSession())
        let pair = OAuthTokenPair(
            accessToken: "access_token_123",
            refreshToken: "refresh_token_456",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            provider: "nous",
            userId: "user123"
        )
        try await store.saveTokenPair(pair, for: gatewayID)
        let loaded = try await store.loadTokenPair(for: gatewayID)
        XCTAssertEqual(loaded?.accessToken, pair.accessToken)
        XCTAssertEqual(loaded?.refreshToken, pair.refreshToken)
        XCTAssertEqual(loaded?.provider, pair.provider)
        XCTAssertEqual(loaded?.userId, pair.userId)

        try await store.deleteTokenPair(for: gatewayID)
        let missing = try await store.loadTokenPair(for: gatewayID)
        XCTAssertNil(missing)
    }
}

private final class MockOAuthKeychainSession: KeychainSession, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    func add(_ query: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let dict = query as NSDictionary
        guard let account = dict[kSecAttrAccount] as? String,
              let data = dict[kSecValueData] as? Data else {
            return errSecParam
        }
        if storage[account] != nil { return errSecDuplicateItem }
        storage[account] = data
        return errSecSuccess
    }

    func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let dict = query as NSDictionary
        let attrs = attributesToUpdate as NSDictionary
        guard let account = dict[kSecAttrAccount] as? String,
              let data = attrs[kSecValueData] as? Data else {
            return errSecParam
        }
        guard storage[account] != nil else { return errSecItemNotFound }
        storage[account] = data
        return errSecSuccess
    }

    func copyMatching(_ query: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let dict = query as NSDictionary
        guard let account = dict[kSecAttrAccount] as? String,
              let data = storage[account] else {
            return errSecItemNotFound
        }
        result = data as CFTypeRef
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let dict = query as NSDictionary
        guard let account = dict[kSecAttrAccount] as? String else {
            return errSecParam
        }
        storage.removeValue(forKey: account)
        return errSecSuccess
    }
}
