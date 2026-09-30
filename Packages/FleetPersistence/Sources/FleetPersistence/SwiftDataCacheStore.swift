import Foundation
import SwiftData
import FleetCore

/// SwiftData-backed non-secret cache (synthesis §12): caches session/event
/// history + seq watermarks + last replay_epoch for relaunch-resume; a stale
/// replay_epoch triggers a fail-closed reset. **Structurally no credentials:
/// every model holds only non-secret transcript/watermark fields — tokens and
/// tickets live exclusively in Keychain (`TokenStoring`), never here.**
///
/// Implements `CacheStoring` (FleetCore) so the replay/service layer and the
/// app composition root depend on the protocol, not on SwiftData (mirrors the
/// M7 seam pattern).
///
/// Concurrency: this is an `actor` owning a `ModelContainer` (@unchecked
/// Sendable). Each operation creates its own `ModelContext` inside the actor,
/// so a context is never shared across concurrency contexts (SwiftData
/// requirement). The cache is intentionally small and bounded (transcripts +
/// watermarks per registered gateway).
public actor SwiftDataCacheStore: CacheStoring, GatewayRecordStoring {
    /// The SwiftData container backing this cache. In-memory in tests /
    /// previews; file-backed in the app with NSFileProtectionComplete +
    /// backup-exclusion applied to the store file. Public read-only so the
    /// composition root can share the container with the ADR-0012 launch
    /// cache (same non-secret posture + file protection, distinct models).
    /// `nonisolated` (immutable + Sendable) so the composition root can
    /// read it without crossing the actor boundary (the `storeURL` pattern).
    nonisolated public let container: ModelContainer

    /// Where the file-backed store lives (nil for in-memory). Used to apply
    /// and verify file-protection attributes. Immutable and Sendable, so it is
    /// `nonisolated` — readable without crossing the actor boundary.
    nonisolated public let storeURL: URL?

    /// Non-fatal protection failures from opening the store (directory,
    /// `-wal`/`-shm` sidecars). Type-only (`LocalFileProtection.Failure`), so
    /// the composition root can hand them to the redacted diagnostics ring.
    /// Empty for in-memory stores and for a fully protected store.
    nonisolated public let protectionFailures: [LocalFileProtection.Failure]

    /// The first successful write re-applies protection: the `-wal` sidecar is
    /// created lazily and may not have existed when the store opened.
    private var didReprotectAfterFirstWrite = false
    private var lateProtectionFailures: [LocalFileProtection.Failure] = []

    public init(
        container: ModelContainer,
        storeURL: URL? = nil,
        protectionFailures: [LocalFileProtection.Failure] = []
    ) {
        self.container = container
        self.storeURL = storeURL
        self.protectionFailures = protectionFailures
    }

    /// Commit a context, then (once) re-apply file protection to the store
    /// family so a sidecar created by this first write is covered explicitly
    /// on top of directory inheritance.
    private func commit(_ ctx: ModelContext) throws {
        try ctx.save()
        guard !didReprotectAfterFirstWrite, let storeURL else { return }
        didReprotectAfterFirstWrite = true
        lateProtectionFailures = CacheStoreProtection.protect(storeURL: storeURL)
    }

    /// Re-apply and read back the protection of the store directory, store
    /// file and any present `-wal`/`-shm` sidecars. nil for in-memory stores.
    /// Used by diagnostics and tests; failures are reported, never thrown.
    public func verifyProtection() -> CacheStoreProtectionReport? {
        guard let storeURL else { return nil }
        let failures = CacheStoreProtection.protect(storeURL: storeURL)
        lateProtectionFailures = failures
        return CacheStoreProtection.verify(storeURL: storeURL, failures: failures)
    }

    /// Failures from the post-first-write re-application (empty until a write
    /// has happened).
    public func lateProtectionFailureList() -> [LocalFileProtection.Failure] {
        lateProtectionFailures
    }

    // MARK: CacheStoring

    public func saveHistory(_ history: SessionHistory, for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        // Replace semantics: delete any existing transcript for this pair,
        // then insert the fresh rows in order.
        let descriptor = FetchDescriptor<CachedMessageRow>()
        let existing = try ctx.fetch(descriptor)
        for row in existing where row.gatewayID == gatewayID.rawValue && row.sessionID == history.sessionID {
            ctx.delete(row)
        }
        for (index, message) in history.messages.enumerated() {
            ctx.insert(CachedMessageRow(
                gatewayID: gatewayID.rawValue,
                sessionID: history.sessionID,
                order: index,
                role: message.role.wireValue,
                text: message.text,
                timestamp: message.timestamp,
                rowID: message.rowID,
                displayKind: message.displayKind,
                reasoning: message.reasoning,
                toolName: message.toolName,
                toolContext: message.toolContext,
                reactionsData: Self.encodeReactions(message.reactions),
                clientID: message.clientID
            ))
        }
        try commit(ctx)
    }

    public func loadHistory(sessionID: String, for gatewayID: GatewayID) async throws -> SessionHistory? {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedMessageRow>())
        let matching = rows
            .filter { $0.gatewayID == gatewayID.rawValue && $0.sessionID == sessionID }
            .sorted { $0.order < $1.order }
        guard !matching.isEmpty else { return nil }
        let messages = matching.map { row in
            SessionMessage(
                role: SessionMessageRole(wire: row.role),
                text: row.text,
                timestamp: row.timestamp,
                rowID: row.rowID,
                displayKind: row.displayKind,
                reasoning: row.reasoning,
                toolName: row.toolName,
                toolContext: row.toolContext,
                reactions: Self.decodeReactions(row.reactionsData),
                clientID: row.clientID
            )
        }
        return SessionHistory(sessionID: sessionID, count: messages.count, messages: messages)
    }

    // MARK: R10-T2 reactions column codec

    /// One persisted reaction entry (Codable mirror of `MessageReaction`).
    private struct CachedReaction: Codable {
        let emoji: String
        let author: String
        let at: Double?
    }

    /// `[MessageReaction]?` → JSON string. nil stays nil; an EMPTY list
    /// encodes as `"[]"` so "disclosed none" survives the round trip
    /// distinct from "not disclosed".
    nonisolated private static func encodeReactions(_ reactions: [MessageReaction]?) -> String? {
        guard let reactions else { return nil }
        let entries = reactions.map { CachedReaction(emoji: $0.emoji, author: $0.author, at: $0.at) }
        guard let data = try? JSONEncoder().encode(entries) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// JSON string → `[MessageReaction]?`. nil / undecodable → nil (honest
    /// not-disclosed); `"[]"` → `[]` (disclosed none).
    nonisolated private static func decodeReactions(_ json: String?) -> [MessageReaction]? {
        guard let json, let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([CachedReaction].self, from: data)
        else { return nil }
        return entries.map { MessageReaction(emoji: $0.emoji, author: $0.author, at: $0.at) }
    }

    public func deleteHistory(sessionID: String, for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedMessageRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue && row.sessionID == sessionID {
            ctx.delete(row)
        }
        try commit(ctx)
    }

    public func saveWatermark(_ watermark: SessionEventWatermark, for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedWatermarkRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue && row.sessionID == watermark.sessionID {
            ctx.delete(row)
        }
        ctx.insert(CachedWatermarkRow(
            gatewayID: gatewayID.rawValue,
            sessionID: watermark.sessionID,
            lastSeenSeq: watermark.lastSeenSeq
        ))
        try commit(ctx)
    }

    public func loadWatermarks() async throws -> [SessionEventWatermark] {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedWatermarkRow>())
        return rows.map { SessionEventWatermark(sessionID: $0.sessionID, lastSeenSeq: $0.lastSeenSeq) }
    }

    public func clearWatermarks() async throws {
        let ctx = ModelContext(container)
        for row in try ctx.fetch(FetchDescriptor<CachedWatermarkRow>()) {
            ctx.delete(row)
        }
        try commit(ctx)
    }

    public func saveReplayEpoch(_ epoch: String?, for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedReplayEpochRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        ctx.insert(CachedReplayEpochRow(gatewayID: gatewayID.rawValue, epoch: epoch))
        try commit(ctx)
    }

    public func loadReplayEpoch(for gatewayID: GatewayID) async throws -> String? {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedReplayEpochRow>())
        return rows.first { $0.gatewayID == gatewayID.rawValue }?.epoch
    }

    public func resetForReplayEpochChange(gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let messageRows = try ctx.fetch(FetchDescriptor<CachedMessageRow>())
        for row in messageRows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        let watermarkRows = try ctx.fetch(FetchDescriptor<CachedWatermarkRow>())
        for row in watermarkRows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        let epochRows = try ctx.fetch(FetchDescriptor<CachedReplayEpochRow>())
        for row in epochRows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        try commit(ctx)
    }

    /// Delete every gateway-keyed cache row for exactly one gateway (exact
    /// `gatewayID` match, never a prefix): transcript rows, watermarks, replay
    /// epoch, health stats, Learning/Projects snapshots and the ADR-0012 launch
    /// cache rows that share this container. Other gateways' rows and the
    /// saved-gateway record (`CachedGatewayRow`, owned by the registry) are
    /// untouched. Everything commits in one `save()`; deleting rows does not
    /// shrink the SQLite file or its `-wal`/`-shm` sidecars immediately.
    public func purgeGateway(_ id: GatewayID) async throws {
        let key = id.rawValue
        let ctx = ModelContext(container)
        try ctx.delete(model: CachedMessageRow.self, where: #Predicate { $0.gatewayID == key })
        try ctx.delete(model: CachedWatermarkRow.self, where: #Predicate { $0.gatewayID == key })
        try ctx.delete(model: CachedReplayEpochRow.self, where: #Predicate { $0.gatewayID == key })
        try ctx.delete(model: CachedHealthStatsRow.self, where: #Predicate { $0.gatewayID == key })
        try ctx.delete(model: LearningGraphSnapshotRow.self, where: #Predicate { $0.gatewayID == key })
        try ctx.delete(model: ProjectsSnapshotRow.self, where: #Predicate { $0.gatewayID == key })
        try ctx.delete(model: LaunchRosterRow.self, where: #Predicate { $0.gatewayID == key })
        for row in try ctx.fetch(FetchDescriptor<LaunchSessionListRow>())
        where SwiftDataLaunchCacheStore.routeKey(row.routeKey, belongsToGateway: key) {
            ctx.delete(row)
        }
        try commit(ctx)
    }

    /// Delete all privacy-bearing cached content but keep the saved gateway
    /// records intact. Credentials are not in this store and remain in the
    /// Keychain until the user removes a gateway.
    public func clearCachedData() async throws {
        let ctx = ModelContext(container)
        for row in try ctx.fetch(FetchDescriptor<CachedMessageRow>()) { ctx.delete(row) }
        for row in try ctx.fetch(FetchDescriptor<CachedWatermarkRow>()) { ctx.delete(row) }
        for row in try ctx.fetch(FetchDescriptor<CachedReplayEpochRow>()) { ctx.delete(row) }
        for row in try ctx.fetch(FetchDescriptor<CachedHealthStatsRow>()) { ctx.delete(row) }
        for row in try ctx.fetch(FetchDescriptor<LearningGraphSnapshotRow>()) { ctx.delete(row) }
        for row in try ctx.fetch(FetchDescriptor<ProjectsSnapshotRow>()) { ctx.delete(row) }
        try commit(ctx)
    }
}

// MARK: - HealthStatsStoring (H2 Connection health dashboard)

extension SwiftDataCacheStore: HealthStatsStoring {
    /// Replace the persisted health snapshot for a gateway (one row per
    /// gateway; last writer wins — the accumulator persists after every
    /// transition, so the row is always the latest observed state).
    public func saveHealthStats(_ stats: GatewayHealthStats, for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedHealthStatsRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        ctx.insert(CachedHealthStatsRow(
            gatewayID: gatewayID.rawValue,
            currentStateRaw: stats.currentState.rawValue,
            firstObservedAt: stats.firstObservedAt,
            lastTransitionAt: stats.lastTransitionAt,
            connectedMilliseconds: stats.connectedMilliseconds,
            disconnectedMilliseconds: stats.disconnectedMilliseconds,
            reconnectCount: stats.reconnectCount,
            lastDisconnectReason: stats.lastDisconnectReason,
            lastDisconnectAt: stats.lastDisconnectAt,
            lastPingRTTMilliseconds: stats.lastPingRTTMilliseconds,
            averagePingRTTMilliseconds: stats.averagePingRTTMilliseconds,
            pingSampleCount: stats.pingSampleCount
        ))
        try commit(ctx)
    }

    public func loadHealthStats(for gatewayID: GatewayID) async throws -> GatewayHealthStats? {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedHealthStatsRow>())
        guard let row = rows.first(where: { $0.gatewayID == gatewayID.rawValue }) else {
            return nil
        }
        return GatewayHealthStats(
            currentState: GatewayStatus(rawValue: row.currentStateRaw) ?? .offline,
            firstObservedAt: row.firstObservedAt,
            lastTransitionAt: row.lastTransitionAt,
            connectedMilliseconds: row.connectedMilliseconds,
            disconnectedMilliseconds: row.disconnectedMilliseconds,
            reconnectCount: row.reconnectCount,
            lastDisconnectReason: row.lastDisconnectReason,
            lastDisconnectAt: row.lastDisconnectAt,
            lastPingRTTMilliseconds: row.lastPingRTTMilliseconds,
            averagePingRTTMilliseconds: row.averagePingRTTMilliseconds,
            pingSampleCount: row.pingSampleCount
        )
    }

    public func deleteHealthStats(for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedHealthStatsRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        try commit(ctx)
    }

    // MARK: GatewayRecordStoring (P0-4 — durable gateway roster)

    public func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {
        let ctx = ModelContext(container)
        // Upsert semantics keyed by gateway id: delete-then-insert (the record
        // is non-secret presentation data — atomicity loss on a crash between
        // the two writes is a benign empty-slot re-add, not data corruption).
        let rows = try ctx.fetch(FetchDescriptor<CachedGatewayRow>())
        for row in rows where row.gatewayID == record.id {
            ctx.delete(row)
        }
        ctx.insert(CachedGatewayRow(
            gatewayID: record.id,
            displayName: record.displayName,
            endpoint: record.endpoint,
            authStrategyRaw: record.authConfiguration.strategy.rawValue,
            credentialStored: record.authConfiguration.credentialStored,
            authConfigured: record.authConfigured
        ))
        try commit(ctx)
    }

    public func deleteGatewayRecord(id: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedGatewayRow>())
        for row in rows where row.gatewayID == id.rawValue {
            ctx.delete(row)
        }
        try commit(ctx)
    }

    public func loadGatewayRecords() async throws -> [StoredGatewayRecord] {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<CachedGatewayRow>())
        return rows
            .sorted { $0.gatewayID < $1.gatewayID }
            .map { row in
                StoredGatewayRecord(
                    id: row.gatewayID,
                    displayName: row.displayName,
                    endpoint: row.endpoint,
                    authConfiguration: GatewayAuthConfiguration(
                        strategy: GatewayAuthConfiguration.Strategy(rawValue: row.authStrategyRaw) ?? .none,
                        credentialStored: row.credentialStored
                    ),
                    authConfigured: row.authConfigured
                )
            }
    }
}

// MARK: - Factories

public extension SwiftDataCacheStore {
    /// In-memory store for tests / previews (no file, no protection needed).
    /// Built through `FleetMigrationPlan` (schema V1), which also covers the
    /// ADR-0012 launch-cache row models that share this container.
    static func makeInMemory() throws -> SwiftDataCacheStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer.fleetCache(configuration: config)
        return SwiftDataCacheStore(container: container)
    }

    /// File-backed store at `storeURL`, applying NSFileProtectionComplete +
    /// backup-exclusion to the store file (spec §12 / synthesis §12). The
    /// parent directory is created if needed. On macOS (host package tests)
    /// file protection is not enforced, but backup exclusion is still applied
    /// and the store round-trips normally. Throws when the store cannot be
    /// opened; the app composition root uses `openWithRecovery` instead.
    static func makeFileBacked(storeURL: URL) throws -> SwiftDataCacheStore {
        let container = try openFileBackedContainer(storeURL: storeURL)
        // The store file is created eagerly at container init (verified); apply
        // the protection attributes now.
        // The store file itself is strict; the directory and `-wal`/`-shm`
        // sidecars are best-effort and reported through `protectionFailures`.
        try CacheStoreProtection.apply(to: storeURL)
        let failures = CacheStoreProtection.protect(storeURL: storeURL)
        return SwiftDataCacheStore(container: container, storeURL: storeURL, protectionFailures: failures)
    }

    /// Opens (creating if needed) the versioned container for `storeURL`.
    /// The containing directory is protected BEFORE the container opens, so the
    /// store and the `-wal`/`-shm` sidecars SQLite creates inherit its class at
    /// creation time. A directory-protection failure is non-fatal here; the
    /// caller's `CacheStoreProtection.protect` pass re-applies and reports it.
    internal static func openFileBackedContainer(storeURL: URL) throws -> ModelContainer {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try? LocalFileProtection.apply(to: directory)
        return try ModelContainer.fleetCache(configuration: ModelConfiguration(url: storeURL))
    }
}

/// The read-back of the store family's protection (P0.3c). One entry per
/// present path, by role; `failures` are the operations that could not be
/// applied. Type-only, safe for diagnostics.
public struct CacheStoreProtectionReport: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// `"directory"`, `"store"`, `"wal"` or `"shm"`.
        public let role: String
        public let attributes: LocalFileProtection.Attributes
    }

    public let entries: [Entry]
    public let failures: [LocalFileProtection.Failure]

    public var isFullyProtected: Bool {
        failures.isEmpty && !entries.isEmpty && entries.allSatisfy { $0.attributes.isProtected }
    }

    /// One-line, type-only summary for the diagnostics ring.
    public var diagnosticsDetail: String {
        let unprotected = entries.filter { !$0.attributes.isProtected }.map(\.role)
        if failures.isEmpty && unprotected.isEmpty { return "local cache files protected" }
        var parts = ["local cache protection incomplete"]
        if !unprotected.isEmpty { parts.append("unprotected: \(unprotected.joined(separator: ", "))") }
        parts.append(contentsOf: failures.map(\.diagnosticsDetail))
        return parts.joined(separator: "; ")
    }
}

