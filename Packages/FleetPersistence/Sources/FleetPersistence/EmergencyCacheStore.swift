import FleetCore

/// Final fallback when SwiftData cannot create even an in-memory container.
/// Keeps new gateway registrations and health only for this process. Transcript
/// and replay/launch caching stay disabled, so reconnect reads authoritative state.
public actor EmergencyCacheStore: CacheStoring, GatewayRecordStoring, HealthStatsStoring, FleetLaunchCaching {
    private var records: [String: StoredGatewayRecord] = [:]
    private var health: [GatewayID: GatewayHealthStats] = [:]
    private var removedGateways: Set<GatewayID> = []

    public init() {}

    public func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {
        records[record.id] = record
        removedGateways.remove(GatewayID(rawValue: record.id))
    }
    public func deleteGatewayRecord(id: GatewayID) async throws { records[id.rawValue] = nil }
    public func loadGatewayRecords() async throws -> [StoredGatewayRecord] {
        records.values.sorted { $0.id < $1.id }
    }
    public func saveHealthStats(_ stats: GatewayHealthStats, for gatewayID: GatewayID) async throws {
        guard !removedGateways.contains(gatewayID) else { return }
        health[gatewayID] = stats
    }
    public func loadHealthStats(for gatewayID: GatewayID) async throws -> GatewayHealthStats? { health[gatewayID] }
    public func deleteHealthStats(for gatewayID: GatewayID) async throws { health[gatewayID] = nil }
    public func purgeGateway(_ id: GatewayID) async throws {
        removedGateways.insert(id)
        health[id] = nil
    }
    public func clearCachedData() async throws { health.removeAll() }
    public func saveHistory(_ history: SessionHistory, for gatewayID: GatewayID) async throws {}
    public func loadHistory(sessionID: String, for gatewayID: GatewayID) async throws -> SessionHistory? { nil }
    public func deleteHistory(sessionID: String, for gatewayID: GatewayID) async throws {}
    public func saveWatermark(_ watermark: SessionEventWatermark, for gatewayID: GatewayID) async throws {}
    public func loadWatermarks() async throws -> [SessionEventWatermark] { [] }
    public func clearWatermarks() async throws {}
    public func saveReplayEpoch(_ epoch: String?, for gatewayID: GatewayID) async throws {}
    public func loadReplayEpoch(for gatewayID: GatewayID) async throws -> String? { nil }
    public func resetForReplayEpochChange(gatewayID: GatewayID) async throws {}

    // Launch-cache writes are disabled in the no-container recovery mode too:
    // a delayed roster/session read must not recreate removed-gateway data.
    public func loadRosterCache() async throws -> [CachedGatewayRoster] { [] }
    public func loadSessionListCache() async throws -> [CachedSessionList] { [] }
    public func saveRosterCache(_ entry: CachedGatewayRoster) async throws {}
    public func saveSessionListCache(_ entry: CachedSessionList) async throws {}
    public func removeLaunchCache(for gatewayID: GatewayID) async throws {}
    public func prune(keeping gatewayIDs: Set<GatewayID>) async throws {}
    public func clearLaunchCache() async throws {}
}
