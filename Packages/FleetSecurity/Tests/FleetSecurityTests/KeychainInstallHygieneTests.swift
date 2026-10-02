import XCTest
import Security
import FleetCore
@testable import FleetSecurity

/// In-memory `KeychainSession` keyed by (service, account). Supports the
/// exact query shapes the three stores and the hygiene purge use: per-account
/// add/update/copy, and service-wide list/delete.
private final class InMemoryKeychainFake: KeychainSession, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: [String: Data]] = [:]  // service -> account -> data
    private var forcedDeleteStatus: OSStatus?
    private(set) var deleteCount = 0

    func forceDeleteStatus(_ status: OSStatus?) {
        lock.lock(); defer { lock.unlock() }
        forcedDeleteStatus = status
    }

    func count(service: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return items[service]?.count ?? 0
    }

    var totalCount: Int {
        lock.lock(); defer { lock.unlock() }
        return items.values.reduce(0) { $0 + $1.count }
    }

    func add(_ query: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        guard let dict = query as? [String: Any],
              let service = dict[kSecAttrService as String] as? String,
              let account = dict[kSecAttrAccount as String] as? String else { return errSecParam }
        items[service, default: [:]][account] = dict[kSecValueData as String] as? Data ?? Data()
        return errSecSuccess
    }

    func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        guard let dict = query as? [String: Any],
              let service = dict[kSecAttrService as String] as? String,
              let account = dict[kSecAttrAccount as String] as? String else { return errSecParam }
        guard items[service]?[account] != nil else { return errSecItemNotFound }
        if let update = attributesToUpdate as? [String: Any],
           let data = update[kSecValueData as String] as? Data {
            items[service]?[account] = data
        }
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        deleteCount += 1
        if let forced = forcedDeleteStatus { return forced }
        guard let dict = query as? [String: Any],
              let service = dict[kSecAttrService as String] as? String else { return errSecParam }
        if let account = dict[kSecAttrAccount as String] as? String {
            items[service]?[account] = nil
        } else {
            items[service] = nil
        }
        return errSecSuccess
    }

    func copyMatching(_ query: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        guard let dict = query as? [String: Any],
              let service = dict[kSecAttrService as String] as? String else { return errSecParam }
        if let account = dict[kSecAttrAccount as String] as? String {
            guard let data = items[service]?[account] else { return errSecItemNotFound }
            result = data as CFTypeRef
            return errSecSuccess
        }
        guard let accounts = items[service], !accounts.isEmpty else { return errSecItemNotFound }
        let rows: [[String: Any]] = accounts.keys.map {
            [kSecAttrService as String: service, kSecAttrAccount as String: $0]
        }
        result = rows as CFArray
        return errSecSuccess
    }
}

