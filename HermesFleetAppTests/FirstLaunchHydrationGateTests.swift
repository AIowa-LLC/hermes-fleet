import XCTest
import os
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

/// Build-88 first-run gate invariant: `AppEnvironment.hydrationPhase` may
/// settle `.unconfigured` ONLY after the durable gateway record store has
/// ANSWERED for this launch. An unresolved durable read must hold `.loading`
/// (never render the setup surface), a transiently failing read must heal via
/// bounded IMMEDIATE retries, and a definitively broken store must hold
/// `.loading` instead of misreporting the fleet as empty.
///
/// Every test asserts the exact invariant: any `.unconfigured` observed while
/// durable restoration was unresolved fails the test. Fixtures mirror
/// `GatewayPersistenceRelaunchTests` (same store/environment construction).
@MainActor
final class FirstLaunchHydrationGateTests: XCTestCase {

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

    /// Durable record-store double for the hydration-gate invariant: counts
    /// durable reads, fails a configurable number of LEADING reads, and samples
    /// the live `AppEnvironment.hydrationPhase` from INSIDE
    /// `loadGatewayRecords()` — the exact window the invariant governs (the
    /// durable store answering for this launch).
    private final class ProbeRecordStore: GatewayRecordStoring, @unchecked Sendable {
        private struct State {
            var records: [String: StoredGatewayRecord] = [:]
            var loadCalls = 0
            var failuresRemaining = 0
            var probes: [AppEnvironment.HydrationPhase] = []
            var probe: (@Sendable () async -> AppEnvironment.HydrationPhase)?
        }

        private let lock = OSAllocatedUnfairLock<State>(initialState: State())

        init(seeded: [StoredGatewayRecord] = [], failuresRemaining: Int = 0) {
            lock.withLock { state in
                for record in seeded { state.records[record.id] = record }
                state.failuresRemaining = failuresRemaining
            }
        }

        /// Wired AFTER the environment exists so the probe can sample its
        /// observable phase from inside every durable read.
        func setProbe(_ probe: @escaping @Sendable () async -> AppEnvironment.HydrationPhase) {
            lock.withLock { $0.probe = probe }
        }

        var loadCalls: Int { lock.withLock { $0.loadCalls } }
        var probeResults: [AppEnvironment.HydrationPhase] { lock.withLock { $0.probes } }

        func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {
            lock.withLock { $0.records[record.id] = record }
        }

        func deleteGatewayRecord(id: GatewayID) async throws {
            lock.withLock { state in state.records[id.rawValue] = nil }
        }

        func loadGatewayRecords() async throws -> [StoredGatewayRecord] {
            let (shouldFail, probe): (Bool, (@Sendable () async -> AppEnvironment.HydrationPhase)?) =
                lock.withLock { state -> (Bool, (@Sendable () async -> AppEnvironment.HydrationPhase)?) in
                    state.loadCalls += 1
                    if state.failuresRemaining > 0 {
                        state.failuresRemaining -= 1
                        return (true, nil)
                    }
                    return (false, state.probe)
                }
            if shouldFail {
                throw CacheStoreError.storeUnavailable("scripted transient restore failure")
            }
            if let probe {
                // Sampled while the durable answer is still unresolved: any
                // `.unconfigured` here is the forbidden onboarding flash.
                let phase = await probe()
                lock.withLock { $0.probes.append(phase) }
            }
            return lock.withLock { $0.records.values.sorted { $0.id < $1.id } }
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

    /// Environment over the durable store, with the hydration-phase probe
    /// wired to sample from inside every durable read.
    private func makeEnvironment(store: ProbeRecordStore) -> AppEnvironment {
        let registry = GatewayRegistryService(
            credentials: InMemoryCredentialStore(),
            connectionFactory: { gateway, _ in OfflineConnection(gatewayID: gateway.id) },
            recordStore: store
        )
        let environment = makeEnvironment(registry: registry)
        store.setProbe { await MainActor.run { environment.hydrationPhase } }
        return environment
    }

    private let dogfoodEndpoint = URL(string: "https://gateway.example.invalid:9120")!
    private let dogfoodID = GatewayID(rawValue: "gateway.example.invalid:9120")

    private func dogfoodRecord() -> StoredGatewayRecord {
        StoredGatewayRecord(
            id: dogfoodID.rawValue,
            displayName: "Lab Node",
            endpoint: dogfoodEndpoint.absoluteString
        )
    }

    // MARK: the invariant assertions

    /// `.unconfigured` may NEVER be observed while durable restoration was
    /// unresolved — that is the transient onboarding flash.
    private func assertNeverUnconfigured(
        _ probes: [AppEnvironment.HydrationPhase],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            probes.contains(.unconfigured),
            "the first-run setup surface (.unconfigured) settled from an UNRESOLVED durable registry — probes: \(probes)",
            file: file, line: line)
    }

