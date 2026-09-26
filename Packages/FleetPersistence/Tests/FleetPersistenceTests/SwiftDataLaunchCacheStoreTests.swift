import XCTest
import Foundation
import SwiftData
import FleetCore
@testable import FleetPersistence

/// Regression (OCR review, 2026-09-22): the ADR-0012 launch cache rides the
/// SHARED cache container, but the container's schema did not include the
/// launch-cache row models — every fetch/insert targeted an entity outside
/// the schema, so the production cache silently degraded to "no cache" while
/// the in-memory test twin kept suites green.
///
/// These tests exercise the production seam exactly as FleetServiceGraph
/// wires it: a store built by the shared factories handed to
/// `SwiftDataLaunchCacheStore`.
final class SwiftDataLaunchCacheStoreTests: XCTestCase {

    private let m5 = GatewayID(rawValue: "workstation")
    /// Recent, exactly-representable instant — inside the 7-day TTL and safe
    /// for JSON round-trips (Date equality on decoded payloads).
    private let recent = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeSharedSeam() async throws -> SwiftDataLaunchCacheStore {
        let cacheStore = try SwiftDataCacheStore.makeInMemory()
        return SwiftDataLaunchCacheStore(container: cacheStore.container)
    }

    func testRosterCacheRoundTripsOnSharedContainer() async throws {
        let launchCache = try await makeSharedSeam()
        let entry = CachedGatewayRoster(gatewayID: m5, bots: [], cachedAt: recent)
        try await launchCache.saveRosterCache(entry)
        let loaded = try await launchCache.loadRosterCache()
        XCTAssertEqual(loaded.count, 1, "roster cache row must persist on the shared container schema")
        XCTAssertEqual(loaded.first?.gatewayID, m5)
        XCTAssertEqual(loaded.first, entry)
    }

    func testSessionListCacheRoundTripsOnSharedContainer() async throws {
        let launchCache = try await makeSharedSeam()
        let route = Route(gatewayID: m5, profileSlug: ProfileSlug(rawValue: "default"))
        let entry = CachedSessionList(route: route, sessions: [], cachedAt: recent)
        try await launchCache.saveSessionListCache(entry)
        let loaded = try await launchCache.loadSessionListCache()
        XCTAssertEqual(loaded.count, 1, "session-list cache row must persist on the shared container schema")
        XCTAssertEqual(loaded.first?.route, route)
        XCTAssertEqual(loaded.first, entry)
    }

    func testClearLaunchCacheEmptiesBothSurfaces() async throws {
        let launchCache = try await makeSharedSeam()
        let route = Route(gatewayID: m5, profileSlug: ProfileSlug(rawValue: "default"))
        try await launchCache.saveRosterCache(CachedGatewayRoster(gatewayID: m5, bots: [], cachedAt: recent))
        try await launchCache.saveSessionListCache(CachedSessionList(route: route, sessions: [], cachedAt: recent))
        try await launchCache.clearLaunchCache()
        let rosters = try await launchCache.loadRosterCache()
        let lists = try await launchCache.loadSessionListCache()
        XCTAssertEqual(rosters, [])
        XCTAssertEqual(lists, [])
    }
}

// MARK: - Additive schema migration (existing installs)

extension SwiftDataLaunchCacheStoreTests {

    /// An existing install has a store file created with the pre-launch-cache
    /// schema. Opening it with the production factory (which now includes the
    /// launch rows) must succeed — this is the additive lightweight migration
    /// path every existing device hits after the b771504 fix.
    func testExistingStoreOpensAfterLaunchModelsAdded() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cache.store")

        // 1. Pre-fix schema (7 models) — as an existing install's file.
        do {
            let config = ModelConfiguration(url: url)
            _ = try ModelContainer(
                for: CachedMessageRow.self, CachedWatermarkRow.self, CachedReplayEpochRow.self,
                     CachedHealthStatsRow.self, CachedGatewayRow.self, LearningGraphSnapshotRow.self,
                     ProjectsSnapshotRow.self,
                configurations: config
            )
        }

        // 2. Re-open with the production factory (9 models) — must migrate.
        let store = try SwiftDataCacheStore.makeFileBacked(storeURL: url)
        let launchCache = SwiftDataLaunchCacheStore(container: store.container)
        try await launchCache.saveRosterCache(CachedGatewayRoster(gatewayID: m5, bots: [], cachedAt: recent))
        let loaded = try await launchCache.loadRosterCache()
        XCTAssertEqual(loaded.count, 1, "launch rows must be writable after additive migration")
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - ADR-0012 decision 2: orphan pruning

extension SwiftDataLaunchCacheStoreTests {

