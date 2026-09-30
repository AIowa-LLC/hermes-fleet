import XCTest
import Foundation
import SwiftData
import FleetCore
@testable import FleetPersistence

/// P0.3b: removing a gateway must leave zero cached rows for it (transcripts,
/// watermarks, replay epoch, health, Learning/Projects snapshots, launch cache)
/// and must not touch any other gateway's rows. Synthetic fixtures only.
final class PurgeGatewayTests: XCTestCase {
    private let a = GatewayID(rawValue: "gw-a")
    /// Shares a textual prefix with `a` to prove matching is exact, not prefix.
    private let aPrefixed = GatewayID(rawValue: "gw-a:8080")
    private let b = GatewayID(rawValue: "gw-b")

    private func seed(_ store: SwiftDataCacheStore, gateway: GatewayID) async throws {
        try await store.saveHistory(
            SessionHistory(sessionID: "s1", count: 2, messages: [
                SessionMessage(role: .user, text: "synthetic question", timestamp: 1, rowID: "r1"),
                SessionMessage(role: .assistant, text: "synthetic answer", timestamp: 2, rowID: "r2"),
            ]),
            for: gateway)
        try await store.saveHistory(
            SessionHistory(sessionID: "s2", count: 1, messages: [
                SessionMessage(role: .user, text: "another", timestamp: 3, rowID: "r3"),
            ]),
            for: gateway)
        try await store.saveWatermark(SessionEventWatermark(sessionID: "s1", lastSeenSeq: 7), for: gateway)
        try await store.saveReplayEpoch("epoch-\(gateway.rawValue)", for: gateway)
        try await store.saveHealthStats(
            GatewayHealthStats(currentState: .online, connectedMilliseconds: 10),
            for: gateway)
        try await store.saveGatewayRecord(StoredGatewayRecord(
            id: gateway.rawValue, displayName: "Synthetic", endpoint: "https://gateway.example.invalid"))
        let ctx = ModelContext(store.container)
        ctx.insert(LearningGraphSnapshotRow(
            gatewayID: gateway.rawValue, profileSlug: "p", capturedAt: 1, totalCount: 1, payload: Data("{}".utf8)))
        ctx.insert(ProjectsSnapshotRow(
            gatewayID: gateway.rawValue, profileSlug: "p", capturedAt: 1, projectCount: 1, payload: Data("{}".utf8)))
        ctx.insert(LaunchRosterRow(gatewayID: gateway.rawValue, payload: Data("{}".utf8), cachedAt: Date()))
        ctx.insert(LaunchSessionListRow(
            routeKey: "\(gateway.rawValue)#profile", payload: Data("{}".utf8), cachedAt: Date()))
        try ctx.save()
    }

    /// Row counts per gateway across every gateway-keyed model.
    private struct Counts: Equatable {
        var messages = 0, watermarks = 0, epochs = 0, health = 0
        var learning = 0, projects = 0, launchRoster = 0, launchSessions = 0, records = 0
        var total: Int { messages + watermarks + epochs + health + learning + projects + launchRoster + launchSessions }
    }

    private func counts(_ store: SwiftDataCacheStore, gateway: GatewayID) throws -> Counts {
        let key = gateway.rawValue
        let ctx = ModelContext(store.container)
        var result = Counts()
        result.messages = try ctx.fetch(FetchDescriptor<CachedMessageRow>()).filter { $0.gatewayID == key }.count
        result.watermarks = try ctx.fetch(FetchDescriptor<CachedWatermarkRow>()).filter { $0.gatewayID == key }.count
        result.epochs = try ctx.fetch(FetchDescriptor<CachedReplayEpochRow>()).filter { $0.gatewayID == key }.count
        result.health = try ctx.fetch(FetchDescriptor<CachedHealthStatsRow>()).filter { $0.gatewayID == key }.count
        result.learning = try ctx.fetch(FetchDescriptor<LearningGraphSnapshotRow>()).filter { $0.gatewayID == key }.count
        result.projects = try ctx.fetch(FetchDescriptor<ProjectsSnapshotRow>()).filter { $0.gatewayID == key }.count
        result.launchRoster = try ctx.fetch(FetchDescriptor<LaunchRosterRow>()).filter { $0.gatewayID == key }.count
        result.launchSessions = try ctx.fetch(FetchDescriptor<LaunchSessionListRow>())
            .filter { $0.routeKey.hasPrefix("\(key)#") }.count
        result.records = try ctx.fetch(FetchDescriptor<CachedGatewayRow>()).filter { $0.gatewayID == key }.count
        return result
    }

    func testPurgeGatewayRemovesEveryRowForThatGatewayOnly() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        try await seed(store, gateway: a)
        try await seed(store, gateway: aPrefixed)
        try await seed(store, gateway: b)

        let beforeA = try counts(store, gateway: a)
        XCTAssertEqual(beforeA.messages, 3)
        XCTAssertEqual(beforeA.total, 3 + 1 + 1 + 1 + 1 + 1 + 1 + 1, "every model is seeded")
        let beforePrefixed = try counts(store, gateway: aPrefixed)
        let beforeB = try counts(store, gateway: b)

        try await store.purgeGateway(a)

        let afterA = try counts(store, gateway: a)
        XCTAssertEqual(afterA.total, 0, "no gateway-keyed row remains for the purged gateway")
        XCTAssertEqual(try counts(store, gateway: aPrefixed), beforePrefixed,
                       "a gateway whose id merely starts with the purged id is untouched")
        XCTAssertEqual(try counts(store, gateway: b), beforeB)
        let history = try await store.loadHistory(sessionID: "s1", for: a)
        XCTAssertNil(history)
        let otherHistory = try await store.loadHistory(sessionID: "s1", for: b)
        XCTAssertEqual(otherHistory?.messages.count, 2)
    }

    func testPurgeGatewayLeavesSavedGatewayRecordToTheRegistry() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        try await seed(store, gateway: a)
        try await store.purgeGateway(a)
        XCTAssertEqual(try counts(store, gateway: a).records, 1,
                       "the saved-gateway record is owned by the registry, not the cache purge")
    }

    func testPurgeUnknownGatewayIsANoOp() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        try await seed(store, gateway: b)
        let before = try counts(store, gateway: b)
        try await store.purgeGateway(a)
        XCTAssertEqual(try counts(store, gateway: b), before)
    }

    func testPurgeIsIdempotent() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        try await seed(store, gateway: a)
        try await store.purgeGateway(a)
        try await store.purgeGateway(a)
        XCTAssertEqual(try counts(store, gateway: a).total, 0)
    }
}
