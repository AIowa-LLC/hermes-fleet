import XCTest
import SwiftData
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
@testable import FleetUI
@testable import HermesFleetApp

/// P0.4b: the cache store is opened through the versioned schema, an existing
/// (pre-versioning) store opens unchanged, and an unopenable store is
/// quarantined and rebuilt instead of trapping. Synthetic fixtures only.
@MainActor
final class LocalCacheRecoveryTests: XCTestCase {
    private var directory: URL!
    private var storeURL: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCacheRecovery-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("HermesFleetCache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("cache.store")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func gateway(_ id: String, name: String) -> StoredGatewayRecord {
        StoredGatewayRecord(id: id, displayName: name, endpoint: "https://\(id)")
    }

    // MARK: Existing stores open unchanged

    func testPreVersioningStoreOpensThroughVersionedContainerWithRowsIntact() async throws {
        // The container setup exactly as build 96 created it: a flat model
        // list, no VersionedSchema, no migration plan.
        do {
            let legacy = try ModelContainer(
                for: CachedMessageRow.self, CachedWatermarkRow.self, CachedReplayEpochRow.self,
                     CachedHealthStatsRow.self, CachedGatewayRow.self, LearningGraphSnapshotRow.self,
                     ProjectsSnapshotRow.self, LaunchRosterRow.self, LaunchSessionListRow.self,
                configurations: ModelConfiguration(url: storeURL))
            let ctx = ModelContext(legacy)
            ctx.insert(CachedGatewayRow(
                gatewayID: "gw-legacy.example.invalid", displayName: "Legacy",
                endpoint: "https://gw-legacy.example.invalid", authStrategyRaw: "bearerToken",
                credentialStored: true, authConfigured: true))
            ctx.insert(CachedMessageRow(
                gatewayID: "gw-legacy.example.invalid", sessionID: "s1", order: 0, role: "user",
                text: "kept", timestamp: 1, rowID: "r1", displayKind: nil, reasoning: nil,
                toolName: nil, toolContext: nil))
            try ctx.save()
        }

        // The app's own open path: no recovery may trigger for a healthy,
        // previously-shipped store.
        let (store, persistentCache, recovery) = FleetServiceGraph.makeFileBackedCache(storeURL: storeURL)

        XCTAssertNil(recovery, "an existing store must open in place, not be rebuilt")
        let gateways = try await store.loadGatewayRecords()
        XCTAssertEqual(gateways.map(\.displayName), ["Legacy"])
        XCTAssertEqual(gateways.first?.authConfiguration.strategy, .bearerToken)
        let history = try await store.loadHistory(
            sessionID: "s1", for: GatewayID(rawValue: "gw-legacy.example.invalid"))
        XCTAssertEqual(history?.messages.map(\.text), ["kept"])
        let quarantine = SwiftDataCacheStore.quarantineDirectory(for: storeURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
    }

    // MARK: Quarantine-and-rebuild through the app graph factory

    func testCorruptStoreIsQuarantinedAndGraphFactoryReturnsWorkingStore() async throws {
        try Data("not a database".utf8).write(to: storeURL)

        let (store, persistentCache, recovery) = FleetServiceGraph.makeFileBackedCache(storeURL: storeURL)

        XCTAssertEqual(recovery?.outcome, .quarantinedAndRebuilt)
        try await store.saveGatewayRecord(gateway("gw-new.example.invalid", name: "New"))
        let loaded = try await store.loadGatewayRecords()
        XCTAssertEqual(loaded.map(\.displayName), ["New"])

        let quarantine = SwiftDataCacheStore.quarantineDirectory(for: storeURL)
        let generations = try FileManager.default.contentsOfDirectory(
            at: quarantine, includingPropertiesForKeys: nil)
        XCTAssertEqual(generations.count, 1)
        XCTAssertEqual(CacheStoreProtection.read(from: quarantine).backupExcluded, true)
        // Quarantined files carry the data-protection class and backup exclusion
        // (the simulator reports its default class rather than the applied
        // .complete, so assert protection is on and exclusion exactly).
        let quarantinedFiles = try FileManager.default.contentsOfDirectory(
            at: try XCTUnwrap(generations.first), includingPropertiesForKeys: nil)
        XCTAssertFalse(quarantinedFiles.isEmpty)
        for file in quarantinedFiles {
            let protection = CacheStoreProtection.read(from: file)
            XCTAssertEqual(protection.backupExcluded, true)
            XCTAssertNotNil(protection.fileProtection, "quarantined file reports a data-protection class")
        }
        // The store directory itself must survive (fresh-install detection).
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        // The rebuilt store keeps backup exclusion.
        XCTAssertEqual(CacheStoreProtection.read(from: storeURL).backupExcluded, true)
    }

    func testSavedGatewaysSurviveWhenRegistryTableIsStillReadable() async throws {
        do {
            let seeded = try SwiftDataCacheStore.makeFileBacked(storeURL: storeURL)
            try await seeded.saveGatewayRecord(gateway("gw-a.example.invalid", name: "Alpha"))
            try await seeded.saveGatewayRecord(gateway("gw-b.example.invalid", name: "Beta"))
        }

        let (store, persistentCache, recovery) = FleetServiceGraph.makeFileBackedCache(
            storeURL: storeURL, faults: [.unreadablePrimaryStore])

        XCTAssertEqual(recovery?.outcome, .quarantinedAndRebuilt)
        XCTAssertEqual(recovery?.registry, .salvaged(count: 2))
        let loaded = try await store.loadGatewayRecords()
        XCTAssertEqual(loaded.map(\.displayName), ["Alpha", "Beta"])
    }

    func testUnrecoverableFileFailureFallsBackToInMemoryWithoutTrapping() async throws {
        let (store, persistentCache, recovery) = FleetServiceGraph.makeFileBackedCache(
            storeURL: storeURL, faults: [.unreadablePrimaryStore, .freshFileBackedStore])

        XCTAssertEqual(recovery?.outcome, .inMemoryFallback)
        XCTAssertNil(persistentCache?.storeURL)
        XCTAssertTrue(recovery?.notices.contains(.runningWithoutLocalCache) == true)
        try await store.saveGatewayRecord(gateway("gw-mem.example.invalid", name: "Memory"))
        let loaded = try await store.loadGatewayRecords()
        XCTAssertEqual(loaded.count, 1, "the session still has a working store")
    }

    func testFailedInMemoryContainerStillReturnsUsableGraphStores() async throws {
        let (store, persistentCache, recovery) = FleetServiceGraph.makeFileBackedCache(
            storeURL: storeURL, faults: [.unreadablePrimaryStore, .freshFileBackedStore, .inMemoryStore])
        XCTAssertNil(persistentCache)
        XCTAssertTrue(recovery?.notices.contains(.runningWithoutLocalCache) == true)
        try await store.saveGatewayRecord(gateway("gw-emergency.example.invalid", name: "Temporary"))
        try await store.clearCachedData()
        let records = try await store.loadGatewayRecords()
        XCTAssertEqual(records.map(\.displayName), ["Temporary"])
        let history = try await store.loadHistory(sessionID: "s1", for: GatewayID(rawValue: "gw-emergency.example.invalid"))
        XCTAssertNil(history)
    }

    func testFailedInMemoryContainerReportsUnrestoredSalvagedGateways() async throws {
        do {
            let seeded = try SwiftDataCacheStore.makeFileBacked(storeURL: storeURL)
            try await seeded.saveGatewayRecord(gateway("gw-before.example.invalid", name: "Before"))
        }
        let (store, _, recovery) = FleetServiceGraph.makeFileBackedCache(
            storeURL: storeURL, faults: [.unreadablePrimaryStore, .freshFileBackedStore, .inMemoryStore])
        XCTAssertEqual(recovery?.registry, .lost)
        XCTAssertTrue(recovery?.notices.contains(.savedGatewaysNeedReadding) == true)
        let records = try await store.loadGatewayRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testGraphLaunchCacheDoesNotRecreateRemovedGatewayOnDelayedWrite() async throws {
        let modes: [CacheOpenFaultInjection] = [
            [], [.unreadablePrimaryStore, .freshFileBackedStore],
            [.unreadablePrimaryStore, .freshFileBackedStore, .inMemoryStore]
        ]
        for (index, faults) in modes.enumerated() {
            let (store, persistentCache, _) = FleetServiceGraph.makeFileBackedCache(
                storeURL: storeURL.appendingPathExtension("mode-\(index)"), faults: faults)
            let id = GatewayID(rawValue: "gw-late.example.invalid")
            let route = Route(gatewayID: id, profileSlug: ProfileSlug(rawValue: "default"))
            try await store.saveGatewayRecord(gateway(id.rawValue, name: "Synthetic"))
            let launch = FleetServiceGraph.makeLaunchCache(for: persistentCache)
            try await launch.saveRosterCache(CachedGatewayRoster(gatewayID: id, bots: []))
            try await launch.saveSessionListCache(CachedSessionList(route: route, sessions: []))
            try await launch.removeLaunchCache(for: id)
            try await store.purgeGateway(id)
            // A read that was already running settles after gateway removal.
            try? await launch.saveRosterCache(CachedGatewayRoster(gatewayID: id, bots: []))
            try? await launch.saveSessionListCache(CachedSessionList(route: route, sessions: []))
            let rosters = try await launch.loadRosterCache()
            let sessions = try await launch.loadSessionListCache()
            XCTAssertTrue(rosters.isEmpty, "Removed gateway roster recreated in mode \(index)")
            XCTAssertTrue(sessions.isEmpty, "Removed gateway session list recreated in mode \(index)")
        }
    }

    // MARK: Diagnostics + notices

    func testRecoveryIsRecordedInDiagnosticsWithoutPathsAndSurfacesNotices() throws {
        let recorder = DiagnosticsRecorder()
        let report = LocalCacheRecoveryReport(
            outcome: .quarantinedAndRebuilt, registry: .lost, failureType: "NSError")
        let environment = makeEnvironment(recorder: recorder, recovery: report)

        let entries = recorder.snapshot()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.category, "persistence")
        let detail = try XCTUnwrap(entries.first?.detail)
        XCTAssertTrue(detail.contains("quarantined"))
        XCTAssertFalse(detail.contains("/"), "diagnostics carry no file paths")
        XCTAssertFalse(detail.contains(directory.lastPathComponent))

        XCTAssertEqual(environment.localCacheNotices, [.savedGatewaysNeedReadding])
        environment.dismissLocalCacheNotice(.savedGatewaysNeedReadding)
        XCTAssertTrue(environment.localCacheNotices.isEmpty)
    }

    func testRunningWithoutCacheNoticeCannotBeDismissed() {
        let report = LocalCacheRecoveryReport(
            outcome: .inMemoryFallback, registry: .nothingToRestore, failureType: "NSError")
        let environment = makeEnvironment(recorder: DiagnosticsRecorder(), recovery: report)

        environment.dismissLocalCacheNotice(.runningWithoutLocalCache)

        XCTAssertEqual(environment.localCacheNotices, [.runningWithoutLocalCache])
    }

    func testNormalLaunchRecordsNothing() {
        let recorder = DiagnosticsRecorder()
        let environment = makeEnvironment(recorder: recorder, recovery: nil)
        XCTAssertTrue(recorder.snapshot().isEmpty)
        XCTAssertTrue(environment.localCacheNotices.isEmpty)
    }

    // MARK: Fixtures

    private struct Connection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
    }

    private struct RosterSession: GatewayRosterSession {
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

    private struct SessionList: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private final class Health: ConnectionHealthAccumulating, @unchecked Sendable {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    private func makeEnvironment(
        recorder: DiagnosticsRecorder,
        recovery: LocalCacheRecoveryReport?
    ) -> AppEnvironment {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in Connection(gatewayID: gateway.id) })
        return AppEnvironment(
            registry: registry,
            roster: FleetRosterService(
                registry: registry, credentials: credentials,
                sessionFactory: { gateway, _ in RosterSession(gatewayID: gateway.id) }),
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: SessionList(),
            connectionFactory: { gateway, _ in Connection(gatewayID: gateway.id) },
            health: Health(),
            bridgedStoreURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fleet-cache-recovery-\(UUID().uuidString).json"),
            diagnosticsRecorder: recorder,
            localCacheRecovery: recovery)
    }
}
