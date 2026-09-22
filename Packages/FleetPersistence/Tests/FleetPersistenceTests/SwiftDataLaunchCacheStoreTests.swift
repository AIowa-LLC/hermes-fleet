import XCTest
import Foundation
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
