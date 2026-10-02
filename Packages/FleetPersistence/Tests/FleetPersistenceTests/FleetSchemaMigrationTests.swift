import XCTest
import SwiftData
import FleetCore
@testable import FleetPersistence

/// P0.4b: `FleetSchemaV1` must describe exactly the models that shipped before
/// versioning, so an existing store (created by the old flat
/// `ModelContainer(for:)` call) opens through `FleetMigrationPlan` in place,
/// with its data intact.
final class FleetSchemaMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetSchemaMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The pre-change container setup, verbatim: a flat model list, no
    /// versioned schema, no migration plan (build 96 and earlier).
    static func makeLegacyContainer(storeURL: URL) throws -> ModelContainer {
        try ModelContainer(
            for: CachedMessageRow.self, CachedWatermarkRow.self, CachedReplayEpochRow.self,
                 CachedHealthStatsRow.self, CachedGatewayRow.self, LearningGraphSnapshotRow.self,
                 ProjectsSnapshotRow.self, LaunchRosterRow.self, LaunchSessionListRow.self,
            configurations: ModelConfiguration(url: storeURL)
        )
    }

    func testSchemaV1ListsExactlyTheLegacyModels() {
        let names = Set(FleetSchemaV1.models.map { String(describing: $0) })
        XCTAssertEqual(names, [
            "CachedMessageRow", "CachedWatermarkRow", "CachedReplayEpochRow",
            "CachedHealthStatsRow", "CachedGatewayRow", "LearningGraphSnapshotRow",
            "ProjectsSnapshotRow", "LaunchRosterRow", "LaunchSessionListRow",
        ])
        XCTAssertEqual(FleetSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertEqual(FleetMigrationPlan.schemas.count, 1)
        XCTAssertTrue(FleetMigrationPlan.stages.isEmpty)
    }

    func testLegacyStoreOpensThroughMigrationPlanWithDataIntact() async throws {
        let storeURL = directory.appendingPathComponent("cache.store")
        do {
            let legacy = try Self.makeLegacyContainer(storeURL: storeURL)
            let ctx = ModelContext(legacy)
            ctx.insert(CachedGatewayRow(
                gatewayID: "gw-a.example.invalid", displayName: "Alpha",
                endpoint: "https://gw-a.example.invalid", authStrategyRaw: "sessionToken",
                credentialStored: true, authConfigured: true))
            ctx.insert(CachedMessageRow(
                gatewayID: "gw-a.example.invalid", sessionID: "s1", order: 0, role: "user",
                text: "hello", timestamp: 1, rowID: "r1", displayKind: nil, reasoning: nil,
                toolName: nil, toolContext: nil, clientID: "c1"))
            ctx.insert(CachedWatermarkRow(
                gatewayID: "gw-a.example.invalid", sessionID: "s1", lastSeenSeq: 7))
            ctx.insert(LaunchRosterRow(
                gatewayID: "gw-a.example.invalid", payload: Data([1, 2, 3]),
                cachedAt: Date(timeIntervalSince1970: 5)))
            try ctx.save()
        }

        let store = try SwiftDataCacheStore.makeFileBacked(storeURL: storeURL)

        let gateways = try await store.loadGatewayRecords()
        XCTAssertEqual(gateways.map(\.id), ["gw-a.example.invalid"])
        XCTAssertEqual(gateways.first?.displayName, "Alpha")
        let history = try await store.loadHistory(
            sessionID: "s1", for: GatewayID(rawValue: "gw-a.example.invalid"))
        XCTAssertEqual(history?.messages.map(\.text), ["hello"])
        let watermarks = try await store.loadWatermarks()
        XCTAssertEqual(watermarks, [SessionEventWatermark(sessionID: "s1", lastSeenSeq: 7)])

        let launchRows = try ModelContext(store.container).fetch(FetchDescriptor<LaunchRosterRow>())
        XCTAssertEqual(launchRows.map(\.payload), [Data([1, 2, 3])])
    }

    func testStoreWrittenThroughPlanReopensWithLegacyContainerSetup() async throws {
        // A store created through the plan still opens with the old flat
        // setup (identical entity hashes), so the change is a pure snapshot.
        let storeURL = directory.appendingPathComponent("cache.store")
        do {
            let store = try SwiftDataCacheStore.makeFileBacked(storeURL: storeURL)
            try await store.saveGatewayRecord(StoredGatewayRecord(
                id: "gw-b.example.invalid", displayName: "Beta", endpoint: "https://gw-b.example.invalid"))
        }
        let legacy = try Self.makeLegacyContainer(storeURL: storeURL)
        let rows = try ModelContext(legacy).fetch(FetchDescriptor<CachedGatewayRow>())
        XCTAssertEqual(rows.map(\.displayName), ["Beta"])
    }

    func testInMemoryStoreBuildsThroughPlan() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        try await store.saveGatewayRecord(StoredGatewayRecord(
            id: "gw-c.example.invalid", displayName: "Gamma", endpoint: "https://gw-c.example.invalid"))
        let loaded = try await store.loadGatewayRecords()
        XCTAssertEqual(loaded.count, 1)
    }
}
