import XCTest
import Security
import FleetCore
@testable import FleetSecurity

/// Scripted `KeychainSession` double: records every SecItem call and lets a
/// test force any OSStatus. Enables P2-4 injected-failure tests without a
/// live keychain (CI stays hermetic).
private final class ScriptedKeychainSession: KeychainSession, @unchecked Sendable {
    enum Mode {
        /// delete-then-add behaves exactly like a fresh keychain (add succeeds).
        case add
        /// update-into-place succeeds only when the item already exists.
        case update
    }

    private let lock = NSLock()
    private var store: [String: Data] = [:]
    private var mode: Mode = .add
    private var forcedAddStatus: OSStatus?
    private var forcedDeleteStatus: OSStatus?
    private var forcedUpdateStatus: OSStatus?
    private var forcedCopyStatus: OSStatus?

    private(set) var addCount = 0
    private(set) var updateCount = 0
    private(set) var deleteCount = 0

    func seed(_ data: Data, account: String) {
        lock.lock(); defer { lock.unlock() }
        store[account] = data
    }

    func stored(_ account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return store[account]
    }

    func setMode(_ mode: Mode) {
        lock.lock(); defer { lock.unlock() }
        self.mode = mode
    }

    func forceAddStatus(_ status: OSStatus) {
        lock.lock(); defer { lock.unlock() }
        forcedAddStatus = status
    }

    func forceDeleteStatus(_ status: OSStatus) {
        lock.lock(); defer { lock.unlock() }
        forcedDeleteStatus = status
    }

    func forceUpdateStatus(_ status: OSStatus) {
        lock.lock(); defer { lock.unlock() }
        forcedUpdateStatus = status
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

/// P2-4 — Keychain replacement and deletion are not failure-safe.
///
/// Regression tests (RED on old delete-then-add, GREEN on atomic upsert):
/// - a failed replacement must NOT lose the working credential;
/// - an existing item is updated IN PLACE (no delete-then-add window);
/// - a missing item falls back to add;
/// - deletion failures propagate instead of being suppressed.
final class FleetSecurityFailureSafetyTests: XCTestCase {

    private let gatewayID = GatewayID(rawValue: "workstation")

    // MARK: KeychainCredentialStore

    func testCredentialReplacementFailureKeepsWorkingCredential() async throws {
        // Old delete-then-add: the delete already removed the working
        // credential when the add fails — the credential is LOST.
        // Fix (P2-4): update-in-place or add-on-missing; a failed write
        // leaves the previously stored credential intact.
        let session = ScriptedKeychainSession()
        session.setMode(.update)
        session.seed(CredentialEncoding.encode(GatewayCredential(rawValue: "working")), account: gatewayID.rawValue)
        session.forceUpdateStatus(errSecNotAvailable)  // the replacement write fails
        let store = KeychainCredentialStore(keychain: session)

        do {
            try await store.saveCredential(GatewayCredential(rawValue: "new"), for: gatewayID)
            XCTFail("expected replacement to fail")
        } catch let error as CredentialStoreError {
            guard case .unexpectedStatus = error else {
                return XCTFail("expected unexpectedStatus, got \(error)")
            }
        }

        let loaded = try await store.loadCredential(for: gatewayID)
        XCTAssertEqual(loaded, GatewayCredential(rawValue: "working"),
                       "a failed replacement must not lose the working credential")
        XCTAssertEqual(session.deleteCount, 0, "upsert must not delete-then-add")
        XCTAssertEqual(session.updateCount, 1, "existing item is updated in place")
    }

    func testCredentialSaveUpdatesExistingInPlace() async throws {
        let session = ScriptedKeychainSession()
        session.setMode(.update)
        session.seed(CredentialEncoding.encode(GatewayCredential(rawValue: "old")), account: gatewayID.rawValue)
        let store = KeychainCredentialStore(keychain: session)

        try await store.saveCredential(GatewayCredential(rawValue: "new"), for: gatewayID)

        XCTAssertEqual(session.deleteCount, 0, "no delete-then-add on replacement")
        XCTAssertEqual(session.updateCount, 1)
        let loaded = try await store.loadCredential(for: gatewayID)
        XCTAssertEqual(loaded, GatewayCredential(rawValue: "new"))
    }

    func testCredentialSaveAddsWhenMissing() async throws {
        let session = ScriptedKeychainSession()
        session.setMode(.update)
        let store = KeychainCredentialStore(keychain: session)

        try await store.saveCredential(GatewayCredential(rawValue: "first"), for: gatewayID)

        XCTAssertEqual(session.updateCount, 1, "update attempted first")
        XCTAssertEqual(session.addCount, 1, "falls back to add on item-not-found")
        let loaded = try await store.loadCredential(for: gatewayID)
        XCTAssertEqual(loaded, GatewayCredential(rawValue: "first"))
    }

    func testCredentialDeletePropagatesFailure() async throws {
        let session = ScriptedKeychainSession()
        session.forceDeleteStatus(errSecNotAvailable)
        let store = KeychainCredentialStore(keychain: session)

        do {
            try await store.deleteCredential(for: gatewayID)
            XCTFail("expected deletion failure to propagate")
        } catch let error as CredentialStoreError {
            guard case .unexpectedStatus = error else {
                return XCTFail("expected unexpectedStatus, got \(error)")
            }
        }
    }

    // MARK: KeychainTokenStore

    func testTokenReplacementFailureKeepsWorkingToken() async throws {
        let session = ScriptedKeychainSession()
        session.setMode(.update)
        session.seed(Data("working-token".utf8), account: gatewayID.rawValue)
        session.forceUpdateStatus(errSecNotAvailable)
        let store = KeychainTokenStore(keychain: session)

        do {
            try await store.saveToken(StoredToken(rawValue: "new-token"), for: gatewayID)
            XCTFail("expected replacement to fail")
        } catch let error as TokenStoreError {
            guard case .unexpectedStatus = error else {
                return XCTFail("expected unexpectedStatus, got \(error)")
            }
        }

        let loaded = try await store.loadToken(for: gatewayID)
        XCTAssertEqual(loaded, StoredToken(rawValue: "working-token"),
                       "a failed token replacement must not lose the working token")
        XCTAssertEqual(session.deleteCount, 0, "upsert must not delete-then-add")
        XCTAssertEqual(session.updateCount, 1)
    }

    func testTokenSaveUpdatesExistingInPlace() async throws {
        let session = ScriptedKeychainSession()
        session.setMode(.update)
        session.seed(Data("old-token".utf8), account: gatewayID.rawValue)
        let store = KeychainTokenStore(keychain: session)

        try await store.saveToken(StoredToken(rawValue: "new-token"), for: gatewayID)

        XCTAssertEqual(session.deleteCount, 0)
        XCTAssertEqual(session.updateCount, 1)
        let loaded = try await store.loadToken(for: gatewayID)
        XCTAssertEqual(loaded, StoredToken(rawValue: "new-token"))
    }

    func testTokenDeletePropagatesFailure() async throws {
        let session = ScriptedKeychainSession()
        session.forceDeleteStatus(errSecInteractionNotAllowed)
        let store = KeychainTokenStore(keychain: session)

        do {
            try await store.deleteToken(for: gatewayID)
            XCTFail("expected deletion failure to propagate")
        } catch let error as TokenStoreError {
            guard case .unexpectedStatus = error else {
                return XCTFail("expected unexpectedStatus, got \(error)")
            }
        }
    }
}
