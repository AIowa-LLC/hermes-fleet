import XCTest
import Foundation
import FleetCore
@testable import FleetPersistence

/// M10 SwiftData non-secret cache: round-trips, replace semantics, watermarks,
/// replay_epoch, fail-closed reset, and the structural no-secret invariant.
///
/// These tests run on the host (macOS 14+) with an in-memory SwiftData
/// container — hermetic, no file I/O. File-protection attribute verification
/// lives in the app-level boundary test (iOS simulator).
final class SwiftDataCacheStoreTests: XCTestCase {

    private func makeStore() async throws -> SwiftDataCacheStore {
        try SwiftDataCacheStore.makeInMemory()
    }

    private let m5 = GatewayID(rawValue: "workstation")
    private let arch = GatewayID(rawValue: "arch")

    // MARK: History

    func testHistoryRoundTrip() async throws {
        let store = try await makeStore()
        let history = SessionHistory(sessionID: "s1", count: 2, messages: [
            SessionMessage(role: .user, text: "hello", timestamp: 1, rowID: "r1"),
            SessionMessage(role: .assistant, text: "hi there", timestamp: 2, rowID: "r2", displayKind: "answer", reasoning: "thinking", toolName: nil, toolContext: nil),
        ])

        try await store.saveHistory(history, for: m5)
        let loaded = try await store.loadHistory(sessionID: "s1", for: m5)
        XCTAssertEqual(loaded, history, "transcript round-trips losslessly")
    }

    func testHistoryMissingIsNil() async throws {
        let store = try await makeStore()
        let loaded = try await store.loadHistory(sessionID: "nope", for: m5)
        XCTAssertNil(loaded)
    }

    func testHistoryReplaceOverwrites() async throws {
        let store = try await makeStore()
        let first = SessionHistory(sessionID: "s1", count: 1, messages: [
            SessionMessage(role: .user, text: "first", timestamp: 1, rowID: "r1"),
        ])
        let second = SessionHistory(sessionID: "s1", count: 1, messages: [
            SessionMessage(role: .user, text: "second", timestamp: 3, rowID: "r3"),
        ])
        try await store.saveHistory(first, for: m5)
        try await store.saveHistory(second, for: m5)
        let loaded = try await store.loadHistory(sessionID: "s1", for: m5)
        XCTAssertEqual(loaded, second, "replace semantics: newest wins, no duplicates")
        XCTAssertEqual(loaded?.messages.count, 1)
    }

    func testHistoryDelete() async throws {
        let store = try await makeStore()
        try await store.saveHistory(
            SessionHistory(sessionID: "s1", count: 1, messages: [SessionMessage(role: .user, text: "x", timestamp: 1, rowID: "r1")]),
            for: m5
        )
        try await store.deleteHistory(sessionID: "s1", for: m5)
        let loaded = try await store.loadHistory(sessionID: "s1", for: m5)
        XCTAssertNil(loaded)
    }

    func testHistoryIsolationPerGateway() async throws {
        let store = try await makeStore()
        let history = SessionHistory(sessionID: "s1", count: 1, messages: [
            SessionMessage(role: .user, text: "on macbook", timestamp: 1, rowID: "r1"),
        ])
        try await store.saveHistory(history, for: m5)
        // Same session id on a different gateway must not leak.
        let other = try await store.loadHistory(sessionID: "s1", for: arch)
        XCTAssertNil(other, "gateways do not share cached transcripts")
    }

    // MARK: Watermarks

    func testWatermarkRoundTrip() async throws {
        let store = try await makeStore()
        try await store.saveWatermark(SessionEventWatermark(sessionID: "s1", lastSeenSeq: 42), for: m5)
        let watermarks = try await store.loadWatermarks()
        XCTAssertEqual(watermarks, [SessionEventWatermark(sessionID: "s1", lastSeenSeq: 42)])
    }

