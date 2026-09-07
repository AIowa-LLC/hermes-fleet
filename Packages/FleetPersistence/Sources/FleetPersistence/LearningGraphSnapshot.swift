import Foundation
import SwiftData
import FleetCore

/// One persisted learning-graph snapshot (R9-T7 offline browse). One row per
/// gateway: the latest `learning.frames` payload, encoded as the same
/// `LearningGraph` Codable the wire layer produces, so an offline reload
/// renders the exact graph the user last saw.
///
/// **Structural no-secret invariant:** like every cache model, there is NO
/// token, ticket, credential, password, or key field here. The payload is
/// skill names/categories/dates and memory chunk text — profile learning
/// data, non-secret, already on the gateway.
@Model
public final class LearningGraphSnapshotRow {
    /// Owning gateway (canonical `GatewayID.rawValue`) — primary key.
    public var gatewayID: String
    /// Wall-clock capture time (Unix seconds).
    public var capturedAt: Double
    /// Server-reported node count at capture (`count`).
    public var totalCount: Int
    /// JSON-encoded `LearningGraph` (buckets + summary).
    public var payload: Data

    public init(gatewayID: String, capturedAt: Double, totalCount: Int, payload: Data) {
        self.gatewayID = gatewayID
        self.capturedAt = capturedAt
        self.totalCount = totalCount
        self.payload = payload
    }
}

// MARK: - FleetCore seam conformance (R9-T7)

extension SwiftDataCacheStore: LearningGraphSnapshotStoring {
    public func save(_ graph: LearningGraph, for gatewayID: GatewayID) async throws {
        try await saveLearningGraphSnapshot(graph, for: gatewayID)
    }

    public func load(for gatewayID: GatewayID) async throws -> (graph: LearningGraph, capturedAt: Date)? {
        try await loadLearningGraphSnapshot(for: gatewayID)
    }
}

// MARK: - Snapshot store (R9-T7)

public extension SwiftDataCacheStore {

    /// Persist the latest graph for a gateway (replace semantics — one row
    /// per gateway).
    func saveLearningGraphSnapshot(_ graph: LearningGraph, for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let data = try JSONEncoder().encode(graph)
        let rows = try ctx.fetch(FetchDescriptor<LearningGraphSnapshotRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        ctx.insert(LearningGraphSnapshotRow(
            gatewayID: gatewayID.rawValue,
            capturedAt: Date().timeIntervalSince1970,
            totalCount: graph.summary.totalCount,
            payload: data))
        try ctx.save()
    }

    /// Latest snapshot for a gateway (nil when never captured). Decoding is
    /// fail-soft: an unparsable payload returns nil, never a crash — an
    /// offline browse falls back to the empty state.
    func loadLearningGraphSnapshot(for gatewayID: GatewayID) async throws -> (graph: LearningGraph, capturedAt: Date)? {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<LearningGraphSnapshotRow>())
            .filter { $0.gatewayID == gatewayID.rawValue }
        guard let latest = rows.sorted(by: { $0.capturedAt > $1.capturedAt }).first,
              let graph = try? JSONDecoder().decode(LearningGraph.self, from: latest.payload)
        else { return nil }
        return (graph, Date(timeIntervalSince1970: latest.capturedAt))
    }

    /// Remove the snapshot for a gateway (used when a gateway is removed).
    func deleteLearningGraphSnapshot(for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<LearningGraphSnapshotRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        try ctx.save()
    }
}