    /// While the durable read is in flight the phase must hold `.loading`.
    private func assertAllProbesLoading(
        _ probes: [AppEnvironment.HydrationPhase],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for phase in probes {
            XCTAssertEqual(
                phase, .loading,
                "the phase during durable restoration must hold .loading — got \(phase)",
                file: file, line: line)
        }
    }

    // MARK: configured relaunch

    func testConfiguredRelaunchNeverPassesThroughUnconfigured() async throws {
        let store = ProbeRecordStore(seeded: [dogfoodRecord()])
        let environment = makeEnvironment(store: store)

        await environment.load()

        XCTAssertEqual(environment.hydrationPhase, .configured,
                       "a restored non-empty registry settles .configured")
        XCTAssertEqual(environment.gateways.map(\.id), [dogfoodID],
                       "the durable fleet must be restored")
        let probes = store.probeResults
        XCTAssertFalse(probes.isEmpty,
                       "the probe must sample the phase from inside the durable read")
        assertAllProbesLoading(probes)
        assertNeverUnconfigured(probes)
    }

    // MARK: transient vs definitive restore failure

    func testTransientRestoreFailureHealsWithoutUnconfigured() async throws {
        // The store throws on its FIRST read, then succeeds (record present).
        let store = ProbeRecordStore(seeded: [dogfoodRecord()], failuresRemaining: 1)
        let environment = makeEnvironment(store: store)

        await environment.load()

        XCTAssertEqual(environment.hydrationPhase, .configured,
                       "a transient restore failure heals to .configured — never .unconfigured")
        XCTAssertEqual(environment.gateways.count, 1,
                       "the immediate retry must restore the durable fleet")
        XCTAssertEqual(store.loadCalls, 2,
                       "one failed read + one immediate retry (no delays)")
        assertNeverUnconfigured(store.probeResults)
        assertAllProbesLoading(store.probeResults)
    }

    func testDefinitiveRestoreFailureHoldsLoadingNeverUnconfigured() async throws {
        // The store always fails: "zero gateways" is NOT authoritative.
        let store = ProbeRecordStore(seeded: [dogfoodRecord()], failuresRemaining: Int.max)
        let environment = makeEnvironment(store: store)

        await environment.load()

        XCTAssertEqual(environment.hydrationPhase, .loading,
                       "an unresolved durable registry must hold .loading — never .unconfigured")
        XCTAssertEqual(environment.gateways.count, 0,
                       "no gateway may be treated as restored")
        XCTAssertEqual(store.loadCalls, 3,
                       "bounded retries: the initial read + two immediate attempts")
        assertNeverUnconfigured(store.probeResults)
    }

    // MARK: fresh install

    func testFreshInstallSettlesUnconfiguredAfterCompletedRestore() async throws {
        let store = ProbeRecordStore()
        let environment = makeEnvironment(store: store)

        XCTAssertEqual(environment.hydrationPhase, .loading,
                       "a fresh runtime starts unresolved (.loading)")

        await environment.load()

        XCTAssertEqual(environment.hydrationPhase, .unconfigured,
                       "an ANSWERED empty registry is authoritative — setup shows")
        XCTAssertEqual(store.loadCalls, 1, "an answered read needs no retry")
        assertAllProbesLoading(store.probeResults)
        assertNeverUnconfigured(store.probeResults)
    }

