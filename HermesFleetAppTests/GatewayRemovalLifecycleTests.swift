import XCTest
import os
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
@testable import FleetUI

/// Deleted-gateway resurrection (Dev build 6). An explicit Remove is a
/// durable user decision: no late asynchronous result (an in-flight roster
/// refresh, an in-flight connect, a foreground restore) may bring the gateway,
/// its bots, or its connection intent back, in memory or after relaunch, and
/// removing one gateway must not disturb its neighbours. Synthetic fixtures
/// only; every race is driven deterministically with gates.
@MainActor
final class GatewayRemovalLifecycleTests: XCTestCase {
    private let removed = GatewayID(rawValue: "gw-removed")
    private let kept = GatewayID(rawValue: "gw-kept")

    // MARK: Doubles

    /// One-shot async gate with a bounded wait so a regression fails instead
    /// of hanging the suite.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = 0

        func wait() async {
            entered += 1
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func waitUntilEntered() async -> Bool {
            for _ in 0..<400 {
                if entered > 0 { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
    }

    private final class Connection: GatewayConnectivityProviding, @unchecked Sendable {
        let gatewayID: GatewayID
        let connectGate: Gate?
        let disconnectGate: Gate?
        private let counters = OSAllocatedUnfairLock(initialState: (connects: 0, disconnects: 0))

        init(gatewayID: GatewayID, connectGate: Gate? = nil, disconnectGate: Gate? = nil) {
            self.gatewayID = gatewayID
            self.connectGate = connectGate
            self.disconnectGate = disconnectGate
        }

        var connectCount: Int { counters.withLock { $0.connects } }
        var disconnectCount: Int { counters.withLock { $0.disconnects } }
        var status: GatewayStatus { .online }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {
            counters.withLock { $0.connects += 1 }
            if let connectGate { await connectGate.wait() }
        }
        func disconnect() async {
            counters.withLock { $0.disconnects += 1 }
            if let disconnectGate { await disconnectGate.wait() }
        }
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
    }

    private struct RosterSession: GatewayRosterSession {
        let gatewayID: GatewayID
        let profilesGate: Gate?
        var status: GatewayStatus { .online }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] {
            if let profilesGate { await profilesGate.wait() }
            return [ProfileDescriptor(
                name: "default", path: "~/profiles/default", isDefault: true,
                model: "model", provider: "provider", displayName: "Default",
                skillCount: 1, hasAvatar: false)]
        }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private struct EmptySessions: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private struct Health: ConnectionHealthAccumulating {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    /// Durable gateway records shared across "launches"; can be told to fail
    /// deletes so persistence errors are exercised.
    private final class RecordStore: GatewayRecordStoring, @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(
            initialState: (records: [String: StoredGatewayRecord](), failDeletes: false))

        var failDeletes: Bool {
            get { state.withLock { $0.failDeletes } }
            set { state.withLock { $0.failDeletes = newValue } }
        }
        func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {
            state.withLock { $0.records[record.id] = record }
        }
        func deleteGatewayRecord(id: GatewayID) async throws {
            if failDeletes { throw CacheStoreError.storeUnavailable("scripted delete failure") }
            state.withLock { _ = $0.records.removeValue(forKey: id.rawValue) }
        }
        func loadGatewayRecords() async throws -> [StoredGatewayRecord] {
            state.withLock { $0.records.values.sorted { $0.id < $1.id } }
        }
    }

    /// Everything that survives a force-quit.
    private struct Durable {
        let records = RecordStore()
        let credentials = InMemoryCredentialStore()
        let removalLedger: any GatewayRemovalLedgering = InMemoryGatewayRemovalLedger()
        let defaults: UserDefaults
        let launchCache = InMemoryLaunchCache()

        init() {
            let suite = "fleet.removal.lifecycle.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private struct Harness {
        let environment: AppEnvironment
        let connections: [GatewayID: Connection]
        /// Credential saves also run the invalidator hook, so the gate only
        /// closes once the test has finished its setup.
        let armInvalidator: @Sendable () -> Void
    }

    private func makeHarness(
        _ durable: Durable,
        connectGates: [GatewayID: Gate] = [:],
        disconnectGates: [GatewayID: Gate] = [:],
        rosterGates: [GatewayID: Gate] = [:],
        invalidatorGate: Gate? = nil
    ) -> Harness {
        let armed = OSAllocatedUnfairLock(initialState: false)
        var connections: [GatewayID: Connection] = [:]
        for id in [removed, kept] {
            connections[id] = Connection(
                gatewayID: id, connectGate: connectGates[id], disconnectGate: disconnectGates[id])
        }
        let frozen = connections
        let registry = GatewayRegistryService(
            credentials: durable.credentials,
            connectionFactory: { gateway, _ in frozen[gateway.id] ?? Connection(gatewayID: gateway.id) },
            recordStore: durable.records,
            removalLedger: durable.removalLedger)
        let roster = FleetRosterService(
            registry: registry,
            credentials: durable.credentials,
            sessionFactory: { gateway, _ in
                RosterSession(gatewayID: gateway.id, profilesGate: rosterGates[gateway.id])
            })
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: EmptySessions(),
            connectionFactory: { gateway, _ in frozen[gateway.id] ?? Connection(gatewayID: gateway.id) },
            health: Health(),
            connectionIntentDefaults: durable.defaults,
            gatewaySessionInvalidator: { _ in
                if armed.withLock({ $0 }), let invalidatorGate { await invalidatorGate.wait() }
            },
            launchCache: durable.launchCache)
        environment.attachContinueIndex(FleetContinueIndexStore(url: tempURL()))
        environment.attachArtifactLibrary(FleetArtifactLibrary(url: tempURL()))
        environment.attachConversationDrafts(ConversationDraftStore(url: tempURL()))
        return Harness(
            environment: environment, connections: frozen,
            armInvalidator: { armed.withLock { $0 = true } })
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-removal-\(UUID().uuidString).json")
    }

    private func addBoth(_ environment: AppEnvironment) async throws {
        for id in [removed, kept] {
            _ = try await environment.addGateway(GatewayRegistration(
                id: id, displayName: "Gateway \(id.rawValue)",
                endpoint: URL(string: "http://127.0.0.1:8642")!))
            try await environment.saveCredential(GatewayCredential(rawValue: "token-\(id.rawValue)"), for: id)
        }
    }

    // MARK: Late async results

    /// A roster refresh that was already in flight when the user removed the
    /// gateway must not put the gateway (or its ghost bots) back on the Fleet
    /// screen: the Fleet sections are built straight from the snapshot.
    func testRefreshInFlightDuringRemovalDoesNotRestoreRemovedGateway() async throws {
        let durable = Durable()
        let gate = Gate()
        let harness = makeHarness(durable, rosterGates: [removed: gate])
        let environment = harness.environment
        try await addBoth(environment)
        await environment.load()

        let refresh = Task { await environment.refreshRoster() }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered, "the refresh must be mid-flight on the removed gateway")

        try await environment.removeGateway(removed)
        await gate.open()
        await refresh.value

        XCTAssertEqual(environment.gateways.map(\.id), [kept])
        let snapshot = try XCTUnwrap(environment.rosterSnapshot)
        XCTAssertEqual(snapshot.roster.allGateways.map(\.id), [kept],
                       "a stale refresh must not reintroduce the removed gateway")
        XCTAssertNil(snapshot.outcome(for: removed))
        XCTAssertTrue(environment.bots(on: removed).isEmpty)
        XCTAssertNil(environment.cachedBotsByGateway[removed],
                     "no ghost bots may be cached for a removed gateway")
        XCTAssertEqual(environment.bots(on: kept).count, 1, "the neighbour's roster is unaffected")
        let cachedRosters = try await durable.launchCache.loadRosterCache()
        XCTAssertFalse(cachedRosters.contains { $0.gatewayID == removed },
                       "the launch cache must not regain the removed gateway")
    }

    /// A connect that completes after the gateway was removed must not
    /// recreate connection state, intent, or a live transport for it.
    func testConnectInFlightDuringRemovalLeavesNoStateOrIntent() async throws {
        let durable = Durable()
        let gate = Gate()
        let harness = makeHarness(durable, connectGates: [removed: gate])
        let environment = harness.environment
        try await addBoth(environment)
        await environment.load()
        await environment.connect(to: kept)

        let connect = Task { await environment.connect(to: removed) }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered, "the connect must be mid-flight on the removed gateway")

        try await environment.removeGateway(removed)
        await gate.open()
        await connect.value

        XCTAssertNil(environment.connectionStates[removed],
                     "a late connect result must not recreate lifecycle state")
        XCTAssertFalse(environment.isConnectionIntended(removed))
        XCTAssertFalse(
            (durable.defaults.stringArray(forKey: ConnectionIntentStore.defaultsKey) ?? [])
                .contains(removed.rawValue),
            "the persisted connect intent must not name a removed gateway")
        XCTAssertGreaterThanOrEqual(harness.connections[removed]?.disconnectCount ?? 0, 1,
                                    "the late transport must be torn down")

        await environment.restoreIntendedConnections()
        XCTAssertEqual(harness.connections[removed]?.connectCount, 1,
                       "a foreground restore must never reconnect a removed gateway")
        XCTAssertEqual(environment.connectionStates[kept], .connected, "the neighbour stays connected")
        XCTAssertTrue(environment.isConnectionIntended(kept))
    }

    /// A connect requested while the removal is still tearing down (the
    /// registry already forgot the gateway, the observable list has not caught
    /// up yet) must be refused, not revive intent, state, or a transport.
    func testConnectRequestedDuringRemovalTeardownIsRefused() async throws {
        let durable = Durable()
        let teardown = Gate()
        let harness = makeHarness(durable, invalidatorGate: teardown)
        let environment = harness.environment
        try await addBoth(environment)
        await environment.load()
        harness.armInvalidator()

        let removal = Task { try await environment.removeGateway(removed) }
        let entered = await teardown.waitUntilEntered()
        XCTAssertTrue(entered, "removal must be parked mid-teardown")

        await environment.connect(to: removed)
        await environment.restoreIntendedConnections()
        await teardown.open()
        try await removal.value

        XCTAssertEqual(harness.connections[removed]?.connectCount, 0,
                       "no connect may start for a gateway that is being removed")
        XCTAssertFalse(environment.isConnectionIntended(removed))
        XCTAssertNil(environment.connectionStates[removed])
        XCTAssertEqual(environment.gateways.map(\.id), [kept])
    }

    // MARK: Durability

    /// Removal survives refresh, foreground restore, and a relaunch over the
    /// same durable stores, while the neighbour keeps its record, credential
    /// and connect intent.
    func testRemovedGatewayStaysRemovedAcrossRefreshForegroundAndRelaunch() async throws {
        let durable = Durable()
        let first = makeHarness(durable).environment
        try await addBoth(first)
        await first.load()
        await first.connect(to: kept)
        try await first.removeGateway(removed)

        await first.refreshRoster()
        await first.restoreIntendedConnections()
        XCTAssertEqual(first.gateways.map(\.id), [kept])

        // Force-quit: a brand-new runtime over the same stores.
        let second = makeHarness(durable).environment
        await second.load()
        await second.refreshRoster()
        await second.restoreIntendedConnections()

        XCTAssertEqual(second.gateways.map(\.id), [kept], "removal must survive relaunch")
        XCTAssertNil(second.rosterSnapshot?.outcome(for: removed))
        let removedCredential = await second.hasCredential(for: removed)
        let keptCredential = await second.hasCredential(for: kept)
        XCTAssertFalse(removedCredential, "the removed gateway's credential is gone")
        XCTAssertTrue(keptCredential, "the neighbour's credential is untouched")
        XCTAssertEqual(second.connectionStates[kept], .connected,
                       "the neighbour's saved connect intent still restores it")
        let stored = try await durable.records.loadGatewayRecords()
        XCTAssertEqual(stored.map(\.id), [kept.rawValue])
    }

    /// Disconnect is transport control; Remove is deletion. After a relaunch a
    /// disconnected gateway is still listed (but not auto-connected) and a
    /// removed one is gone.
    func testDisconnectKeepsGatewayWhileRemoveDeletesIt() async throws {
        let durable = Durable()
        let first = makeHarness(durable).environment
        try await addBoth(first)
        await first.load()
        await first.connect(to: removed)
        await first.connect(to: kept)

        await first.disconnect(from: kept)
        XCTAssertEqual(first.gateways.count, 2, "Disconnect never removes a gateway")
        try await first.removeGateway(removed)

        let second = makeHarness(durable)
        await second.environment.load()
        await second.environment.restoreIntendedConnections()

        XCTAssertEqual(second.environment.gateways.map(\.id), [kept])
        let keptCredential = await second.environment.hasCredential(for: kept)
        XCTAssertTrue(keptCredential, "Disconnect keeps the credential")
        XCTAssertFalse(second.environment.isConnectionIntended(kept))
        XCTAssertEqual(second.connections[kept]?.connectCount, 0,
                       "an explicitly disconnected gateway is not auto-connected")
    }

    /// If the removal cannot be made durable the user is told, and the gateway
    /// stays listed (no success is claimed); a relaunch agrees with the UI.
    func testRemovalPersistenceFailureIsReportedAndGatewayStaysListed() async throws {
        let durable = Durable()
        let first = makeHarness(durable).environment
        try await addBoth(first)
        await first.load()

        durable.records.failDeletes = true
        do {
            try await first.removeGateway(removed)
            XCTFail("a removal that could not be persisted must throw")
        } catch let error as GatewayRegistryError {
            guard case .recordStoreFailed = error else {
                return XCTFail("expected recordStoreFailed, got \(error)")
            }
        }
        XCTAssertEqual(Set(first.gateways.map(\.id)), [removed, kept],
                       "a failed removal must not claim success")

        let second = makeHarness(durable).environment
        await second.load()
        XCTAssertEqual(Set(second.gateways.map(\.id)), [removed, kept],
                       "the relaunch agrees with what the failed removal told the user")
    }
}
