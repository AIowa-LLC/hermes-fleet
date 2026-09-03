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
            id: "<tailnet-ip>:8642",
            displayName: "Arch Lab",
            endpoint: "http://<tailnet-ip>:8642",
            authConfiguration: GatewayAuthConfiguration(strategy: .usernamePassword, credentialStored: true),
            authConfigured: true
        ))

        // The launch-env override drives the default endpoint in tests.
        setenv("HERMES_FLEET_DEFAULT_ENDPOINT", tunnel, 1)
        defer { unsetenv("HERMES_FLEET_DEFAULT_ENDPOINT") }

        let service = makeService(records: records)
        let restored = try await service.restorePersistedGateways()

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].endpoint, URL(string: tunnel))
        XCTAssertEqual(restored[0].id, GatewayID(rawValue: "<tailnet-ip>:8642"),
                       "identity must be preserved through migration")
        let stored = try await records.loadGatewayRecords()
        XCTAssertEqual(stored[0].endpoint, tunnel, "migration must write through to the store")
    }

    /// Migration is idempotent: a restore over an already-converged store
    /// writes nothing and re-registers the same row.
    func testRestoreMigrationIsIdempotent() async throws {
        let records = TestRecordStore()
        try await records.saveGatewayRecord(StoredGatewayRecord(
            id: "arch", displayName: "Arch Lab", endpoint: tunnel
        ))
        setenv("HERMES_FLEET_DEFAULT_ENDPOINT", tunnel, 1)
        defer { unsetenv("HERMES_FLEET_DEFAULT_ENDPOINT") }

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
            id: "arch", displayName: "Arch Lab", endpoint: "http://127.0.0.1:8642"
        ))
        unsetenv("HERMES_FLEET_DEFAULT_ENDPOINT")
        // Ensure the plist layer cannot leak the app's configured default
        // into a package test (Bundle.main here is the test runner, but be
        // explicit).
        let service = makeService(records: records)
        let restored = try await service.restorePersistedGateways()
        XCTAssertEqual(restored[0].endpoint, URL(string: "http://127.0.0.1:8642"))
        let stored = try await records.loadGatewayRecords()
        XCTAssertEqual(stored[0].endpoint, "http://127.0.0.1:8642")
    }
}
