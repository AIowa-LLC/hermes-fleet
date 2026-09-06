import XCTest
import FleetCore
@testable import FleetPersistence

/// P0-4 (t_e32529e8): gateway-record persistence. A user-added gateway must
/// survive app relaunch — the record (id, display name, endpoint, non-secret
/// auth configuration) is persisted IMMEDIATELY on Add, regardless of
/// connection state, and restored on launch marked disconnected.
///
/// These tests cover the persistence layer (`SwiftDataCacheStore` as a
/// `GatewayRecordStoring`): round-trip, upsert/replace, delete, and the
/// relaunch simulation (a SECOND store instance on the same file sees the
/// records the first one wrote).
final class GatewayRecordPersistenceTests: XCTestCase {

    private func sampleRecord(
        id: String = "100.100.200.61:9120",
        displayName: String = "Lab Node",
        endpoint: String = "http://100.100.200.61:9120"
    ) -> StoredGatewayRecord {
        StoredGatewayRecord(
            id: id,
            displayName: displayName,
            endpoint: endpoint,
            authConfiguration: GatewayAuthConfiguration(
                strategy: .usernamePassword,
                credentialStored: true
            ),
            authConfigured: true
        )
    }

    // MARK: Round-trip

    func testSaveThenLoadRoundTripsRecord() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        let record = sampleRecord()
        try await store.saveGatewayRecord(record)

        let loaded = try await store.loadGatewayRecords()
        XCTAssertEqual(loaded, [record], "saved record must round-trip exactly")
    }

    func testLoadOnEmptyStoreReturnsEmptyArray() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        let loaded = try await store.loadGatewayRecords()
        XCTAssertTrue(loaded.isEmpty, "fresh store must load zero records")
    }

    // MARK: Replace / delete semantics

    func testSavingAgainReplacesTheRecordNotDuplicates() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        try await store.saveGatewayRecord(sampleRecord(displayName: "Old Name"))
        try await store.saveGatewayRecord(sampleRecord(displayName: "New Name"))

        let loaded = try await store.loadGatewayRecords()
        XCTAssertEqual(loaded.count, 1, "upsert must replace, not duplicate")
        XCTAssertEqual(loaded.first?.displayName, "New Name")
    }

    func testDeleteRemovesOnlyTheTargetRecord() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        let a = sampleRecord(id: "gw-a", endpoint: "http://127.0.0.1:8001")
        let b = sampleRecord(id: "gw-b", endpoint: "http://127.0.0.1:8002")
        try await store.saveGatewayRecord(a)
        try await store.saveGatewayRecord(b)

        try await store.deleteGatewayRecord(id: GatewayID(rawValue: "gw-a"))

        let loaded = try await store.loadGatewayRecords()
        XCTAssertEqual(loaded.map(\.id), ["gw-b"], "delete removes only the target record")
    }

    func testDeleteMissingRecordIsNoOp() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        try await store.deleteGatewayRecord(id: GatewayID(rawValue: "never-added"))
        let loaded = try await store.loadGatewayRecords()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: Relaunch simulation (the P0-4 acceptance core)

    func testSecondStoreInstanceOnSameFileSeesSavedRecords() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p04-record-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("cache.store")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // "Session 1": add a gateway, record written through.
        let session1 = try SwiftDataCacheStore.makeFileBacked(storeURL: url)
        try await session1.saveGatewayRecord(sampleRecord())

        // "Session 2" (app relaunched): a fresh store instance on the same
        // file must see the record — entries survive app close/relaunch.
        let session2 = try SwiftDataCacheStore.makeFileBacked(storeURL: url)
        let loaded = try await session2.loadGatewayRecords()
        XCTAssertEqual(loaded, [sampleRecord()], "records must survive a store relaunch")
    }

    // MARK: No-secret invariant

    func testRecordCarriesNoSecretMaterial() async throws {
        // The durable record describes the auth STRATEGY + whether a
        // credential exists — the secret itself lives only in Keychain.
        // Structural check: the record's Codable JSON contains no field
        // capable of carrying an arbitrary secret blob.
        let record = sampleRecord()
        let json = try JSONEncoder().encode(record)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(text.contains("password"), "record JSON must not carry password material: \(text)")
        XCTAssertFalse(text.contains("token"), "record JSON must not carry token material: \(text)")
        XCTAssertTrue(
            text.contains("usernamePassword"),
            "the non-secret strategy name is the only auth description persisted"
        )
    }
}
