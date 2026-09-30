import XCTest
import Security
import FleetCore
@testable import FleetSecurity

/// Recording in-memory `KeychainSession`: keeps the last query for every call so
/// tests can assert exactly which Keychain attributes were sent, with no live
/// keychain (CI stays hermetic).
private final class RecordingKeychainSession: KeychainSession, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private(set) var queries: [[String: Any]] = []
    var forcedStatus: OSStatus?

    private func key(_ query: CFDictionary) -> String {
        let dict = query as? [String: Any] ?? [:]
        return "\(dict[kSecAttrService as String] ?? "")|\(dict[kSecAttrAccount as String] ?? "")"
    }

    private func record(_ query: CFDictionary) {
        queries.append(query as? [String: Any] ?? [:])
    }

    func add(_ query: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        record(query)
        if let forcedStatus { return forcedStatus }
        let dict = query as? [String: Any] ?? [:]
        items[key(query)] = dict[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        record(query)
        if let forcedStatus { return forcedStatus }
        guard items[key(query)] != nil else { return errSecItemNotFound }
        let update = attributesToUpdate as? [String: Any] ?? [:]
        items[key(query)] = update[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        record(query)
        if let forcedStatus { return forcedStatus }
        return items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
    }

    func copyMatching(_ query: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        record(query)
        if let forcedStatus { return forcedStatus }
        guard let data = items[key(query)] else { return errSecItemNotFound }
        result = data as CFData
        return errSecSuccess
    }
}

/// F3: the shared keychain group holds the push key ONLY, with
/// `AfterFirstUnlockThisDeviceOnly`; every gateway-secret store stays app-private.
final class FleetSharedKeychainTests: XCTestCase {

    private let syntheticGroup = "TESTPREFIX.com.example.shared"
    private let syntheticKey = Data((0..<32).map { UInt8($0) })

    // MARK: shared push-key store

    func testPushKeyRoundTripsWithAccessGroupAndAfterFirstUnlockAttributes() throws {
        let session = RecordingKeychainSession()
        let store = FleetSharedKeychain(accessGroup: syntheticGroup, keychain: session)

        XCTAssertNil(try store.load(item: .pushPrivateKey), "nothing stored yet")
        try store.save(syntheticKey, item: .pushPrivateKey)
        XCTAssertEqual(try store.load(item: .pushPrivateKey), syntheticKey)

        // Upsert replaces in place.
        let rotated = Data(repeating: 0x7F, count: 32)
        try store.save(rotated, item: .pushPrivateKey)
        XCTAssertEqual(try store.load(item: .pushPrivateKey), rotated)

        try store.delete(item: .pushPrivateKey)
        XCTAssertNil(try store.load(item: .pushPrivateKey))
        // Deleting a missing item is a no-op.
        XCTAssertNoThrow(try store.delete(item: .pushPrivateKey))

        XCTAssertFalse(session.queries.isEmpty)
        for query in session.queries {
            XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, syntheticGroup,
                           "every shared query must carry the access group")
            XCTAssertEqual(query[kSecAttrAccessible as String] as? String,
                           kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(query[kSecAttrService as String] as? String,
                           FleetSharedKeychain.serviceName)
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "push-private-key")
        }
    }

    func testFallbackWithoutAccessGroupOmitsGroupButKeepsAccessibility() throws {
        let session = RecordingKeychainSession()
        let store = FleetSharedKeychain(accessGroup: nil, keychain: session)
        try store.save(syntheticKey, item: .pushPrivateKey)
        XCTAssertEqual(try store.load(item: .pushPrivateKey), syntheticKey)
        for query in session.queries {
            XCTAssertNil(query[kSecAttrAccessGroup as String],
                         "nil access group = app-private fallback, no group attribute")
            XCTAssertEqual(query[kSecAttrAccessible as String] as? String,
                           kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        }
    }

    func testOnlyThePushKeyCanBeStoredInTheSharedGroup() {
        XCTAssertEqual(FleetSharedKeychainItem.allCases, [.pushPrivateKey],
                       "the shared group is push-key only; adding an item is a security decision")
        // The shared service namespace is distinct from every app-private store.
        let privateServices: Set<String> = [
            KeychainCredentialStore.serviceName,
            KeychainTokenStore.serviceName,
            KeychainPinStore.serviceName,
        ]
        XCTAssertFalse(privateServices.contains(FleetSharedKeychain.serviceName))
    }

    func testMissingEntitlementIsATypedError() {
        let session = RecordingKeychainSession()
        session.forcedStatus = errSecMissingEntitlement
        let store = FleetSharedKeychain(accessGroup: syntheticGroup, keychain: session)
        XCTAssertThrowsError(try store.save(syntheticKey, item: .pushPrivateKey)) {
            XCTAssertEqual($0 as? FleetSharedKeychainError, .missingEntitlement)
        }
        XCTAssertThrowsError(try store.load(item: .pushPrivateKey)) {
            XCTAssertEqual($0 as? FleetSharedKeychainError, .missingEntitlement)
        }
    }

    func testOtherFailuresCarryOnlyTheNumericStatus() {
        let session = RecordingKeychainSession()
        session.forcedStatus = errSecInteractionNotAllowed
        let store = FleetSharedKeychain(accessGroup: syntheticGroup, keychain: session)
        XCTAssertThrowsError(try store.save(syntheticKey, item: .pushPrivateKey)) { error in
            XCTAssertEqual(error as? FleetSharedKeychainError,
                           .unexpectedStatus(Int(errSecInteractionNotAllowed)))
            XCTAssertFalse("\(error)".contains(syntheticGroup))
        }
    }

    func testEmptyAccessGroupIsRejectedRatherThanTreatedAsNone() {
        let store = FleetSharedKeychain(accessGroup: "", keychain: RecordingKeychainSession())
        XCTAssertThrowsError(try store.save(syntheticKey, item: .pushPrivateKey)) {
            XCTAssertEqual($0 as? FleetSharedKeychainError, .invalidAccessGroup)
        }
    }

    // MARK: existing stores stay app-private

    func testExistingStoresNeverSetAnAccessGroupAndStayWhenUnlocked() async throws {
        let session = RecordingKeychainSession()
        let gateway = GatewayID(rawValue: "synthetic-gateway")

        let credentials = KeychainCredentialStore(keychain: session)
        try await credentials.saveCredential(GatewayCredential(rawValue: "synthetic-secret"), for: gateway)
        _ = try await credentials.loadCredential(for: gateway)
        try await credentials.deleteCredential(for: gateway)

        let tokens = KeychainTokenStore(keychain: session)
        try await tokens.saveToken(StoredToken(rawValue: "synthetic-token"), for: gateway)
        _ = try await tokens.loadToken(for: gateway)
        try await tokens.deleteToken(for: gateway)

        let pins = KeychainPinStore(keychain: session)
        let pin = SPKIFingerprint(rawBytes: [UInt8](repeating: 1, count: 32))
        try await pins.savePin(pin, for: gateway)
        _ = try await pins.loadPin(for: gateway)
        try await pins.deletePin(for: gateway)

        XCTAssertGreaterThanOrEqual(session.queries.count, 9)
        for query in session.queries {
            XCTAssertNil(query[kSecAttrAccessGroup as String],
                         "gateway credential/token/pin stores must never use a shared access group")
            XCTAssertEqual(query[kSecAttrAccessible as String] as? String,
                           kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        }

        let staticAttributes: [[String: Any]] = [
            KeychainCredentialStore.baseAttributes(account: "a"),
            KeychainTokenStore.baseAttributes(account: "a"),
            KeychainPinStore.baseAttributes(account: "a"),
        ]
        for attributes in staticAttributes {
            XCTAssertNil(attributes[kSecAttrAccessGroup as String])
            XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                           kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        }
    }

    func testSharedPushKeyAttributesDifferFromPrivateStoreAttributes() {
        let shared = FleetSharedKeychain.baseAttributes(item: .pushPrivateKey, accessGroup: syntheticGroup)
        XCTAssertNotNil(shared[kSecAttrAccessGroup as String])
        XCTAssertEqual(shared[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(shared[kSecAttrAccessible as String] as? String,
                          KeychainTokenStore.baseAttributes(account: "a")[kSecAttrAccessible as String] as? String)
    }

    // MARK: relay_key_id

    func testRelayKeyIDMeetsTheRelayContract() throws {
        let first = try XCTUnwrap(RelayKeyID.generate())
        let second = try XCTUnwrap(RelayKeyID.generate())
        XCTAssertNotEqual(first, second, "a different id for every gateway")
        for id in [first, second] {
            XCTAssertTrue(RelayKeyID.isValid(id))
            XCTAssertGreaterThanOrEqual(id.count, 22)
            XCTAssertLessThanOrEqual(id.count, 64)
            XCTAssertFalse(id.contains("="))
            XCTAssertFalse(id.contains("+"))
            XCTAssertFalse(id.contains("/"))
        }
    }

    func testRelayKeyIDValidationRejectsShortLongAndNonBase64URL() {
        XCTAssertFalse(RelayKeyID.isValid(String(repeating: "a", count: 21)), "under 128 bits")
        XCTAssertTrue(RelayKeyID.isValid(String(repeating: "a", count: 22)))
        XCTAssertTrue(RelayKeyID.isValid(String(repeating: "a", count: 64)))
        XCTAssertFalse(RelayKeyID.isValid(String(repeating: "a", count: 65)))
        XCTAssertFalse(RelayKeyID.isValid(String(repeating: "a", count: 21) + "="))
        XCTAssertFalse(RelayKeyID.isValid(String(repeating: "a", count: 21) + "/"))
        XCTAssertFalse(RelayKeyID.isValid(String(repeating: "a", count: 21) + " "))
    }
}
