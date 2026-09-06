import XCTest
import os
import FleetCore
@testable import FleetNetworking

/// F2 (t_b678fb38) — persisted-row convergence through the registry's
/// restore path.
///
/// The QA gate-1 contract: a persisted row at a dead spelling migrates to
/// the configured default endpoint over the store, before the registry
/// rebuild — so the app (and the UI) only ever sees the converged endpoint,
/// and a relaunch of the migrated store is a no-op (idempotent).
final class GatewayEndpointMigrationTests: XCTestCase {

    private final class TestRecordStore: GatewayRecordStoring, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[String: StoredGatewayRecord]>(initialState: [:])
        func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {
            lock.withLock { $0[record.id] = record }
        }
        func deleteGatewayRecord(id: GatewayID) async throws {
            lock.withLock { $0.removeValue(forKey: id.rawValue) }
        }
        func loadGatewayRecords() async throws -> [StoredGatewayRecord] {
            lock.withLock { $0.values.sorted { $0.id < $1.id } }
        }
    }

    /// In-memory credential store (M0 boundary: no FleetSecurity import).
    private final class TestCredentialStore: CredentialStoring, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[String: GatewayCredential]>(initialState: [:])
        func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
            lock.withLock { $0[gatewayID.rawValue] = credential }
        }
        func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
            lock.withLock { $0[gatewayID.rawValue] }
        }
        func deleteCredential(for gatewayID: GatewayID) async throws {
            lock.withLock { $0.removeValue(forKey: gatewayID.rawValue) }
        }
    }

    private func makeService(records: TestRecordStore) -> GatewayRegistryService {
        GatewayRegistryService(
            credentials: TestCredentialStore(),
            connectionFactory: { gateway, _ in
                OfflineStub(gatewayID: gateway.id)
            },
            recordStore: records
        )
    }

    private final class OfflineStub: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws { throw GatewayConnectivityError.unreachable }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
    }

    private let tunnel = "https://fleet.example.dev"

    /// QA gate 1: persisted dead-spelling row migrates to the default
    /// endpoint through `restorePersistedGateways()` — in the registry AND
    /// written back to the store.
    func testRestoreMigratesDeadSpellingToDefault() async throws {
        let records = TestRecordStore()
        try await records.saveGatewayRecord(StoredGatewayRecord(
            id: "100.127.200.89:8642",
            displayName: "Lab Node",
            endpoint: "http://100.127.200.89:8642",
            authConfiguration: GatewayAuthConfiguration(strategy: .usernamePassword, credentialStored: true),
            authConfigured: true
        ))

        // Legacy migration lane: target AND explicit opt-in flag both set
        // (Issue #2 review: a default endpoint alone must never migrate).
        setenv("HERMES_FLEET_DEFAULT_ENDPOINT", tunnel, 1)
        setenv("HERMES_FLEET_LEGACY_MIGRATION", "1", 1)
        defer {
            unsetenv("HERMES_FLEET_DEFAULT_ENDPOINT")
            unsetenv("HERMES_FLEET_LEGACY_MIGRATION")
        }

        let service = makeService(records: records)
        let restored = try await service.restorePersistedGateways()

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].endpoint, URL(string: tunnel))
        XCTAssertEqual(restored[0].id, GatewayID(rawValue: "100.127.200.89:8642"),
                       "identity must be preserved through migration")
        let stored = try await records.loadGatewayRecords()
        XCTAssertEqual(stored[0].endpoint, tunnel, "migration must write through to the store")
    }

    /// Migration is idempotent: a restore over an already-converged store
    /// writes nothing and re-registers the same row.
    func testRestoreMigrationIsIdempotent() async throws {
        let records = TestRecordStore()
        try await records.saveGatewayRecord(StoredGatewayRecord(
            id: "arch", displayName: "Lab Node", endpoint: tunnel
        ))
        setenv("HERMES_FLEET_DEFAULT_ENDPOINT", tunnel, 1)
        setenv("HERMES_FLEET_LEGACY_MIGRATION", "1", 1)
        defer {
            unsetenv("HERMES_FLEET_DEFAULT_ENDPOINT")
            unsetenv("HERMES_FLEET_LEGACY_MIGRATION")
        }

        let first = makeService(records: records)
        _ = try await first.restorePersistedGateways()
        let second = makeService(records: records)
        let restored = try await second.restorePersistedGateways()

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].endpoint, URL(string: tunnel))
        let stored = try await records.loadGatewayRecords()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].endpoint, tunnel)
    }

    /// No configured default → no migration: rows pass through as-is.
    func testNoDefaultEndpointLeavesRowsVerbatim() async throws {
        let records = TestRecordStore()
        try await records.saveGatewayRecord(StoredGatewayRecord(
            id: "arch", displayName: "Lab Node", endpoint: "http://127.0.0.1:8642"
        ))
        unsetenv("HERMES_FLEET_DEFAULT_ENDPOINT")
        unsetenv("HERMES_FLEET_LEGACY_MIGRATION")
        // Ensure the plist layer cannot leak the app's configured default
        // into a package test (Bundle.main here is the test runner, but be
        // explicit).
        let service = makeService(records: records)
        let restored = try await service.restorePersistedGateways()
        XCTAssertEqual(restored[0].endpoint, URL(string: "http://127.0.0.1:8642"))
        let stored = try await records.loadGatewayRecords()
        XCTAssertEqual(stored[0].endpoint, "http://127.0.0.1:8642")
    }

    // MARK: Issue #2 review — private user gateways survive by default

    /// A configured default endpoint ALONE must NOT migrate anything:
    /// ordinary users persist LAN/tailnet/loopback gateways intentionally,
    /// and Hermes Fleet explicitly supports them. Migration requires the
    /// explicit legacy opt-in flag.
    func testConfiguredDefaultAloneNeverMigratesPrivateRows() async throws {
        let cases: [(String, String)] = [
            ("lan-user", "http://192.168.50.10:9119"),            // RFC1918 user gateway
            ("tailnet-user", "http://100.100.200.61:9120"),       // CGNAT/tailnet user gateway
            ("magicdns-user", "https://node-b.tailnet-example.ts.net:9119"),
            ("loopback-user", "http://127.0.0.1:9119"),
            ("public-user", "https://gateway.example.net"),
        ]
        for (id, endpoint) in cases {
            let records = TestRecordStore()
            try await records.saveGatewayRecord(StoredGatewayRecord(
                id: id, displayName: "User Gateway", endpoint: endpoint
            ))
            setenv("HERMES_FLEET_DEFAULT_ENDPOINT", tunnel, 1)
            unsetenv("HERMES_FLEET_LEGACY_MIGRATION")
            defer { unsetenv("HERMES_FLEET_DEFAULT_ENDPOINT") }

            let service = makeService(records: records)
            let restored = try await service.restorePersistedGateways()
            XCTAssertEqual(restored.count, 1)
            XCTAssertEqual(restored[0].endpoint, URL(string: endpoint),
                           "default endpoint alone must NEVER rewrite a user gateway (\(id))")
            let stored = try await records.loadGatewayRecords()
            XCTAssertEqual(stored[0].endpoint, endpoint,
                           "store must remain untouched without the legacy opt-in (\(id))")
        }
    }

    /// With the legacy opt-in explicitly enabled, legacy private shapes
    /// migrate onto the target and public rows survive — the deliberate
    /// one-time legacy convergence lane.
    func testExplicitLegacyOptInMigratesPrivateShapesOnly() async throws {
        let legacyRow = StoredGatewayRecord(
            id: "legacy-lan", displayName: "Legacy Lab", endpoint: "http://192.168.50.20:8642"
        )
        let tailnetRow = StoredGatewayRecord(
            id: "legacy-tailnet", displayName: "Legacy Tailnet", endpoint: "http://100.127.200.89:8642"
        )
        let publicRow = StoredGatewayRecord(
            id: "public-user", displayName: "User Gateway", endpoint: "https://gateway.example.net"
        )
        let records = TestRecordStore()
        for row in [legacyRow, tailnetRow, publicRow] {
            try await records.saveGatewayRecord(row)
        }
        setenv("HERMES_FLEET_DEFAULT_ENDPOINT", tunnel, 1)
        setenv("HERMES_FLEET_LEGACY_MIGRATION", "1", 1)
        defer {
            unsetenv("HERMES_FLEET_DEFAULT_ENDPOINT")
            unsetenv("HERMES_FLEET_LEGACY_MIGRATION")
        }

        let service = makeService(records: records)
        let restored = try await service.restorePersistedGateways()
        let byID = Dictionary(uniqueKeysWithValues: restored.map { ($0.id.rawValue, $0) })
        XCTAssertEqual(byID["legacy-lan"]?.endpoint, URL(string: tunnel),
                       "legacy private row migrates under explicit opt-in")
        XCTAssertEqual(byID["legacy-tailnet"]?.endpoint, URL(string: tunnel),
                       "legacy tailnet row migrates under explicit opt-in")
        XCTAssertEqual(byID["public-user"]?.endpoint, URL(string: "https://gateway.example.net"),
                       "public user row survives even under legacy opt-in")
        let stored = try await records.loadGatewayRecords()
        let storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        XCTAssertEqual(storedByID["public-user"]?.endpoint, "https://gateway.example.net")
        XCTAssertEqual(storedByID["legacy-lan"]?.endpoint, tunnel, "write-through verified")
    }
}
