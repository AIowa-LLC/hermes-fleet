import Foundation
import SwiftData
import FleetCore

/// ADR-0012 (Instant Fleet): SwiftData-backed launch cache. Persists the
/// last-good per-gateway bot lists and per-route session summaries so cold
/// launch paints the fleet before any network work. 7-day TTL (Hermex
/// parity); maintenance on write prunes expired rows and orphans (gateway
/// ids the caller no longer knows are pruned via `prune(to:)` at read time
/// by AppEnvironment, which owns the registry). **No credentials ever.**
///
/// Shape note: the DTOs are small and few (one row per gateway + one per
/// bot-route + one per session-route); storing each as a JSON payload row
/// keeps the schema at THREE models total and makes the wire format the
/// version boundary (unknown/undecodable rows are discarded fail-open, not
/// migrated).
@Model
final public class LaunchRosterRow {
    @Attribute(.unique) public var gatewayID: String
    public var payload: Data
    public var cachedAt: Date

    public init(gatewayID: String, payload: Data, cachedAt: Date) {
        self.gatewayID = gatewayID
        self.payload = payload
        self.cachedAt = cachedAt
    }
}

@Model
final public class LaunchSessionListRow {
    /// Route identity: "gateway/slug" (stable, unique per route).
    @Attribute(.unique) public var routeKey: String
    public var payload: Data
    public var cachedAt: Date

    public init(routeKey: String, payload: Data, cachedAt: Date) {
        self.routeKey = routeKey
        self.payload = payload
        self.cachedAt = cachedAt
    }
}

public actor SwiftDataLaunchCacheStore: FleetLaunchCaching {
    private let container: ModelContainer

    /// Shares the app's cache-store container (same non-secret posture and
    /// file protection) or stands alone in-memory for tests/previews.
    public init(container: ModelContainer) {
        self.container = container
    }

    private static let ttl = FleetLaunchCachePolicy.ttl

    public func loadRosterCache() async throws -> [CachedGatewayRoster] {
        let ctx = ModelContext(container)
        let now = Date()
        let rows = try ctx.fetch(FetchDescriptor<LaunchRosterRow>())
        return rows.compactMap { row in
            guard now.timeIntervalSince(row.cachedAt) < Self.ttl else { return nil }
            guard let entry = try? JSONDecoder().decode(CachedGatewayRoster.self, from: row.payload) else {
                // Fail-open: an undecodable row is stale wire format — drop it.
                return nil
            }
            return entry
        }
    }

    public func loadSessionListCache() async throws -> [CachedSessionList] {
        let ctx = ModelContext(container)
        let now = Date()
        let rows = try ctx.fetch(FetchDescriptor<LaunchSessionListRow>())
        return rows.compactMap { row in
            guard now.timeIntervalSince(row.cachedAt) < Self.ttl else { return nil }
            guard let entry = try? JSONDecoder().decode(CachedSessionList.self, from: row.payload) else {
                return nil
            }
            return entry
        }
    }

    public func saveRosterCache(_ entry: CachedGatewayRoster) async throws {
        let ctx = ModelContext(container)
        let key = entry.gatewayID.rawValue
        let payload = try JSONEncoder().encode(entry)
        let existing = try ctx.fetch(FetchDescriptor<LaunchRosterRow>(
            predicate: #Predicate { $0.gatewayID == key }
        ))
        if let row = existing.first {
            row.payload = payload
            row.cachedAt = entry.cachedAt
        } else {
            ctx.insert(LaunchRosterRow(gatewayID: key, payload: payload, cachedAt: entry.cachedAt))
        }
        // Maintenance: prune expired rows on every write (Hermex pattern).
        let cutoff = Date().addingTimeInterval(-Self.ttl)
        let stale = try ctx.fetch(FetchDescriptor<LaunchRosterRow>(
            predicate: #Predicate { $0.cachedAt < cutoff }
        ))
        stale.forEach { ctx.delete($0) }
        try ctx.save()
    }

    public func saveSessionListCache(_ entry: CachedSessionList) async throws {
        let ctx = ModelContext(container)
        let key = "\(entry.route.gatewayID.rawValue)/\(entry.route.profileSlug.rawValue)"
        let payload = try JSONEncoder().encode(entry)
        let existing = try ctx.fetch(FetchDescriptor<LaunchSessionListRow>(
            predicate: #Predicate { $0.routeKey == key }
        ))
        if let row = existing.first {
            row.payload = payload
            row.cachedAt = entry.cachedAt
        } else {
            ctx.insert(LaunchSessionListRow(routeKey: key, payload: payload, cachedAt: entry.cachedAt))
        }
        let cutoff = Date().addingTimeInterval(-Self.ttl)
        let stale = try ctx.fetch(FetchDescriptor<LaunchSessionListRow>(
            predicate: #Predicate { $0.cachedAt < cutoff }
        ))
        stale.forEach { ctx.delete($0) }
        try ctx.save()
    }

    public func clearLaunchCache() async throws {
        let ctx = ModelContext(container)
        try ctx.delete(model: LaunchRosterRow.self)
        try ctx.delete(model: LaunchSessionListRow.self)
        try ctx.save()
    }
}
