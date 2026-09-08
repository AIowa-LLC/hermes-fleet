import Foundation

/// R10-T3 — remote file browser domain models + seam: the gateway's
/// project → repo → lane structure with preview sessions, per-project
/// drill-in, and gateway-side path completion.
///
/// WIRE GROUND TRUTH (hermes-agent 0.21.0, installed source, verified
/// 2026-09-04):
/// - `projects.tree` (tui_gateway/methods_config.py:117-153): result
///   `{projects[], active_id, scoped_session_ids}`. Node shape from
///   project_tree.py `_project_node` (:540-571): `{id, label, path,
///   color, icon, isAuto, isNoProject, sessionCount, lastActive,
///   totalTokens, totalCostUsd, repos[], previewSessions[]}`. Repos
///   (`_build_repos` :373-421): `{id, label, path, sessionCount,
///   groups[]}` where groups are LANES `{id, label, path, isMain,
///   isKanban, sessions[]}` — sessions EMPTY on the overview
///   (hydrate=False drops rows only after lane sorting, :411-419).
/// - Session rows (server.py `_project_tree_row` :15827-15866): the
///   ~18-field sidebar projection — id, title, preview, started_at,
///   last_active, cwd, git_branch, message_count, input/output tokens,
///   actual/estimated cost, model, profile (stamped per-request by
///   `stamp_profile`, project_tree.py:66-77).
/// - `projects.project_sessions` (methods_config.py:157-191): params
///   `{project_id, profile?}`; 5063 when project_id missing (:163);
///   result `{project: <hydrated node | null>}` — hydrate=True so lanes
///   carry rows, preview_limit=0 so previewSessions is empty.
/// - `complete.path` (methods_complete.py:41-326): params
///   `{word, cwd?}`; result `{items: [{text, display, meta}]}` where
///   `text` already carries the `@file:` / `@folder:` prefix
///   (:294-302). Empty word → `{items: []}` fast path (:42-44).
/// - Empty profile DB → honest blank `{projects: [], active_id: null,
///   scoped_session_ids: []}` (methods_config.py:128-131); runtime
///   failure → 5061 (:151).

// MARK: - Session row (shared by previews and hydrated lanes)

/// A `previewSessions` / hydrated-lane session row
/// (`_project_tree_row`, server.py:15827-15866).
public struct ProjectSessionRow: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let preview: String
    public let startedAt: Double
    public let lastActive: Double
    public let endedAt: Double?
    public let cwd: String
    public let gitBranch: String
    public let messageCount: Int
    public let toolCallCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let actualCostUsd: Double?
    public let estimatedCostUsd: Double?
    public let model: String
    public let profile: String

    public init(
        id: String,
        title: String,
        preview: String,
        startedAt: Double,
        lastActive: Double,
        endedAt: Double?,
        cwd: String,
        gitBranch: String,
        messageCount: Int,
        toolCallCount: Int,
        inputTokens: Int,
        outputTokens: Int,
        actualCostUsd: Double?,
        estimatedCostUsd: Double?,
        model: String,
        profile: String
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.startedAt = startedAt
        self.lastActive = lastActive
        self.endedAt = endedAt
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.messageCount = messageCount
        self.toolCallCount = toolCallCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.actualCostUsd = actualCostUsd
        self.estimatedCostUsd = estimatedCostUsd
        self.model = model
        self.profile = profile
    }
}

// MARK: - Tree nodes

/// A lane (branch) inside a repo — `groups[]` rows
/// (project_tree.py:373-382). `sessions` is populated only on the
/// hydrated drill-in payload; the overview ships counts only.
public struct ProjectLaneNode: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let label: String
    public let path: String?
    public let isMain: Bool
    public let isKanban: Bool
    public let sessions: [ProjectSessionRow]

    public init(
        id: String, label: String, path: String?,
        isMain: Bool, isKanban: Bool, sessions: [ProjectSessionRow]
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.isMain = isMain
        self.isKanban = isKanban
        self.sessions = sessions
    }
}