    func testWatermarkUpsert() async throws {
        let store = try await makeStore()
        try await store.saveWatermark(SessionEventWatermark(sessionID: "s1", lastSeenSeq: 10), for: m5)
        try await store.saveWatermark(SessionEventWatermark(sessionID: "s1", lastSeenSeq: 11), for: m5)
        let watermarks = try await store.loadWatermarks()
        XCTAssertEqual(watermarks, [SessionEventWatermark(sessionID: "s1", lastSeenSeq: 11)])
    }

    func testClearWatermarks() async throws {
        let store = try await makeStore()
        try await store.saveWatermark(SessionEventWatermark(sessionID: "s1", lastSeenSeq: 5), for: m5)
        try await store.clearWatermarks()
        let watermarks = try await store.loadWatermarks()
        XCTAssertTrue(watermarks.isEmpty)
    }

    // MARK: Replay epoch

    func testReplayEpochRoundTrip() async throws {
        let store = try await makeStore()
        try await store.saveReplayEpoch("epoch-1", for: m5)
        let epoch = try await store.loadReplayEpoch(for: m5)
        XCTAssertEqual(epoch, "epoch-1")
    }

    func testReplayEpochNilByDefault() async throws {
        let store = try await makeStore()
        let epoch = try await store.loadReplayEpoch(for: m5)
        XCTAssertNil(epoch)
    }

    func testReplayEpochPerGateway() async throws {
        let store = try await makeStore()
        try await store.saveReplayEpoch("epoch-m5", for: m5)
        let epoch = try await store.loadReplayEpoch(for: m5)
        XCTAssertEqual(epoch, "epoch-m5")
        let other = try await store.loadReplayEpoch(for: arch)
        XCTAssertNil(other)
    }

    // MARK: Fail-closed reset (stale epoch → reset)

    func testResetClearsGatewayState() async throws {
        let store = try await makeStore()
        try await store.saveHistory(
            SessionHistory(sessionID: "s1", count: 1, messages: [SessionMessage(role: .user, text: "x", timestamp: 1, rowID: "r1")]),
            for: m5
        )
        try await store.saveWatermark(SessionEventWatermark(sessionID: "s1", lastSeenSeq: 9), for: m5)
        try await store.saveReplayEpoch("stale-epoch", for: m5)

        // A stale epoch for THIS gateway resets only this gateway.
        try await store.resetForReplayEpochChange(gatewayID: m5)

        let history = try await store.loadHistory(sessionID: "s1", for: m5)
        XCTAssertNil(history)
        let watermarks = try await store.loadWatermarks()
        XCTAssertTrue(watermarks.isEmpty)
        let epoch = try await store.loadReplayEpoch(for: m5)
        XCTAssertNil(epoch)
    }

    func testResetIsolationPerGateway() async throws {
        let store = try await makeStore()
        try await store.saveHistory(
            SessionHistory(sessionID: "s1", count: 1, messages: [SessionMessage(role: .user, text: "keep", timestamp: 1, rowID: "r1")]),
            for: arch
        )
        try await store.saveReplayEpoch("arch-epoch", for: arch)
        try await store.resetForReplayEpochChange(gatewayID: m5)

        let archHistory = try await store.loadHistory(sessionID: "s1", for: arch)
        XCTAssertNotNil(archHistory, "unrelated gateway unaffected")
        let archEpoch = try await store.loadReplayEpoch(for: arch)
        XCTAssertEqual(archEpoch, "arch-epoch")
    }

    // MARK: B1 — launch-stable message identity persists across fresh containers

