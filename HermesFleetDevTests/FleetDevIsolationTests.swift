import XCTest
import Security
import FleetCore
import FleetSecurity
@testable import HermesFleetDev

/// Hosted by the actual Dev app; all credentials and keychain calls are fake.
final class FleetDevIsolationTests: XCTestCase {
    func testHostHasOnlyDevelopmentIdentity() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.aiowa.hermesfleet.dev")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "FleetDevBuild") as? Bool, true)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Hermes Fleet Dev")
        XCTAssertTrue(FleetAppIdentity.current.isDevelopment)
        XCTAssertEqual(FleetAppIdentity.keychainNamespace, "com.aiowa.hermesfleet.dev")
    }

    func testProductionIdentityRemainsStable() throws {
        let production = try FleetAppIdentity.resolve(bundleIdentifier: "com.aiowa.hermesfleet", developmentMarker: false)
        XCTAssertEqual(production.keychainNamespace, "com.aiowa.hermesfleet")
        XCTAssertEqual(production.conversationURLScheme, "hermes-fleet")
        XCTAssertEqual(production.cacheDirectoryName, "HermesFleetCache")
        XCTAssertFalse(production.isDevelopment)
    }

    func testInconsistentDevelopmentMetadataFailsClosed() {
        XCTAssertThrowsError(try FleetAppIdentity.resolve(bundleIdentifier: "com.aiowa.hermesfleet.dev", developmentMarker: false))
        XCTAssertThrowsError(try FleetAppIdentity.resolve(bundleIdentifier: "com.aiowa.hermesfleet", developmentMarker: true))
        XCTAssertThrowsError(try FleetAppIdentity.resolve(bundleIdentifier: nil, developmentMarker: true))
    }

    func testDevCredentialSaveAndDeletePreserveProductionItem() async throws {
        let fake = DevKeychainFake()
        let gateway = GatewayID(rawValue: "fixture-gateway")
        let productionService = "com.aiowa.hermesfleet.gateway-credentials"
        fake.seed(service: productionService, account: gateway.rawValue)
        let store = KeychainCredentialStore(keychain: fake)
        try await store.saveCredential(GatewayCredential(rawValue: "synthetic-dev-secret"), for: gateway)
        XCTAssertEqual(fake.count(service: productionService), 1)
        XCTAssertEqual(fake.count(service: KeychainCredentialStore.serviceName), 1)
        try await store.deleteCredential(for: gateway)
        XCTAssertEqual(fake.count(service: productionService), 1)
        XCTAssertEqual(fake.count(service: KeychainCredentialStore.serviceName), 0)
    }

    func testFreshDevInstallPurgePreservesAllProductionServices() {
        let fake = DevKeychainFake()
        let production = ["gateway-credentials", "tokens", "tlspins"].map { "com.aiowa.hermesfleet." + $0 }
        for service in production + KeychainInstallHygiene.defaultServices {
            fake.seed(service: service, account: "synthetic-gateway")
        }
        let suite = "fleet-dev-hygiene-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let result = KeychainInstallHygiene(keychain: fake, defaults: defaults).runIfNeeded(hasPriorInstallEvidence: false)
        XCTAssertEqual(result, .purged(count: 3))
        for service in production { XCTAssertEqual(fake.count(service: service), 1) }
        for service in KeychainInstallHygiene.defaultServices { XCTAssertEqual(fake.count(service: service), 0) }
    }

    func testEveryStoreUsesDevNamespaceAndPrivateDefaultAccessGroup() {
        let queries = [KeychainCredentialStore.baseAttributes(account: "synthetic"),
                       KeychainTokenStore.baseAttributes(account: "synthetic"),
                       KeychainPinStore.baseAttributes(account: "synthetic")]
        for query in queries {
            XCTAssertTrue((query[kSecAttrService as String] as? String)?.hasPrefix("com.aiowa.hermesfleet.dev.") == true)
            XCTAssertNil(query[kSecAttrAccessGroup as String])
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(query[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        }
    }

    func testShortcutRoundTripRejectsProductionScheme() {
        let route = Route(gatewayID: GatewayID(rawValue: "fixture-gateway"), profileSlug: ProfileSlug(rawValue: "default"))
        let entity = FleetConversationShortcutEntity(id: "synthetic", route: route, sessionID: "session-1", canonical: false)
        let url = FleetConversationDeepLink.url(for: entity)
        XCTAssertEqual(url.scheme, "hermes-fleet-dev")
        XCTAssertNotNil(FleetConversationDeepLink.target(from: url))
        var production = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        production.scheme = "hermes-fleet"
        XCTAssertNil(FleetConversationDeepLink.target(from: production.url!))
    }

    func testCacheIdentityAndDefaultsDomainSeparateFromProduction() throws {
        let production = try FleetAppIdentity.resolve(bundleIdentifier: "com.aiowa.hermesfleet", developmentMarker: false)
        XCTAssertEqual(FleetAppIdentity.cacheDirectoryName, "HermesFleetDevCache")
        XCTAssertNotEqual(FleetAppIdentity.cacheDirectoryName, production.cacheDirectoryName)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "FleetCacheDirectory") as? String, FleetAppIdentity.cacheDirectoryName)
        // Explicit synthetic domains avoid reading or changing any real defaults.
        let id = UUID().uuidString
        let devName = "synthetic.dev." + id, prodName = "synthetic.production." + id
        let dev = UserDefaults(suiteName: devName)!, prod = UserDefaults(suiteName: prodName)!
        defer { dev.removePersistentDomain(forName: devName); prod.removePersistentDomain(forName: prodName) }
        prod.set("production-fixture", forKey: "shared-key")
        dev.set("dev-fixture", forKey: "shared-key")
        XCTAssertEqual(prod.string(forKey: "shared-key"), "production-fixture")
        XCTAssertEqual(dev.string(forKey: "shared-key"), "dev-fixture")
    }
}

private final class DevKeychainFake: KeychainSession, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: [String: Data]] = [:]
    func seed(service: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        items[service, default: [:]][account] = Data("synthetic".utf8)
    }
    func count(service: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return items[service]?.count ?? 0
    }
    func add(_ query: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        guard let q = query as? [String: Any], let service = q[kSecAttrService as String] as? String,
              let account = q[kSecAttrAccount as String] as? String else { return errSecParam }
        items[service, default: [:]][account] = q[kSecValueData as String] as? Data ?? Data()
        return errSecSuccess
    }
    func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus { errSecItemNotFound }
    func delete(_ query: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        guard let q = query as? [String: Any], let service = q[kSecAttrService as String] as? String else { return errSecParam }
        if let account = q[kSecAttrAccount as String] as? String { items[service]?[account] = nil }
        else { items[service] = nil }
        return errSecSuccess
    }
    func copyMatching(_ query: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        guard let q = query as? [String: Any], let service = q[kSecAttrService as String] as? String,
              let records = items[service], !records.isEmpty else { return errSecItemNotFound }
        result = records.keys.map { [kSecAttrAccount as String: $0] } as CFArray
        return errSecSuccess
    }
}
