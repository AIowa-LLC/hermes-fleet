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

    private let tunnel = "https://gateway.example.net"

    private func record(_ endpoint: String, id: String = "gw") -> StoredGatewayRecord {
        StoredGatewayRecord(
            id: id,
            displayName: "Lab Gateway",
            endpoint: endpoint,
            authConfiguration: GatewayAuthConfiguration(strategy: .usernamePassword, credentialStored: true),
            authConfigured: true
        )
    }

    // MARK: every dead spelling migrates (both relay-era and direct-era ports)

    func testLANIP8642Migrates() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://192.168.50.20:8642", defaultEndpoint: tunnel), .migrated)
    }

    func testTailnetIP8642Migrates() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://100.127.200.89:8642", defaultEndpoint: tunnel), .migrated)
    }

    func testTailnetIP9119Migrates() {
        // F1-era direct spelling — its ATS exception is stripped, so leaving
        // it would silently fail ATS on device.
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://100.127.200.89:9119", defaultEndpoint: tunnel), .migrated)
    }

    func testMagicDNSHostMigrates() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://node-a.tailnet-example.ts.net", defaultEndpoint: tunnel), .migrated)
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://node-a.tailnet-example.ts.net:9119", defaultEndpoint: tunnel), .migrated)
    }

    func testLoopbackMigrates() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://127.0.0.1:8642", defaultEndpoint: tunnel), .migrated)
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://localhost:8642", defaultEndpoint: tunnel), .migrated)
    }

    func testCaseInsensitiveHost() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: "http://NODE-A.TAILNET-EXAMPLE.TS.NET:9119", defaultEndpoint: tunnel), .migrated)
    }

    // MARK: idempotence + unknown rows

    func testAlreadyCurrentIsIdempotent() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: tunnel, defaultEndpoint: tunnel), .alreadyCurrent)
        XCTAssertEqual(EndpointMigration.classify(endpoint: "https://gateway.example.net:443", defaultEndpoint: tunnel), .alreadyCurrent)
    }

    func testUnknownHostUntouched() {
        // A PUBLIC gateway the user configured must survive verbatim.
        XCTAssertEqual(EndpointMigration.classify(endpoint: "https://other.example.com:9119", defaultEndpoint: tunnel), .untouched)
    }

    func testUnparseableEndpointUntouched() {
        XCTAssertEqual(EndpointMigration.classify(endpoint: "not a url", defaultEndpoint: tunnel), .untouched)
        XCTAssertEqual(EndpointMigration.classify(endpoint: "", defaultEndpoint: tunnel), .untouched)
    }

    // MARK: the record mapping

    func testMigrateEndpointsRewritesOnlyDeadRows() {
        let records = [
            record("http://100.127.200.89:8642", id: "gw-relay"),
            record("https://other.example.com:9119", id: "other-gateway"),
            record(tunnel, id: "already"),
        ]
        let migrated = EndpointMigration.migrateEndpoints(in: records, defaultEndpoint: tunnel)
        XCTAssertEqual(migrated[0].endpoint, tunnel)
        XCTAssertEqual(migrated[1].endpoint, "https://other.example.com:9119", "public hosts must survive verbatim")
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
        let records = [record("http://192.168.50.20:8642")]
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

    // MARK: the dead-host classification itself

    func testDeadHostClassificationCarriesNoLiveTopology() {
        // Dead classification is SHAPE-based (private/loopback/CGNAT/ts.net).
        // Guards: no LIVE endpoint is compiled in (the classifier never marks
        // a public host dead), and every historical spelling shape is caught.
        for host in ["192.168.50.20", "100.127.200.89", "node-a.tailnet-example.ts.net",
                     "127.0.0.1", "localhost", "100.100.200.61"] {
            XCTAssertTrue(EndpointMigration.isDeadHost(host), "historical shape must classify dead: \(host)")
        }
        for host in ["gateway.example.net", "example.com", "1.1.1.1"] {
            XCTAssertFalse(EndpointMigration.isDeadHost(host), "public host must NEVER classify dead: \(host)")
        }
    }

    func testCGNATRangeBoundaries() {
        XCTAssertTrue(EndpointMigration.isDeadHost("100.64.0.1"), "100.64/10 start is CGNAT")
        XCTAssertTrue(EndpointMigration.isDeadHost("100.127.255.254"), "100.64/10 end is CGNAT")
        XCTAssertFalse(EndpointMigration.isDeadHost("100.63.255.255"), "just below CGNAT is not dead")
        XCTAssertFalse(EndpointMigration.isDeadHost("100.128.0.1"), "just above CGNAT is not dead")
    }

    // MARK: strict CGNAT IPv4 parsing (Issue #2 review: all four octets)

    func testCGNATParserRequiresStrictIPv4Everywhere() {
        // Numeric-looking HOSTNAMES must never classify as CGNAT — the
        // parser validates every octet, not just the first two.
        for host in ["100.64.gateway.example",
                     "100.64.1.example",
                     "100.64.999.1",            // octet > 255
                     "100.64.-1.1",             // sign
                     "100.64.+1.1",             // sign
                     "100.64.01.1",              // leading zero (non-canonical)
                     "100.64.1.1.1",             // five octets
                     "100.64.1",                 // three octets
                     "100.64..1",                // empty octet
                     "100.64.1.",                // trailing dot = empty octet
                     ".64.1.1",                  // leading dot = empty octet
                     ""] {
            XCTAssertFalse(EndpointMigration.isDeadHost(host),
                           "malformed host must not classify CGNAT-dead: \(host)")
        }
    }

    func testCGNATParserAcceptsValidInRangeAddresses() {
        for host in ["100.64.0.1", "100.127.255.254", "100.64.255.255",
                     "100.100.1.1", "100.127.0.0"] {
            XCTAssertTrue(EndpointMigration.isDeadHost(host),
                           "valid in-range CGNAT address must classify dead (legacy migration scope): \(host)")
        }
        // Valid IPv4 outside the range must not classify dead.
        for host in ["100.63.255.255", "100.128.0.1", "101.64.0.1", "8.8.8.8"] {
            XCTAssertFalse(EndpointMigration.isDeadHost(host), "out-of-range address must not classify dead: \(host)")
        }
    }
}
