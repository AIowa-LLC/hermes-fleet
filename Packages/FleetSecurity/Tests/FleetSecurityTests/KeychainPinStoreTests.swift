import XCTest
import Security
import FleetCore
@testable import FleetSecurity

/// Scripted `KeychainSession` double for the pin store (same pattern as
/// FleetSecurityFailureSafetyTests).
private final class ScriptedKeychainSession: KeychainSession, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]
    private var forcedAddStatus: OSStatus?
    private var forcedUpdateStatus: OSStatus?
    private var forcedDeleteStatus: OSStatus?
    private var forcedCopyStatus: OSStatus?

    private(set) var addCount = 0
    private(set) var updateCount = 0
    private(set) var deleteCount = 0

    func seed(_ data: Data, account: String) {
        lock.lock(); defer { lock.unlock() }
        store[account] = data
    }

    func storedAccounts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(store.keys)
    }

    func forceAddStatus(_ status: OSStatus) {
        lock.lock(); defer { lock.unlock() }
        forcedAddStatus = status
    }

    func forceUpdateStatus(_ status: OSStatus) {
        lock.lock(); defer { lock.unlock() }
        forcedUpdateStatus = status
    }

    func forceDeleteStatus(_ status: OSStatus) {
        lock.lock(); defer { lock.unlock() }
        forcedDeleteStatus = status
    }

    func forceCopyStatus(_ status: OSStatus) {
        lock.lock(); defer { lock.unlock() }
        forcedCopyStatus = status
    }

    // MARK: KeychainSession

    func add(_ query: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        addCount += 1
        if let forced = forcedAddStatus { return forced }
        guard let dict = query as? [String: Any],
              let account = dict[kSecAttrAccount as String] as? String else {
            return errSecParam
        }
        store[account] = dict[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        updateCount += 1
        if let forced = forcedUpdateStatus { return forced }
        guard let dict = query as? [String: Any],
              let account = dict[kSecAttrAccount as String] as? String else {
            return errSecParam
        }
        guard store[account] != nil else { return errSecItemNotFound }
        if let update = attributesToUpdate as? [String: Any],
           let data = update[kSecValueData as String] as? Data {
            store[account] = data
        }
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        deleteCount += 1
        if let forced = forcedDeleteStatus { return forced }
        guard let dict = query as? [String: Any],
              let account = dict[kSecAttrAccount as String] as? String else {
            return errSecParam
        }
        store[account] = nil
        return errSecSuccess
    }

    func copyMatching(_ query: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        if let forced = forcedCopyStatus { return forced }
        guard let dict = query as? [String: Any],
              let account = dict[kSecAttrAccount as String] as? String,
              let data = store[account] else {
            return errSecItemNotFound
        }
        result = data as CFTypeRef
        return errSecSuccess
    }
}

/// T3 — Keychain-backed TLS pin store (`KeychainPinStore`).
///
/// Contract mirrors KeychainTokenStore: GenericPassword, per-peer account,
/// WhenUnlockedThisDeviceOnly, no sync, atomic upsert (update-then-add,
/// NEVER delete-then-add), delete failures propagate.
final class KeychainPinStoreTests: XCTestCase {

    private let gatewayID = GatewayID(rawValue: "workstation")
    private static let pinB64 = "0sshb6QBdnSVmS4d7pNB5MC4rowmN+JUeF0KQS/kpOk="
    private static let otherB64 = "85yFqwhKWLa3bnAIOCtS/8bmZ4pznYYnPPp7l9MD65o="

    func testSaveLoadRoundTripAndTOFULoadNil() async throws {
        let session = ScriptedKeychainSession()
        let store = KeychainPinStore(keychain: session)
        let pin = try XCTUnwrap(SPKIFingerprint(base64: Self.pinB64))

        // TOFU: nothing stored → nil, no error
        let none = try await store.loadPin(for: gatewayID)
        XCTAssertNil(none)

        try await store.savePin(pin, for: gatewayID)

        let loaded = try await store.loadPin(for: gatewayID)
        XCTAssertEqual(loaded, pin)
        XCTAssertEqual(loaded?.base64String, Self.pinB64)
    }

    func testUpsertUpdatesInPlaceNotDeleteThenAdd() async throws {
        let session = ScriptedKeychainSession()
        let store = KeychainPinStore(keychain: session)
        let first = try XCTUnwrap(SPKIFingerprint(base64: Self.pinB64))
        let replacement = try XCTUnwrap(SPKIFingerprint(base64: Self.otherB64))

        try await store.savePin(first, for: gatewayID)
        try await store.savePin(replacement, for: gatewayID)

        XCTAssertEqual(session.deleteCount, 0, "upsert must never delete-then-add")
        XCTAssertEqual(session.updateCount, 2)
        let reloaded = try await store.loadPin(for: gatewayID)
        XCTAssertEqual(reloaded, replacement)
    }

    func testFailedReplacementKeepsWorkingPin() async throws {
        let session = ScriptedKeychainSession()
        let store = KeychainPinStore(keychain: session)
        let working = try XCTUnwrap(SPKIFingerprint(base64: Self.pinB64))
        try await store.savePin(working, for: gatewayID)

        session.forceUpdateStatus(errSecNotAvailable)
        let replacement = try XCTUnwrap(SPKIFingerprint(base64: Self.otherB64))
        do {
            try await store.savePin(replacement, for: gatewayID)
            XCTFail("expected save failure")
        } catch let error as PinStoreError {
            guard case .unexpectedStatus = error else {
                return XCTFail("expected unexpectedStatus, got \(error)")
            }
        }
        let reloaded = try await store.loadPin(for: gatewayID)
        XCTAssertEqual(reloaded, working,
                       "a failed replacement must not lose the working pin")
    }

    func testDeletePropagatesFailureAndMissingIsNoOp() async throws {
        let session = ScriptedKeychainSession()
        let store = KeychainPinStore(keychain: session)

        // Missing → no-op
        try await store.deletePin(for: gatewayID)

        // Failure propagates
        session.forceDeleteStatus(errSecNotAvailable)
        do {
            try await store.deletePin(for: gatewayID)
            XCTFail("expected delete failure to propagate")
        } catch let error as PinStoreError {
            guard case .unexpectedStatus = error else {
                return XCTFail("expected unexpectedStatus, got \(error)")
            }
        }
    }

    func testMalformedStoredDataSurfacesTypedError() async throws {
        let session = ScriptedKeychainSession()
        session.seed(Data("garbage".utf8), account: gatewayID.rawValue)
        let store = KeychainPinStore(keychain: session)

        do {
            _ = try await store.loadPin(for: gatewayID)
            XCTFail("expected malformedData")
        } catch let error as PinStoreError {
            XCTAssertEqual(error, .malformedData)
        }
        _ = session.storedAccounts() // keep helper referenced
    }

    func testBaseAttributesMatchSecurityPolicy() {
        // Public so the app-level boundary test can assert attributes; here
        // assert the same hardening as the token store: WhenUnlockedThisDeviceOnly,
        // no iCloud sync, dedicated service name.
        let attrs = KeychainPinStore.baseAttributes(account: gatewayID.rawValue)
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(attrs[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(attrs[kSecAttrService as String] as? String, KeychainPinStore.serviceName)
        XCTAssertNotEqual(KeychainPinStore.serviceName, KeychainTokenStore.serviceName,
                          "pins live in their own service namespace")
    }
}