/// A repo inside a project (project_tree.py:397-405).
public struct ProjectRepoNode: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let label: String
    public let path: String?
    public let sessionCount: Int
    public let groups: [ProjectLaneNode]

    public init(
        id: String, label: String, path: String?,
        sessionCount: Int, groups: [ProjectLaneNode]
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.sessionCount = sessionCount
        self.groups = groups
    }
}

/// One project node (`_project_node`, project_tree.py:540-571).
public struct ProjectNode: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let label: String
    public let path: String?
    public let color: String?
    public let isAuto: Bool
    public let isNoProject: Bool
    public let sessionCount: Int
    public let lastActive: Double
    public let totalTokens: Int
    public let totalCostUsd: Double
    public let repos: [ProjectRepoNode]
    public let previewSessions: [ProjectSessionRow]

    public init(
        id: String, label: String, path: String?, color: String?,
        isAuto: Bool, isNoProject: Bool, sessionCount: Int,
        lastActive: Double, totalTokens: Int, totalCostUsd: Double,
        repos: [ProjectRepoNode], previewSessions: [ProjectSessionRow]
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.color = color
        self.isAuto = isAuto
        self.isNoProject = isNoProject
        self.sessionCount = sessionCount
        self.lastActive = lastActive
        self.totalTokens = totalTokens
        self.totalCostUsd = totalCostUsd
        self.repos = repos
        self.previewSessions = previewSessions
    }
}

/// The `projects.tree` envelope (methods_config.py:141-149).
public struct ProjectsTree: Hashable, Codable, Sendable {
    public let projects: [ProjectNode]
    public let activeID: String?
    public let scopedSessionIDs: [String]

    public init(projects: [ProjectNode], activeID: String?, scopedSessionIDs: [String]) {
        self.projects = projects
        self.activeID = activeID
        self.scopedSessionIDs = scopedSessionIDs
    }

    /// R10-T3 round 2 — resolve a transcript `@file:` / `@folder:` ref to
    /// the project whose repository (or own path) contains it, so a
    /// tap-through can pre-highlight the containing project. Deepest
    /// (longest) repo-root prefix wins; the No Project tier is never a
    /// target; a repo-RELATIVE ref (no resolvable root) resolves nil —
    /// honest no-highlight beats a wrong highlight. Pure function over
    /// the wire payload (no gateway round trip).
    public func project(containingPath rawPath: String) -> ProjectNode? {
        Self.containingProject(in: projects, path: rawPath)
    }

    static func containingProject(in projects: [ProjectNode], path rawPath: String) -> ProjectNode? {
        guard let target = Self.normalizedSegments(rawPath), !target.isEmpty else { return nil }
        var best: (node: ProjectNode, depth: Int)?
        for project in projects where !project.isNoProject {
            var roots: [String] = project.repos.compactMap(\.path)
            if let projectPath = project.path { roots.append(projectPath) }
            for root in roots {
                guard let rootSegments = Self.normalizedSegments(root), !rootSegments.isEmpty,
                      target.count > rootSegments.count,
                      target.prefix(rootSegments.count) == rootSegments[...] else { continue }
                if best == nil || rootSegments.count > best!.depth {
                    best = (project, rootSegments.count)
                }
            }
        }
        return best?.node
    }

    /// Split a path into normalized (`.`, `..`, empty segments resolved)
    /// components. Absolute and relative paths both normalize; nil never
    /// returned — an empty result means "no usable segments".
    static func normalizedSegments(_ path: String) -> [String]? {
        var out: [String] = []
        for segment in path.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..":
                if out.isEmpty { return nil } // escapes the root: unresolvable
                out.removeLast()
            default: out.append(String(segment))
            }
        }
        return out
    }
}

