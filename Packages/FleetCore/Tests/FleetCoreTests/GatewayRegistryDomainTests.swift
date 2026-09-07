import XCTest
@testable import FleetCore

/// M7 Gateway Registry domain: auth configuration, credential redaction,
/// capability surface, registration/edit values, test result, registry errors,
/// and the §13 status mapping for connectivity probes.
final class GatewayRegistryDomainTests: XCTestCase {

    // MARK: GatewayAuthConfiguration

    func testAuthConfigurationDefaultsToNone() {
        let config = GatewayAuthConfiguration()
        XCTAssertEqual(config.strategy, .none)
        XCTAssertFalse(config.credentialStored)
        XCTAssertEqual(GatewayAuthConfiguration.none, config)
    }

    func testAuthConfigurationStrategyCases() {
        XCTAssertEqual(
            Set(GatewayAuthConfiguration.Strategy.allCases),
            Set([.none, .sessionToken, .bearerToken, .loopbackToken, .usernamePassword]))
    }

    func testAuthConfigurationCodableRoundTrip() throws {
        let config = GatewayAuthConfiguration(strategy: .sessionToken, credentialStored: true)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GatewayAuthConfiguration.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    // MARK: GatewayCredential redaction (spec §16, §27, §29)

    func testCredentialDescriptionIsRedacted() {
        let secret = GatewayCredential(rawValue: "super-secret-token-value")
        XCTAssertEqual(secret.description, "[REDACTED]")
        XCTAssertEqual("\(secret)", "[REDACTED]")
        XCTAssertEqual(secret.debugDescription, "GatewayCredential(redacted)")
        // The raw value must not appear in any printable representation.
        XCTAssertFalse(secret.description.contains("super-secret-token-value"))
        XCTAssertFalse(secret.debugDescription.contains("super-secret-token-value"))
    }

    func testCredentialEqualityComparesRawValue() {
        XCTAssertEqual(GatewayCredential(rawValue: "a"), GatewayCredential(rawValue: "a"))
        XCTAssertNotEqual(GatewayCredential(rawValue: "a"), GatewayCredential(rawValue: "b"))
    }

    // MARK: CredentialStoreError

    func testCredentialStoreErrorVocabulary() {
        XCTAssertEqual(CredentialStoreError.itemNotFound, .itemNotFound)
        XCTAssertNotEqual(CredentialStoreError.itemNotFound, .malformedData)
        XCTAssertEqual(CredentialStoreError.unexpectedStatus(50), CredentialStoreError.unexpectedStatus(50))
        XCTAssertTrue((CredentialStoreError.itemNotFound.errorDescription ?? "").contains("no credential"))
        // No secret material in error descriptions.
        XCTAssertFalse(CredentialStoreError.unexpectedStatus(5).errorDescription?.contains("secret") ?? false)
    }

    // MARK: GatewayCapabilities (spec §5.5 tolerant detection)

    func testCapabilitiesTolerantDecode() {
        let surface = GatewayCapabilities(strings: ["heartbeat", "change_events", "future_flag"])
        XCTAssertTrue(surface.contains(.heartbeat))
        XCTAssertTrue(surface.contains(.changeEvents))
        XCTAssertFalse(surface.contains(.replay))
        XCTAssertEqual(surface.unknown, ["future_flag"])
        XCTAssertEqual(surface.allStrings, ["heartbeat", "change_events", "future_flag"])
    }

    func testCapabilitiesEmpty() {
        let surface = GatewayCapabilities(strings: [])
        XCTAssertTrue(surface.isEmpty)
    }

    func testCapabilitiesRoundTripAllStrings() {
        let surface = GatewayCapabilities(strings: ["heartbeat", "mystery"])
        XCTAssertEqual(GatewayCapabilities(strings: surface.allStrings), surface)
    }

    func testCapabilityRawValues() {
        XCTAssertEqual(GatewayCapability.heartbeat.rawValue, "heartbeat")
        XCTAssertEqual(GatewayCapability.changeEvents.rawValue, "change_events")
        XCTAssertEqual(GatewayCapability.replay.rawValue, "replay")
        XCTAssertNil(GatewayCapability(rawWireValue: "not-a-capability"))
    }

    // MARK: GatewayRegistration / GatewayEdit

    func testRegistrationDefaults() {
        let registration = GatewayRegistration(displayName: "MacBook", endpoint: URL(string: "http://127.0.0.1:8642")!)
        XCTAssertNil(registration.id)
        XCTAssertEqual(registration.authConfiguration, .none)
    }

    func testEditAppliesOnlyNonNilFields() {
        let base = FleetGateway(id: GatewayID(rawValue: "a"), displayName: "A", endpoint: URL(string: "http://x")!)
        let edit = GatewayEdit(displayName: "B") // endpoint / auth untouched
        let updated = edit.applied(to: base)
        XCTAssertEqual(updated.displayName, "B")
        XCTAssertEqual(updated.endpoint, URL(string: "http://x"))
        XCTAssertEqual(updated.authConfiguration, .none)
    }

    func testEditAppliesEndpointAndAuth() {
        let base = FleetGateway(id: GatewayID(rawValue: "a"), displayName: "A")
        let edit = GatewayEdit(
            endpoint: URL(string: "http://new")!,
            authConfiguration: GatewayAuthConfiguration(strategy: .sessionToken, credentialStored: true)
        )
        let updated = edit.applied(to: base)
        XCTAssertEqual(updated.endpoint, URL(string: "http://new"))
        XCTAssertEqual(updated.authConfiguration.strategy, .sessionToken)
        XCTAssertEqual(updated.authConfiguration.credentialStored, true)
        XCTAssertEqual(updated.displayName, "A", "nil displayName leaves it unchanged")
    }

    // MARK: GatewayTestResult

    func testTestResultDefaults() {
        let result = GatewayTestResult(status: .online)
        XCTAssertTrue(result.capabilities.isEmpty)
        XCTAssertNil(result.serverIdentity)
    }

    func testTestResultEqualityAndHashable() {
        let a = GatewayTestResult(status: .online, capabilities: GatewayCapabilities(strings: ["heartbeat"]), serverIdentity: "id")
        let b = GatewayTestResult(status: .online, capabilities: GatewayCapabilities(strings: ["heartbeat"]), serverIdentity: "id")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    // MARK: GatewayRegistryError (fail closed)

    func testRegistryErrorVocabulary() {
        let id = GatewayID(rawValue: "gw")
        XCTAssertEqual(GatewayRegistryError.notFound(id), .notFound(id))
        XCTAssertNotEqual(GatewayRegistryError.notFound(id), .duplicate(id))
        XCTAssertEqual(GatewayRegistryError.invalidEndpoint, .invalidEndpoint)
        XCTAssertEqual(GatewayRegistryError.emptyDisplayName, .emptyDisplayName)
        XCTAssertEqual(GatewayRegistryError.credentialStoreFailed("boom"), .credentialStoreFailed("boom"))
        // Error text carries no secrets.
        XCTAssertTrue((GatewayRegistryError.notFound(id).errorDescription ?? "").contains("not found"))
    }

    // MARK: GatewayID(endpoint:) derivation

    func testGatewayIDDerivedFromEndpoint() {
        XCTAssertEqual(
            GatewayID(endpoint: URL(string: "http://192.168.50.58:8642")!).rawValue,
            "192.168.50.58:8642")
        XCTAssertEqual(
            GatewayID(endpoint: URL(string: "https://workstation:9119")!).rawValue,
            "workstation:9119")
        // Deterministic: same endpoint → same ID.
        XCTAssertEqual(
            GatewayID(endpoint: URL(string: "http://workstation:9119")!),
            GatewayID(endpoint: URL(string: "http://workstation:9119")!))
    }

    // MARK: GatewayStatus(connectivityError:) — §13 probe classification

    func testGatewayStatusFromConnectivityError() {
        XCTAssertEqual(GatewayStatus(connectivityError: .authenticationRequired), .authenticationRequired)
        XCTAssertEqual(GatewayStatus(connectivityError: .unreachable), .offline)
        XCTAssertEqual(GatewayStatus(connectivityError: .timeout), .offline)
        XCTAssertEqual(GatewayStatus(connectivityError: .unsupported("chat disabled")), .unsupported)
        XCTAssertEqual(GatewayStatus(connectivityError: .connectionFailed("server error (1011)")), .degraded)
        XCTAssertEqual(GatewayStatus(connectivityError: .connectionFailed("abnormal closure")), .offline)
        XCTAssertEqual(GatewayStatus(connectivityError: .invalidState("nope")), .offline)
    }
}