final class KeychainInstallHygieneTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "keychain-hygiene-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Seeds one item in each of the app's namespaces through the real stores
    /// (credential, token, TLS pin, first-use approval).
    private func seedStores(_ keychain: InMemoryKeychainFake) async throws {
        let id = GatewayID(rawValue: "gw-a")
        try await KeychainCredentialStore(keychain: keychain)
            .saveCredential(GatewayCredential(rawValue: "synthetic-secret"), for: id)
        try await KeychainTokenStore(keychain: keychain)
            .saveToken(StoredToken(rawValue: "synthetic-token"), for: id)
        let pins = KeychainPinStore(keychain: keychain)
        let pin = try XCTUnwrap(SPKIFingerprint(base64: "0sshb6QBdnSVmS4d7pNB5MC4rowmN+JUeF0KQS/kpOk="))
        try await pins.savePin(pin, for: id)
        try await pins.approveFirstUse(for: id)
    }

    func testFreshInstallWithLeftoverItemsPurgesThenSetsMarker() async throws {
        let keychain = InMemoryKeychainFake()
        try await seedStores(keychain)
        XCTAssertEqual(keychain.totalCount, 4)

        let hygiene = KeychainInstallHygiene(keychain: keychain, defaults: defaults)
        let outcome = hygiene.runIfNeeded(hasPriorInstallEvidence: false)

        XCTAssertEqual(outcome, .purged(count: 4))
        XCTAssertEqual(keychain.totalCount, 0)
        XCTAssertTrue(defaults.bool(forKey: KeychainInstallHygiene.markerFlagName))
        XCTAssertFalse(defaults.bool(forKey: KeychainInstallHygiene.purgePendingFlagName))
        let credential = try await KeychainCredentialStore(keychain: keychain)
            .loadCredential(for: GatewayID(rawValue: "gw-a"))
        XCTAssertNil(credential)
    }

    func testMarkerPresentLeavesItemsUntouched() async throws {
        let keychain = InMemoryKeychainFake()
        try await seedStores(keychain)
        defaults.set(true, forKey: KeychainInstallHygiene.markerFlagName)

        let hygiene = KeychainInstallHygiene(keychain: keychain, defaults: defaults)
        // Even with no sandbox evidence, a present marker wins.
        let outcome = hygiene.runIfNeeded(hasPriorInstallEvidence: false)

        XCTAssertEqual(outcome, .skippedMarkerPresent)
        XCTAssertEqual(keychain.totalCount, 4)
        XCTAssertEqual(keychain.deleteCount, 0)
    }

    /// The upgrade case: a build that predates this feature has no marker but
    /// its sandbox is populated. Credentials must survive and the marker is
    /// adopted so a later (still-populated) launch stays a no-op.
    func testUpgradeFromBuildWithoutMarkerKeepsCredentialsAndAdoptsMarker() async throws {
        let keychain = InMemoryKeychainFake()
        try await seedStores(keychain)

        let hygiene = KeychainInstallHygiene(keychain: keychain, defaults: defaults)
        let outcome = hygiene.runIfNeeded(hasPriorInstallEvidence: true)

        XCTAssertEqual(outcome, .adoptedExistingInstall)
        XCTAssertEqual(keychain.totalCount, 4)
        XCTAssertEqual(keychain.deleteCount, 0)
        XCTAssertTrue(defaults.bool(forKey: KeychainInstallHygiene.markerFlagName))

        // Second launch: marker fast path, still untouched.
        XCTAssertEqual(hygiene.runIfNeeded(hasPriorInstallEvidence: true), .skippedMarkerPresent)
        XCTAssertEqual(keychain.totalCount, 4)
    }

    func testIsIdempotentAfterPurge() async throws {
        let keychain = InMemoryKeychainFake()
        try await seedStores(keychain)
        let hygiene = KeychainInstallHygiene(keychain: keychain, defaults: defaults)
        XCTAssertEqual(hygiene.runIfNeeded(hasPriorInstallEvidence: false), .purged(count: 4))

        // A credential added after the purge (the user set up a gateway)
        // must survive every later launch, including one where the sandbox
        // is (now) populated.
        try await KeychainCredentialStore(keychain: keychain)
            .saveCredential(GatewayCredential(rawValue: "synthetic-secret-2"), for: GatewayID(rawValue: "gw-b"))
        XCTAssertEqual(hygiene.runIfNeeded(hasPriorInstallEvidence: false), .skippedMarkerPresent)
        XCTAssertEqual(hygiene.runIfNeeded(hasPriorInstallEvidence: true), .skippedMarkerPresent)
        XCTAssertEqual(keychain.totalCount, 1)
    }

    func testEmptyKeychainFreshInstallStillSetsMarker() {
        let keychain = InMemoryKeychainFake()
        let hygiene = KeychainInstallHygiene(keychain: keychain, defaults: defaults)
        XCTAssertEqual(hygiene.runIfNeeded(hasPriorInstallEvidence: false), .purged(count: 0))
        XCTAssertTrue(defaults.bool(forKey: KeychainInstallHygiene.markerFlagName))
    }

    func testFailedDeleteDoesNotSetMarkerAndRetryOverridesEvidence() async throws {
        let keychain = InMemoryKeychainFake()
        try await seedStores(keychain)
        keychain.forceDeleteStatus(errSecInteractionNotAllowed)

        let hygiene = KeychainInstallHygiene(keychain: keychain, defaults: defaults)
        XCTAssertEqual(
            hygiene.runIfNeeded(hasPriorInstallEvidence: false),
            .purgeFailed(status: errSecInteractionNotAllowed))
        XCTAssertFalse(defaults.bool(forKey: KeychainInstallHygiene.markerFlagName))
        XCTAssertTrue(defaults.bool(forKey: KeychainInstallHygiene.purgePendingFlagName))
        XCTAssertEqual(keychain.totalCount, 4)

        // Next launch: the failed attempt's own launch created sandbox state,
        // so evidence is now true, but the pending flag forces the retry.
        keychain.forceDeleteStatus(nil)
        XCTAssertEqual(hygiene.runIfNeeded(hasPriorInstallEvidence: true), .purged(count: 4))
        XCTAssertEqual(keychain.totalCount, 0)
        XCTAssertTrue(defaults.bool(forKey: KeychainInstallHygiene.markerFlagName))
        XCTAssertFalse(defaults.bool(forKey: KeychainInstallHygiene.purgePendingFlagName))
    }

    func testFailedInstallPurgeCannotAcceptNewCredentialsBeforeRetrySucceeds() async throws {
        let keychain = InMemoryKeychainFake()
        try await seedStores(keychain)
        keychain.forceDeleteStatus(errSecInteractionNotAllowed)
        let hygiene = KeychainInstallHygiene(keychain: keychain, defaults: defaults)
        XCTAssertEqual(hygiene.runIfNeeded(hasPriorInstallEvidence: false),
                       .purgeFailed(status: errSecInteractionNotAllowed))
        let session = InstallReconciledKeychainSession(
            keychain: keychain, defaults: defaults, hasPriorInstallEvidence: false)
        let credentials = KeychainCredentialStore(keychain: session)
        let newID = GatewayID(rawValue: "new-gateway")
        do {
            try await credentials.saveCredential(GatewayCredential(rawValue: "synthetic-new"), for: newID)
            XCTFail("failed install reconciliation must not accept credentials that its retry will erase")
        } catch {
            XCTAssertEqual(error as? CredentialStoreError, .unexpectedStatus(Int(errSecInteractionNotAllowed)))
        }
        XCTAssertEqual(keychain.totalCount, 4)
        keychain.forceDeleteStatus(nil)
        try await credentials.saveCredential(GatewayCredential(rawValue: "synthetic-new"), for: newID)
        let restored = try await credentials.loadCredential(for: newID)
        XCTAssertEqual(restored?.rawValue, "synthetic-new")
        XCTAssertEqual(keychain.totalCount, 1, "old install items are gone before the new credential is accepted")
        XCTAssertTrue(defaults.bool(forKey: KeychainInstallHygiene.markerFlagName))
        XCTAssertFalse(defaults.bool(forKey: KeychainInstallHygiene.purgePendingFlagName))
    }

    func testPurgeOnlyTouchesAppNamespaces() async throws {
        let keychain = InMemoryKeychainFake()
        try await seedStores(keychain)
        XCTAssertEqual(keychain.add([
            kSecAttrService as String: "com.example.unrelated",
            kSecAttrAccount as String: "other",
            kSecValueData as String: Data("x".utf8),
        ] as CFDictionary), errSecSuccess)

        KeychainInstallHygiene(keychain: keychain, defaults: defaults)
            .runIfNeeded(hasPriorInstallEvidence: false)

        XCTAssertEqual(keychain.count(service: "com.example.unrelated"), 1)
        XCTAssertEqual(keychain.totalCount, 1)
    }

    func testDefaultServicesCoverEveryKeychainNamespace() {
        XCTAssertEqual(
            Set(KeychainInstallHygiene.defaultServices),
            [
                "com.aiowa.hermesfleet.gateway-credentials",
                "com.aiowa.hermesfleet.tokens",
                "com.aiowa.hermesfleet.tlspins",
            ])
    }
}