/// One `complete.path` completion item (methods_complete.py:303-309).
/// `text` already carries the `@file:` / `@folder:` prefix.
public struct PathCompletionItem: Hashable, Codable, Sendable {
    public let text: String
    public let display: String
    public let meta: String

    public init(text: String, display: String, meta: String) {
        self.text = text
        self.display = display
        self.meta = meta
    }
}

// MARK: - Errors

/// Errors surfaced by the projects browser. Non-secret (spec §29).
public enum GatewayProjectsError: Error, Sendable, Equatable, LocalizedError {
    /// The response body was not the expected shape.
    case malformedResponse(String)
    /// `projects.project_sessions` without a project_id (server 5063,
    /// methods_config.py:163-165 — mirrored client-side so an empty id
    /// fails before the round trip).
    case projectRequired(String)
    /// A transport/RPC failure (classified detail, non-secret).
    case rpcFailed(String)

    public var errorDescription: String? {
        switch self {
        case .malformedResponse(let detail):
            return "malformed gateway response (\(detail))"
        case .projectRequired(let detail):
            return detail
        case .rpcFailed(let detail):
            return detail
        }
    }
}

// MARK: - Seam

/// R10-T3 seam: the projects/file-tree surface over a gateway's
/// transport. Lives in FleetCore so FleetUI never imports
/// FleetNetworking (M0 guard); the concrete `GatewayProjectsClient` is
/// injected at the composition root.
public protocol GatewayProjectsProviding: Sendable {
    /// `projects.tree {profile?}` — the authoritative project overview
    /// (counts + preview sessions; lanes carry no rows).
    func projectTree(profile: String?) async throws -> ProjectsTree

    /// `projects.project_sessions {project_id, profile?}` — fully
    /// hydrated lanes for one project. Nil result = unknown project /
    /// empty profile DB (honest empty, not an error).
    func projectSessions(projectID: String, profile: String?) async throws -> ProjectNode?

    /// `complete.path {word, cwd?}` — gateway-side path completion.
    /// Items' `text` already carries the `@file:` prefix.
    func completePath(word: String, cwd: String?) async throws -> [PathCompletionItem]
}

/// Persistence seam for the offline snapshot (R10-T3): the VM depends
/// on this protocol; the composition root adapts FleetPersistence's
/// `SwiftDataCacheStore` (which conforms in an extension).
public protocol ProjectsSnapshotStoring: Sendable {
    func save(_ tree: ProjectsTree, for gatewayID: GatewayID, profile: ProfileSlug?) async throws
    func load(for gatewayID: GatewayID, profile: ProfileSlug?) async throws -> (tree: ProjectsTree, capturedAt: Date)?
}

public extension ProjectsSnapshotStoring {
    /// Legacy snapshots have unknown profile ownership and are never reused
    /// by a profile-qualified load. Kept only for existing unscoped callers.
    func save(_ tree: ProjectsTree, for gatewayID: GatewayID) async throws {
        try await save(tree, for: gatewayID, profile: nil)
    }
    func load(for gatewayID: GatewayID) async throws -> (tree: ProjectsTree, capturedAt: Date)? {
        try await load(for: gatewayID, profile: nil)
    }
}

/// Fail-closed default for gateways without the projects surface (no
/// endpoint configured): every call throws instead of silently
/// pretending the gateway answered (the `UnsupportedGatewayLearning`
/// discipline).
public struct UnsupportedGatewayProjects: GatewayProjectsProviding {
    public init() {}

    public func projectTree(profile: String?) async throws -> ProjectsTree {
        throw GatewayProjectsError.rpcFailed("gateway not configured")
    }

    public func projectSessions(projectID: String, profile: String?) async throws -> ProjectNode? {
        throw GatewayProjectsError.rpcFailed("gateway not configured")
    }

    public func completePath(word: String, cwd: String?) async throws -> [PathCompletionItem] {
        throw GatewayProjectsError.rpcFailed("gateway not configured")
    }
}
