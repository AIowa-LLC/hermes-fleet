import XCTest
import os
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

/// P0-4 (t_e32529e8): gateway persistence across relaunch, at the
/// AppEnvironment runtime level. A gateway added in "session 1"
/// (persist-on-Add, write-through) must still be listed after a relaunch
/// ("session 2" = fresh registry over the SAME record store), marked idle —
/// never-connected entries included.
@MainActor
final class GatewayPersistenceRelaunchTests: XCTestCase {

    // MARK: fixtures

    private struct OfflineConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {
            throw GatewayConnectivityError.connectionFailed("scripted offline")
        }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
    }

    private struct TestRosterSession: GatewayRosterSession {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] { [] }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private struct TestSessionList: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private struct TestHealthAccumulator: ConnectionHealthAccumulating {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    /// In-memory GatewayRecordStoring shared across the two "sessions".
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

    private func makeEnvironment(
        registry: any GatewayRegistryManaging,
        seedRegistrations: [GatewayRegistration] = []
    ) -> AppEnvironment {
        AppEnvironment(
            registry: registry,
            roster: FleetRosterService(
                registry: registry,
                credentials: InMemoryCredentialStore(),
                sessionFactory: { gateway, _ in
                    TestRosterSession(gatewayID: gateway.id)
                }
            ),
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                OfflineConnection(gatewayID: gateway.id)
            },
            health: TestHealthAccumulator(),
            seedRegistrations: seedRegistrations
        )
    }

    private let dogfoodEndpoint = URL(string: "http://100.100.200.61:9120")!
    private let dogfoodID = GatewayID(rawValue: "100.100.200.61:9120")

    // MARK: the P0-4 acceptance

    func testGatewaySurvivesRelaunchThroughRecordStore() async throws {
        let records = TestRecordStore()
        let credentials = InMemoryCredentialStore()

        // Session 1: add a gateway through the runtime (persist-on-Add).
        let registry1 = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in OfflineConnection(gatewayID: gateway.id) },
            recordStore: records
        )
        let env1 = makeEnvironment(registry: registry1)
        let added = try await env1.addGateway(GatewayRegistration(
            displayName: "Lab Node",
            endpoint: dogfoodEndpoint,
            authConfiguration: GatewayAuthConfiguration(strategy: .usernamePassword, credentialStored: false)
        ))
        try await env1.saveCredential(
            GatewayCredential(rawValue: "user:fake-low-entropy-pw"),
            for: added.id
        )
        XCTAssertEqual(env1.gateways.count, 1)

        // Session 2 (relaunch): fresh registry + runtime over the SAME store.
        let registry2 = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in OfflineConnection(gatewayID: gateway.id) },
            recordStore: records
        )
        let env2 = makeEnvironment(registry: registry2)
        await env2.load()

        XCTAssertEqual(env2.gateways.map(\.id), [dogfoodID], "gateway must survive relaunch")
        XCTAssertEqual(env2.gateways.first?.displayName, "Lab Node")
        XCTAssertEqual(env2.gateways.first?.endpoint, dogfoodEndpoint)
        XCTAssertEqual(
            env2.connectionStates[dogfoodID], .idle,
            "restored gateway starts idle (never connected this session)"
        )
        let hasCred = await env2.hasCredential(for: dogfoodID)
        XCTAssertTrue(hasCred, "stored credential must survive relaunch")
    }

    /// Restore must run BEFORE seeding so a restored user fleet is never
    /// re-seeded (mirrors the existing never-override-seed contract).
    func testRestoredFleetSuppressesSeeding() async throws {
        let records = TestRecordStore()
        try await records.saveGatewayRecord(StoredGatewayRecord(
            id: dogfoodID.rawValue,
            displayName: "Lab Node",
            endpoint: dogfoodEndpoint.absoluteString
        ))

        let registry = GatewayRegistryService(
            credentials: InMemoryCredentialStore(),
            connectionFactory: { gateway, _ in OfflineConnection(gatewayID: gateway.id) },
            recordStore: records
        )
        let env = makeEnvironment(
            registry: registry,
            seedRegistrations: [GatewayRegistration(
                id: GatewayID(rawValue: "seed-macbook"),
                displayName: "MacBook",
                endpoint: URL(string: "http://127.0.0.1:8642")!
            )]
        )

        await env.load()

        XCTAssertEqual(
            env.gateways.map(\.id.rawValue), [dogfoodID.rawValue],
            "restored user fleet must suppress seeding"
        )
    }

    /// A broken record store must not brick launch: load() logs and continues
    /// with the (empty) in-memory registry.
    func testLoadToleratesBrokenRecordStore() async throws {
        struct BrokenRecordStore: GatewayRecordStoring {
            func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {
                throw CacheStoreError.storeUnavailable("broken")
            }
            func deleteGatewayRecord(id: GatewayID) async throws {
                throw CacheStoreError.storeUnavailable("broken")
            }
            func loadGatewayRecords() async throws -> [StoredGatewayRecord] {
                throw CacheStoreError.storeUnavailable("broken")
            }
        }

        let registry = GatewayRegistryService(
            credentials: InMemoryCredentialStore(),
            connectionFactory: { gateway, _ in OfflineConnection(gatewayID: gateway.id) },
            recordStore: BrokenRecordStore()
        )
        let env = makeEnvironment(registry: registry)
        await env.load()
        XCTAssertEqual(env.gateways.count, 0, "broken store must not brick launch")
    }
}
