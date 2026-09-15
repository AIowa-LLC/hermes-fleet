import XCTest
import FleetCore
import FleetNetworking
import FleetPersistence
import FleetSecurity
import FleetUI

@MainActor
final class GatewaySessionInvalidationTests: XCTestCase {
    private actor InvalidationSpy {
        private(set) var invalidated: [GatewayID] = []
        private(set) var invalidateAllCount = 0
        func invalidate(_ id: GatewayID) { invalidated.append(id) }
        func invalidateAll() { invalidateAllCount += 1 }
        func count(for id: GatewayID) -> Int { invalidated.filter { $0 == id }.count }
    }

    private struct EmptyRoster: FleetRosterProviding {
        func refreshRoster() async -> FleetRosterSnapshot { FleetRosterSnapshot() }
    }

    private struct EmptySessions: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private struct EmptyHealth: ConnectionHealthAccumulating {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    private func makeEnvironment(spy: InvalidationSpy) async -> (AppEnvironment, GatewayID) {
        let id = GatewayID(rawValue: "workstation")
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                GatewayTestConnection(gatewayID: gateway.id)
            })
        let environment = AppEnvironment(
            registry: registry,
            roster: EmptyRoster(),
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: EmptySessions(),
            connectionFactory: { gateway, _ in GatewayTestConnection(gatewayID: gateway.id) },
            health: EmptyHealth(),
            seedRegistrations: [GatewayRegistration(
                id: id, displayName: "Workstation",
                endpoint: URL(string: "http://127.0.0.1:9000")!)],
            gatewaySessionInvalidator: { gatewayID in await spy.invalidate(gatewayID) },
            gatewaySessionInvalidatorAll: { await spy.invalidateAll() })
        await environment.load()
        return (environment, id)
    }

    func testCredentialAndEndpointChangesInvalidateGatewayLease() async throws {
        let spy = InvalidationSpy()
        let (environment, id) = await makeEnvironment(spy: spy)
        try await environment.saveCredential(
            GatewayCredential(rawValue: "pw", username: "tony"), for: id)
        try await environment.clearCredential(for: id)
        _ = try await environment.updateGateway(
            id,
            edits: GatewayEdit(endpoint: URL(string: "http://127.0.0.1:9001")))
        let invalidationCount = await spy.count(for: id)
        XCTAssertEqual(invalidationCount, 3)
    }

    func testGatewayDeletionInvalidatesLeaseAndCacheClearInvalidatesAll() async throws {
        let spy = InvalidationSpy()
        let (environment, id) = await makeEnvironment(spy: spy)
        try await environment.removeGateway(id)
        let deletionCount = await spy.count(for: id)
        XCTAssertEqual(deletionCount, 1)

        // The invalidation is deliberately separate from transport disconnect:
        // local-cache deletion is the explicit privacy boundary for all
        // ephemeral authenticated sessions.
        try await environment.clearLocalCache()
        let allCount = await spy.invalidateAllCount
        XCTAssertEqual(allCount, 1)
    }

    private struct GatewayTestConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
    }
}
