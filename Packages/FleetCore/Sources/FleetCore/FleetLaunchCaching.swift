import Foundation

/// ADR-0012 (Instant Fleet): the launch-cache seam. FleetUI reads/writes
/// through this protocol; FleetPersistence provides the SwiftData-backed
/// concrete. **Structurally no credentials** — roster DTOs and session
/// summaries only (tokens/tickets stay in Keychain).
public protocol FleetLaunchCaching: Sendable {
    /// All unexpired roster entries (per gateway).
    func loadRosterCache() async throws -> [CachedGatewayRoster]
    /// All unexpired session-list entries (per route).
    func loadSessionListCache() async throws -> [CachedSessionList]
    /// Replace the roster entry for one gateway (`nil` bots clears it —
    /// empty-is-authoritative).
    func saveRosterCache(_ entry: CachedGatewayRoster) async throws
    /// Replace the session-list entry for one route.
    func saveSessionListCache(_ entry: CachedSessionList) async throws
    /// ADR-0012 decision 2 — orphan pruning. Drop every row belonging to one
    /// gateway (its roster entry and every session-list row on its routes).
    /// Called when the user removes a gateway (FOS-4 precedent: a removed
    /// source's cached rows must not outlive it).
    func removeLaunchCache(for gatewayID: GatewayID) async throws
    /// ADR-0012 decision 2 — orphan pruning on write. Drop every row whose
    /// gateway is NOT in `gatewayIDs` (the registry's current set), keeping
    /// rows for registered gateways even when their last refresh failed
    /// (FOS-5 persisted-ghost semantics). Called from the settled roster
    /// write-through.
    func prune(keeping gatewayIDs: Set<GatewayID>) async throws
    /// Drop everything (Data & Storage clear + UI-test hygiene).
    func clearLaunchCache() async throws
}

/// In-memory default for previews/tests — also the DEBUG-only seam the
/// simulator fixture knob seeds (spec W8: HERMES_FLEET_LAUNCH_CACHE_FIXTURE).
public actor InMemoryLaunchCache: FleetLaunchCaching {
    private var rosters: [GatewayID: CachedGatewayRoster] = [:]
    private var lists: [Route: CachedSessionList] = [:]
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func loadRosterCache() async throws -> [CachedGatewayRoster] {
        rosters.values.filter { now().timeIntervalSince($0.cachedAt) < FleetLaunchCachePolicy.ttl }
    }

    public func loadSessionListCache() async throws -> [CachedSessionList] {
        lists.values.filter { now().timeIntervalSince($0.cachedAt) < FleetLaunchCachePolicy.ttl }
    }

    public func saveRosterCache(_ entry: CachedGatewayRoster) async throws {
        rosters[entry.gatewayID] = entry
    }

    public func saveSessionListCache(_ entry: CachedSessionList) async throws {
        lists[entry.route] = entry
    }

    public func removeLaunchCache(for gatewayID: GatewayID) async throws {
        rosters[gatewayID] = nil
        lists = lists.filter { $0.key.gatewayID != gatewayID }
    }

    public func prune(keeping gatewayIDs: Set<GatewayID>) async throws {
        rosters = rosters.filter { gatewayIDs.contains($0.key) }
        lists = lists.filter { gatewayIDs.contains($0.key.gatewayID) }
    }

    public func clearLaunchCache() async throws {
        rosters.removeAll()
        lists.removeAll()
    }
}
