import Foundation
import SwiftData
import FleetCore

/// ADR-0012 (Instant Fleet): SwiftData-backed launch cache. Persists the
/// last-good per-gateway bot lists and per-route session summaries so cold
/// launch paints the fleet before any network work. 7-day TTL (Hermex
/// parity); reads discard expired rows, and ORPHANS are pruned at the two
/// moments a gateway can leave the app's world: removing a gateway drops its
/// rows (`removeLaunchCache(for:)` — the FOS-4 precedent), and every settled
/// roster write-through sweeps rows for gateways the registry no longer knows
/// (`prune(keeping:)`, decision 2's "orphan pruning on write"). **No
/// credentials ever.**
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
        // Canonical route identity ("gw#slug"): components reject `#` (M9), and
        // unlike the old "gw/slug" concatenation this cannot be collided by
        // wire-derived slugs that carry `/` (e.g. "b/c" vs gateway "a/b").
        let key = entry.route.id
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

    public func removeLaunchCache(for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let key = gatewayID.rawValue
        let rosterRows = try ctx.fetch(FetchDescriptor<LaunchRosterRow>(
            predicate: #Predicate { $0.gatewayID == key }
        ))
        rosterRows.forEach { ctx.delete($0) }
        // Session rows are keyed by the canonical route id ("<gateway>#<slug>"),
        // written only since b771504 (the pre-canonical "gw/slug" format never
        // shipped a row) and unambiguous because route components reject `#`.
        let listRows = try ctx.fetch(FetchDescriptor<LaunchSessionListRow>())
        for row in listRows where Self.routeKey(row.routeKey, belongsToGateway: key) {
            ctx.delete(row)
        }
        try ctx.save()
    }

    public func prune(keeping gatewayIDs: Set<GatewayID>) async throws {
        let ctx = ModelContext(container)
        let keep = Set(gatewayIDs.map(\.rawValue))
        let rosterRows = try ctx.fetch(FetchDescriptor<LaunchRosterRow>())
        for row in rosterRows where !keep.contains(row.gatewayID) {
            ctx.delete(row)
        }
        let listRows = try ctx.fetch(FetchDescriptor<LaunchSessionListRow>())
        for row in listRows where !keep.contains(Self.gatewayKey(ofRouteKey: row.routeKey)) {
            ctx.delete(row)
        }
        try ctx.save()
    }

    /// Whether a canonical route key (`<gateway>#<slug>`) belongs to the
    /// gateway. Gateway ids cannot contain the `#` separator (M9).
    private static func routeKey(_ routeKey: String, belongsToGateway id: String) -> Bool {
        gatewayKey(ofRouteKey: routeKey) == id
    }

    private static func gatewayKey(ofRouteKey routeKey: String) -> String {
        String(routeKey.prefix(while: { $0 != "#" }))
    }

    public func clearLaunchCache() async throws {
        let ctx = ModelContext(container)
        try ctx.delete(model: LaunchRosterRow.self)
        try ctx.delete(model: LaunchSessionListRow.self)
        try ctx.save()
    }
}