    /// Removing a gateway drops ITS rows — roster entry and every session row
    /// on its routes — while other gateways' rows survive. (OCR review: the
    /// doc promised orphan pruning that did not exist; a removed gateway's bot
    /// list and session titles stayed on disk for the full 7-day TTL.)
    func testRemoveLaunchCacheDropsOnlyThatGatewaysRows() async throws {
        let launchCache = try await makeSharedSeam()
        let other = GatewayID(rawValue: "render-box")
        let m5Route = Route(gatewayID: m5, profileSlug: ProfileSlug(rawValue: "default"))
        let otherRoute = Route(gatewayID: other, profileSlug: ProfileSlug(rawValue: "default"))
        try await launchCache.saveRosterCache(CachedGatewayRoster(gatewayID: m5, bots: [], cachedAt: recent))
        try await launchCache.saveRosterCache(CachedGatewayRoster(gatewayID: other, bots: [], cachedAt: recent))
        try await launchCache.saveSessionListCache(CachedSessionList(route: m5Route, sessions: [], cachedAt: recent))
        try await launchCache.saveSessionListCache(CachedSessionList(route: otherRoute, sessions: [], cachedAt: recent))

        try await launchCache.removeLaunchCache(for: m5)

        let rosters = try await launchCache.loadRosterCache()
        let lists = try await launchCache.loadSessionListCache()
        XCTAssertEqual(rosters.map(\.gatewayID), [other], "the removed gateway's roster row is gone")
        XCTAssertEqual(lists.map(\.route), [otherRoute], "the removed gateway's session rows are gone")
    }

    /// A route key that merely CONTAINS the removed gateway id (a different
    /// gateway whose id is a prefix, or a slug carrying the id) is untouched:
    /// the canonical key is `<gateway>#<slug>` and components reject `#`.
    func testRemoveLaunchCacheDoesNotTouchPrefixLookalikeGateway() async throws {
        let launchCache = try await makeSharedSeam()
        let lookalike = GatewayID(rawValue: "workstation-2")
        let lookalikeRoute = Route(gatewayID: lookalike, profileSlug: ProfileSlug(rawValue: "default"))
        try await launchCache.saveSessionListCache(CachedSessionList(route: lookalikeRoute, sessions: [], cachedAt: recent))

        try await launchCache.removeLaunchCache(for: m5)

        let lists = try await launchCache.loadSessionListCache()
        XCTAssertEqual(lists.map(\.route), [lookalikeRoute],
                       "only rows on the removed gateway's own routes are pruned")
    }

    /// Write-time sweep: rows for gateways the registry still knows survive
    /// (even unanswered ones — the persisted FOS-5 ghost), rows for gateways
    /// it no longer knows are deleted.
    func testPruneKeepingRegistryGatewaysSweepsOnlyOrphans() async throws {
        let launchCache = try await makeSharedSeam()
        let orphan = GatewayID(rawValue: "decommissioned")
        let m5Route = Route(gatewayID: m5, profileSlug: ProfileSlug(rawValue: "default"))
        let orphanRoute = Route(gatewayID: orphan, profileSlug: ProfileSlug(rawValue: "default"))
        try await launchCache.saveRosterCache(CachedGatewayRoster(gatewayID: m5, bots: [], cachedAt: recent))
        try await launchCache.saveRosterCache(CachedGatewayRoster(gatewayID: orphan, bots: [], cachedAt: recent))
        try await launchCache.saveSessionListCache(CachedSessionList(route: m5Route, sessions: [], cachedAt: recent))
        try await launchCache.saveSessionListCache(CachedSessionList(route: orphanRoute, sessions: [], cachedAt: recent))

        try await launchCache.prune(keeping: [m5])

        let rosters = try await launchCache.loadRosterCache()
        let lists = try await launchCache.loadSessionListCache()
        XCTAssertEqual(rosters.map(\.gatewayID), [m5])
        XCTAssertEqual(lists.map(\.route), [m5Route])
    }
}

extension SwiftDataLaunchCacheStoreTests {

    /// Route components reject `/` and `#` only in the VALIDATING initializer;
    /// plain init and wire-derived slugs can carry `/`. With the old
    /// `"gw/profile"` key, ("a", "b/c") and ("a/b", "c") both persisted to
    /// "a/b/c" and overwrote each other. The canonical `Route.id` ("#") keeps
    /// them distinct.
    func testSessionListCacheKeysDoNotCollideOnSlashProfiles() async throws {
        let launchCache = try await makeSharedSeam()
        let routeA = Route(gatewayID: GatewayID(rawValue: "a"), profileSlug: ProfileSlug(rawValue: "b/c"))
        let routeB = Route(gatewayID: GatewayID(rawValue: "a/b"), profileSlug: ProfileSlug(rawValue: "c"))
        try await launchCache.saveSessionListCache(CachedSessionList(route: routeA, sessions: [], cachedAt: recent))
        try await launchCache.saveSessionListCache(CachedSessionList(route: routeB, sessions: [], cachedAt: recent))
        let loaded = try await launchCache.loadSessionListCache()
        XCTAssertEqual(Set(loaded.map(\.route)), Set([routeA, routeB]),
                       "distinct routes must persist as distinct rows (no key collision)")
    }
}
