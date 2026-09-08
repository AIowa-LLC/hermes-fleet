import Foundation
import SwiftData
import FleetCore

/// One persisted projects-tree snapshot (R10-T3 offline browse). One row
/// per gateway: the latest `projects.tree` payload, encoded as the same
/// `ProjectsTree` Codable the wire layer produces, so an offline reload
/// renders the exact tree the user last saw.
///
/// **Structural no-secret invariant:** like every cache model, there is
/// NO token, ticket, credential, password, or key field here. The
/// payload is project/repo/lane structure and session titles/previews —
/// non-secret metadata already on the gateway.
@Model
public final class ProjectsSnapshotRow {
    /// Owning gateway (canonical `GatewayID.rawValue`) — primary key.
    public var gatewayID: String
    /// nil marks legacy data with unknown profile ownership.
    public var profileSlug: String? = nil
    /// Wall-clock capture time (Unix seconds).
    public var capturedAt: Double
    /// Project count at capture.
    public var projectCount: Int
    /// JSON-encoded `ProjectsTree`.
    public var payload: Data

    public init(gatewayID: String, profileSlug: String? = nil, capturedAt: Double, projectCount: Int, payload: Data) {
        self.gatewayID = gatewayID
        self.profileSlug = profileSlug
        self.capturedAt = capturedAt
        self.projectCount = projectCount
        self.payload = payload
    }
}

// MARK: - FleetCore seam conformance (R10-T3)

extension SwiftDataCacheStore: ProjectsSnapshotStoring {
    public func save(_ tree: ProjectsTree, for gatewayID: GatewayID, profile: ProfileSlug?) async throws {
        try await saveProjectsSnapshot(tree, for: gatewayID, profile: profile)
    }

    public func load(for gatewayID: GatewayID, profile: ProfileSlug?) async throws -> (tree: ProjectsTree, capturedAt: Date)? {
        try await loadProjectsSnapshot(for: gatewayID, profile: profile)
    }
}

// MARK: - Snapshot store (R10-T3)

public extension SwiftDataCacheStore {

    /// Persist the latest tree for a gateway (replace semantics — one
    /// row per gateway; the `LearningGraphSnapshotRow` discipline).
    func saveProjectsSnapshot(_ tree: ProjectsTree, for gatewayID: GatewayID, profile: ProfileSlug? = nil) async throws {
        let ctx = ModelContext(container)
        let data = try JSONEncoder().encode(tree)
        let rows = try ctx.fetch(FetchDescriptor<ProjectsSnapshotRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue && row.profileSlug == profile?.rawValue {
            ctx.delete(row)
        }
        ctx.insert(ProjectsSnapshotRow(
            gatewayID: gatewayID.rawValue,
            profileSlug: profile?.rawValue,
            capturedAt: Date().timeIntervalSince1970,
            projectCount: tree.projects.count,
            payload: data))
        try ctx.save()
    }

    /// Latest snapshot for a gateway (nil when never captured). Decoding
    /// is fail-soft: an unparsable payload returns nil, never a crash —
    /// an offline browse falls back to the empty state.
    func loadProjectsSnapshot(for gatewayID: GatewayID, profile: ProfileSlug? = nil) async throws -> (tree: ProjectsTree, capturedAt: Date)? {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<ProjectsSnapshotRow>())
            .filter { $0.gatewayID == gatewayID.rawValue && $0.profileSlug == profile?.rawValue }
        guard let latest = rows.sorted(by: { $0.capturedAt > $1.capturedAt }).first,
              let tree = try? JSONDecoder().decode(ProjectsTree.self, from: latest.payload)
        else { return nil }
        return (tree, Date(timeIntervalSince1970: latest.capturedAt))
    }

    /// Remove the snapshot for a gateway (used when a gateway is removed).
    func deleteProjectsSnapshot(for gatewayID: GatewayID) async throws {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<ProjectsSnapshotRow>())
        for row in rows where row.gatewayID == gatewayID.rawValue {
            ctx.delete(row)
        }
        try ctx.save()
    }
}