    // MARK: add / remove flips

    func testFirstGatewayRegistrationFlipsConfiguredOnlyAfterSuccess() async throws {
        let store = ProbeRecordStore()
        let environment = makeEnvironment(store: store)
        await environment.load()
        XCTAssertEqual(environment.hydrationPhase, .unconfigured)

        _ = try await environment.addGateway(GatewayRegistration(
            id: GatewayID(rawValue: "first"),
            displayName: "First Server",
            endpoint: URL(string: "https://gateway.example.invalid:8642")!
        ))
        XCTAssertEqual(environment.hydrationPhase, .configured,
                       "registering the first gateway must end the setup state")

        // A FRESH environment: a registration the registry REJECTS (the real
        // trimmed-empty-display-name validation) must leave the phase
        // untouched — no optimistic flip, no setup-surface churn.
        let rejectingStore = ProbeRecordStore()
        let rejectingEnvironment = makeEnvironment(store: rejectingStore)
        await rejectingEnvironment.load()
        XCTAssertEqual(rejectingEnvironment.hydrationPhase, .unconfigured)

        do {
            _ = try await rejectingEnvironment.addGateway(GatewayRegistration(
                id: GatewayID(rawValue: "rejected"),
                displayName: "   ",
                endpoint: URL(string: "https://gateway.example.invalid:9000")!
            ))
            XCTFail("the registry must reject an empty display name")
        } catch GatewayRegistryError.emptyDisplayName {
            // Expected — rejected before any mutation. (XCTest has no async
            // `XCTAssertThrowsError` overload; this do/catch is equivalent:
            // no throw — or any other error — fails the test.)
        }
        XCTAssertEqual(rejectingEnvironment.hydrationPhase, .unconfigured,
                       "a failed registration must not flip the first-run gate")
        XCTAssertTrue(rejectingEnvironment.gateways.isEmpty,
                      "a rejected registration must not enter the fleet")
    }

    func testFinalGatewayRemovalReturnsToUnconfigured() async throws {
        let store = ProbeRecordStore()
        let environment = makeEnvironment(store: store)
        await environment.load()
        XCTAssertEqual(environment.hydrationPhase, .unconfigured)

        let added = try await environment.addGateway(GatewayRegistration(
            id: GatewayID(rawValue: "only"),
            displayName: "Only Server",
            endpoint: URL(string: "https://gateway.example.invalid:8642")!
        ))
        XCTAssertEqual(environment.hydrationPhase, .configured)

        try await environment.removeGateway(added.id)

        XCTAssertEqual(environment.hydrationPhase, .unconfigured,
                       "removing the final gateway must return to the setup state")
        XCTAssertTrue(environment.gateways.isEmpty)
    }

    // MARK: duplicate hydration (initial auth + app-lock unlock resume)

    func testDuplicateHydrationIsIdempotentNoFlash() async throws {
        let store = ProbeRecordStore(seeded: [dogfoodRecord()])
        let environment = makeEnvironment(store: store)

        await environment.hydrateIfNeeded()
        await environment.hydrateIfNeeded()

        XCTAssertEqual(environment.hydrationPhase, .configured)
        XCTAssertEqual(environment.gateways.count, 1)
        XCTAssertEqual(store.loadCalls, 1,
                       "hydration is once-per-runtime — the unlock path must not re-read the store")
        assertNeverUnconfigured(store.probeResults)
        assertAllProbesLoading(store.probeResults)

        // App-lock unlock resume: a third call still performs no new load.
        await environment.hydrateIfNeeded()
        XCTAssertEqual(store.loadCalls, 1)
        XCTAssertEqual(environment.hydrationPhase, .configured)
    }
}