/// Applies the on-disk cache protection attributes required by synthesis §12:
/// NSFileProtectionComplete + backup-excluded, so a device backup never ships
/// the (non-secret but privacy-bearing) transcript cache. Covers the whole
/// SQLite family: the store directory (new files inherit its class), the store
/// file, and the `-wal` / `-shm` sidecars. The policy itself lives in
/// `LocalFileProtection` (FleetCore) so the other local stores share it.
public enum CacheStoreProtection {
    public static func apply(to url: URL) throws {
        try LocalFileProtection.apply(to: url)
    }

    /// `-wal` and `-shm` sidecar locations for a store file.
    public static func sidecarURLs(for storeURL: URL) -> (wal: URL, shm: URL) {
        (URL(fileURLWithPath: storeURL.path + "-wal"), URL(fileURLWithPath: storeURL.path + "-shm"))
    }

    private static func family(of storeURL: URL) -> [(role: String, url: URL)] {
        let sidecars = sidecarURLs(for: storeURL)
        return [
            ("directory", storeURL.deletingLastPathComponent()),
            ("store", storeURL),
            ("wal", sidecars.wal),
            ("shm", sidecars.shm),
        ]
    }

    /// Apply the policy to the store directory first (so files created later
    /// inherit it), then the store file and any present sidecars. Best effort:
    /// failures are collected, never thrown, so the store stays available.
    @discardableResult
    public static func protect(storeURL: URL) -> [LocalFileProtection.Failure] {
        LocalFileProtection.applyBestEffort(to: family(of: storeURL))
    }

    /// Read back the attributes of the directory, store and present sidecars.
    public static func verify(
        storeURL: URL, failures: [LocalFileProtection.Failure] = []
    ) -> CacheStoreProtectionReport {
        let entries = family(of: storeURL)
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .map { CacheStoreProtectionReport.Entry(role: $0.role, attributes: LocalFileProtection.read(from: $0.url)) }
        return CacheStoreProtectionReport(entries: entries, failures: failures)
    }

    /// Read back the protection attributes for verification (used by the
    /// app-level boundary test on iOS; on macOS file protection reads as nil).
    public static func read(from url: URL) -> (backupExcluded: Bool?, fileProtection: String?) {
        let attributes = LocalFileProtection.read(from: url)
        return (attributes.backupExcluded, attributes.fileProtection)
    }
}
