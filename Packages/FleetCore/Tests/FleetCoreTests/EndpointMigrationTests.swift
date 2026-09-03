import XCTest
@testable import FleetCore

/// F2 (t_b678fb38) — endpoint convergence mapping unit tests.
///
/// Locks the migration contract: every dead private-network spelling of the
/// Arch gateway (any port) is re-pointed onto the configured default
/// endpoint; rows already on the default are untouched (idempotent); rows
/// pointing at unknown hosts pass through verbatim (other gateways survive);
/// identity/display-name/auth configuration are preserved; a missing or
/// unparseable default endpoint disables the migration entirely.
final class EndpointMigrationTests: XCTestCase {

    private let tunnel = "https://fleet.example.dev"

    private func record(_ endpoint: String, id: String = "arch") -> StoredGatewayRecord {
        StoredGatewayRecord(
            id: id,
            displayName: "Arch Lab",
            endpoint: endpoint,
            authConfiguration: GatewayAuthConfiguration(strategy: .usernamePassword, credentialStored: true),
            authConfigured: true
        )
    }

    // MARK: every dead spelling migrates (both relay-era and direct-era ports)

    func testLANIP8642Migrates() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://<lan-ip>:8642", defaultEndpoint: tunnel), .migrated)
    }

    func testTailnetIP8642Migrates() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://<tailnet-ip>:8642", defaultEndpoint: tunnel), .migrated)
    }

    func testTailnetIP9119Migrates() {
        // F1-era direct spelling — its ATS exception is stripped, so leaving
        // it would silently fail ATS on device.
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://<tailnet-ip>:9119", defaultEndpoint: tunnel), .migrated)
    }

    func testMagicDNSHostMigrates() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://<private-host>", defaultEndpoint: tunnel), .migrated)
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://<private-host>:9119", defaultEndpoint: tunnel), .migrated)
    }

    func testLoopbackMigrates() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://127.0.0.1:8642", defaultEndpoint: tunnel), .migrated)
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://localhost:8642", defaultEndpoint: tunnel), .migrated)
    }

    func testCaseInsensitiveHost() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://ARCHLINUX-1.TAILA00FDC.TS.NET:9119", defaultEndpoint: tunnel), .migrated)
    }

    // MARK: idempotence + unknown rows

    func testAlreadyCurrentIsIdempotent() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: tunnel, defaultEndpoint: tunnel), .alreadyCurrent)
        XCTAssertEqual(EndpointMigration.classify(endpoint: "https://fleet.example.dev:443", defaultEndpoint: tunnel), .alreadyCurrent)
    }

    func testUnknownHostUntouched() {
        // Another gateway (e.g. the Mac dogfood lane) must survive verbatim.
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://<tailnet-ip>:9120", defaultEndpoint: tunnel), .untouched)
        XCTAssertEqual(EndpointMigration.classify(endpoint: "https://other.example.com:9119", defaultEndpoint: tunnel), .untouched)
    }

    func testUnparseableEndpointUntouched() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: "not a url", defaultEndpoint: tunnel), .untouched)
        XCTAssertEqual(EndpointMigration.classify(endpoint: "", defaultEndpoint: tunnel), .untouched)
    }

    // MARK: the record mapping

    func testMigrateEndpointsRewritesOnlyDeadRows() {
        let records = [
            record("http://<tailnet-ip>:8642", id: "arch-relay"),
            record("http://<tailnet-ip>:9120", id: "mac-dogfood"),
            record(tunnel, id: "already"),
        ]
        let migrated = EndpointMigration.migrateEndpoints(in: records, defaultEndpoint: tunnel)
        XCTAssertEqual(migrated[0].endpoint, tunnel)
        XCTAssertEqual(migrated[1].endpoint, "http://<tailnet-ip>:9120", "unknown hosts must survive verbatim")
        XCTAssertEqual(migrated[2].endpoint, tunnel)
    }

    func testMigrateEndpointsPreservesIdentityAndAuth() {
        let original = record("http://127.0.0.1:8642", id: "arch")
        let migrated = EndpointMigration.migrateEndpoints(in: [original], defaultEndpoint: tunnel)
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].id, original.id)
        XCTAssertEqual(migrated[0].displayName, original.displayName)
        XCTAssertEqual(migrated[0].authConfiguration, original.authConfiguration)
        XCTAssertEqual(migrated[0].authConfigured, original.authConfigured)
    }

    func testMigrateEndpointsIsIdempotent() {
        let records = [record("http://<lan-ip>:8642")]
        let once = EndpointMigration.migrateEndpoints(in: records, defaultEndpoint: tunnel)
        let twice = EndpointMigration.migrateEndpoints(in: once, defaultEndpoint: tunnel)
        XCTAssertEqual(once, twice, "second run must be a no-op")
    }

    func testMissingDefaultEndpointDisablesMigration() {
        let records = [record("http://127.0.0.1:8642")]
        XCTAssertEqual(EndpointMigration.migrateEndpoints(in: records, defaultEndpoint: ""), records)
        XCTAssertEqual(EndpointMigration.migrateEndpoints(in: records, defaultEndpoint: "   "), records)
        XCTAssertEqual(EndpointMigration.migrateEndpoints(in: records, defaultEndpoint: "not a url"), records)
    }

    // MARK: the dead-host list itself

    func testDeadHostsCarryNoLiveTopology() {
        // The dead spellings are historical facts; the LIVE endpoint must
        // never be compiled into FleetCore. Guard: the module's dead list
        // must not contain any https origin.
        for origin in EndpointMigration.deadHosts {
            XCTAssertFalse(origin.lowercased().hasPrefix("https://"),
                           "live topology leaked into the compiled dead-host list: \(origin)")
        }
    }
}