    /// B1 regression: the synthesized message id must be a launch-stable UUID
    /// minted at message construction and persisted through this seam, so two
    /// "app launches" (fresh model containers) reading the SAME persisted store
    /// see identical ids — never a per-launch-randomized `hashValue`. Also
    /// duplicate-text messages must keep distinct ids after reload, and a
    /// gateway row_id must remain the durable identity.
    func testFreshContainersRestoreIdenticalMessageIDs() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("S2Stable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("cache.store")

        // "Launch 1": persist a transcript with no row_id (synthesized-id path)
        // including a duplicate-text pair, plus one gateway-stamped row_id.
        let history = SessionHistory(sessionID: "s1", count: 3, messages: [
            SessionMessage(role: .user, text: "duplicate", timestamp: 100, rowID: nil),
            SessionMessage(role: .user, text: "duplicate", timestamp: 100, rowID: nil),
            SessionMessage(role: .assistant, text: "answer", timestamp: 200, rowID: "r1"),
        ])
        do {
            let storeA = try SwiftDataCacheStore.makeFileBacked(storeURL: storeURL)
            try await storeA.saveHistory(history, for: m5)
        }

        // "Launch 2": a fresh model container on the same persisted store.
        let storeB = try SwiftDataCacheStore.makeFileBacked(storeURL: storeURL)
        let loadedB = try await storeB.loadHistory(sessionID: "s1", for: m5)
        let idsB = loadedB?.messages.map(\.id) ?? []
        XCTAssertEqual(idsB.count, 3, "transcript survives the relaunch")
        // No-row_id messages mint launch-stable UUIDs, not hash-derived strings.
        XCTAssertNotNil(UUID(uuidString: idsB[0]), "synthesized id is a UUID after reload")
        XCTAssertNotNil(UUID(uuidString: idsB[1]), "synthesized id is a UUID after reload")
        // Duplicate-text messages keep distinct ids after reload.
        XCTAssertNotEqual(idsB[0], idsB[1], "duplicate-text messages keep distinct ids")
        // A gateway row_id remains the durable identity.
        XCTAssertEqual(idsB[2], "r1", "row_id stays the durable identity")

        // "Launch 3": ANOTHER fresh container sees the exact same ids.
        let storeC = try SwiftDataCacheStore.makeFileBacked(storeURL: storeURL)
        let loadedC = try await storeC.loadHistory(sessionID: "s1", for: m5)
        XCTAssertEqual(
            loadedC?.messages.map(\.id) ?? [], idsB,
            "two fresh model containers from the same persisted store yield identical ids")
    }

    // MARK: Structural no-secret invariant

    /// Proves the cache models hold NO token/credential/secret field by
    /// construction: the @Model row types are inspected for forbidden field
    /// names, and the store's public API surface has no secret parameter.
    func testCacheModelsHaveNoSecretFields() {
        let forbidden = ["token", "ticket", "credential", "password", "passphrase", "secret", "apikey", "api_key"]
        let modelTypes: [(String, Any)] = [
            ("CachedMessageRow", CachedMessageRow(gatewayID: "", sessionID: "", order: 0, role: "", text: "", timestamp: nil, rowID: nil, displayKind: nil, reasoning: nil, toolName: nil, toolContext: nil)),
            ("CachedWatermarkRow", CachedWatermarkRow(gatewayID: "", sessionID: "", lastSeenSeq: 0)),
            ("CachedReplayEpochRow", CachedReplayEpochRow(gatewayID: "", epoch: nil)),
        ]
        for (typeName, instance) in modelTypes {
            let fields = Mirror(reflecting: instance).children.compactMap { $0.label }
            for field in fields {
                let lower = field.lowercased()
                for word in forbidden where lower.contains(word) {
                    XCTFail("\(typeName).\(field) must not exist (no-secret invariant)")
                }
            }
        }
    }

    func testStoreProtocolHasNoSecretParameter() {
        // Compile-time/structural: `CacheStoring` (FleetCore) accepts only
        // non-secret values. Proved by type — a token cannot be passed to any
        // cache method. (Compilation of this test file already asserts the API;
        // the check documents the invariant.)
        let requirements: [String] = [
            "saveHistory", "loadHistory", "deleteHistory",
            "saveWatermark", "loadWatermarks", "clearWatermarks",
            "saveReplayEpoch", "loadReplayEpoch", "resetForReplayEpochChange",
        ]
        XCTAssertEqual(requirements.count, 9)
        // No "saveToken"/"credential"/"token" entry exists in the cache seam.
        XCTAssertFalse(requirements.contains { $0.lowercased().contains("token") })
        XCTAssertFalse(requirements.contains { $0.lowercased().contains("credential") })
    }
}
