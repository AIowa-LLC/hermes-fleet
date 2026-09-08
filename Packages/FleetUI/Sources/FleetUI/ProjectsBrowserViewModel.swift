import Foundation
import Observation
import FleetCore

/// R10-T3 — observable state for the Projects browser pane
/// (the R9 memory-graph UX pattern: offline snapshot prefill → live
/// refresh → honest empty state; drill-in via
/// `projects.project_sessions`).
@MainActor
@Observable
public final class ProjectsBrowserViewModel {
    public enum Source: Equatable, Sendable {
        case live
        case offlineSnapshot
    }

    /// Drill-in state for the entered project.
    public struct ProjectDetailState: Sendable {
        public let project: ProjectNode?
        public let error: String?
    }

    // MARK: Observable state

    public private(set) var tree: ProjectsTree?
    public private(set) var source: Source = .live
    /// When the offline snapshot was captured (nil on live loads).
    public private(set) var offlineCapturedAt: Date?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// Drill-in (projects.project_sessions); nil when no project open.
    public private(set) var projectDetail: ProjectDetailState?
    public private(set) var isLoadingDetail = false

    // MARK: Dependencies

    public let gatewayID: GatewayID
    private let projects: any GatewayProjectsProviding
    private let snapshotStore: (any ProjectsSnapshotStoring)?

    public init(
        gatewayID: GatewayID,
        projects: any GatewayProjectsProviding,
        snapshotStore: (any ProjectsSnapshotStoring)? = nil
    ) {
        self.gatewayID = gatewayID
        self.projects = projects
        self.snapshotStore = snapshotStore
    }

    // MARK: Lifecycle

    /// Offline prefill first (instant browse), then the live fetch.
    public func start(profile: String?) async {
        if tree == nil, let store = snapshotStore,
           let cached = try? await store.load(for: gatewayID, profile: profile.map(ProfileSlug.init(rawValue:))),
           let cachedTree = cached.tree.projects.isEmpty ? nil : cached.tree {
            tree = cachedTree
            offlineCapturedAt = cached.capturedAt
            source = .offlineSnapshot
        }
        await reload(profile: profile)
    }

    public func reload(profile: String?) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await projects.projectTree(profile: profile)
            tree = fresh
            source = .live
            offlineCapturedAt = nil
            errorMessage = nil
            if let store = snapshotStore {
                // Save-on-success; a persistence failure must not fail
                // the pane (offline browse is best-effort).
                try? await store.save(fresh, for: gatewayID, profile: profile.map(ProfileSlug.init(rawValue:)))
            }
        } catch {
            // Keep the snapshot prefill (if any) for offline browse;
            // surface the failure honestly.
            errorMessage = Self.describe(error)
        }
    }

    // MARK: Drill-in

    /// Enter a project: fully hydrated lanes
    /// (`projects.project_sessions`). Failures keep the pane open with
    /// an honest error; the overview is untouched.
    public func openProject(id: String, profile: String? = nil) async {
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            let hydrated = try await projects.projectSessions(projectID: id, profile: profile)
            projectDetail = ProjectDetailState(project: hydrated, error: nil)
        } catch {
            projectDetail = ProjectDetailState(project: nil, error: Self.describe(error))
        }
    }

    public func closeProject() {
        projectDetail = nil
    }

    static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
    }
}
