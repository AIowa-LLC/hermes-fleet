import Foundation

/// Build 41 navigation + full-Kanban mission — mutation domain (FleetCore).
///
/// Wire contract verified against the stock Hermes kanban dashboard plugin
/// (`plugins/kanban/dashboard/plugin_api.py`, Sep 2026):
/// - `POST   /api/plugins/kanban/tasks`                    (CreateTaskBody)
/// - `PATCH  /api/plugins/kanban/tasks/{task_id}`           (UpdateTaskBody)
/// - `DELETE /api/plugins/kanban/tasks/{task_id}`
/// - `GET    /api/plugins/kanban/tasks/{task_id}`           (detail bundle)
/// - `POST   /api/plugins/kanban/tasks/{task_id}/comments`  (CommentBody)
/// - `POST   /api/plugins/kanban/links` / `DELETE /links`
/// - `POST   /api/plugins/kanban/tasks/bulk`                (BulkTaskBody)
/// - `POST   /api/plugins/kanban/tasks/{task_id}/reclaim`
/// - `POST   /api/plugins/kanban/tasks/{task_id}/specify`
/// - `POST   /api/plugins/kanban/tasks/{task_id}/decompose`
/// - `POST   /api/plugins/kanban/tasks/{task_id}/reassign`
/// - `GET    /api/plugins/kanban/assignees`
/// - `GET/PUT /api/plugins/kanban/orchestration`
/// - `POST   /api/plugins/kanban/dispatch?dry_run=&max=`
///
/// Status vocabulary (kanban_db.VALID_STATUSES): triage, todo, scheduled,
/// ready, running, blocked, review, done, archived. `running` can NOT be set
/// directly through PATCH (claim path only) — the UI offers it and surfaces
/// the server's refusal honestly.

// MARK: - Status vocabulary

/// The board's status vocabulary (server truth; unknown statuses bucket to
/// `todo` by the server, so this set is display-ordering only).
public enum KanbanStatus {
    public static let all: [String] = [
        "triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done",
    ]
    /// Statuses a human may request through PATCH (running is claim-path only;
    /// archived is a separate archive action).
    public static let settable: [String] = [
        "triage", "todo", "scheduled", "ready", "blocked", "review", "done",
    ]
    /// Legacy case-insensitive match for filter/UI input.
    public static func canonical(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        return all.first { $0 == lowered } ?? (lowered == "archived" ? "archived" : nil)
    }
}

// MARK: - Create draft

/// `POST /tasks` body (CreateTaskBody — field-for-field).
public struct KanbanTaskDraft: Sendable, Equatable {
    public var title: String
    public var body: String?
    public var assignee: String?
    public var tenant: String?
    public var priority: Int
    public var workspaceKind: String?
    public var workspacePath: String?
    public var parents: [String]
    public var triage: Bool
    public var maxRuntimeSeconds: Int?
    public var skills: [String]?
    public var goalMode: Bool
    public var goalMaxTurns: Int?
    public var modelOverride: String?
    public var providerOverride: String?
    public var reasoningEffort: String?
    public var projectId: String?

    public init(
        title: String,
        body: String? = nil,
        assignee: String? = nil,
        tenant: String? = nil,
        priority: Int = 0,
        workspaceKind: String? = nil,
        workspacePath: String? = nil,
        parents: [String] = [],
        triage: Bool = false,
        maxRuntimeSeconds: Int? = nil,
        skills: [String]? = nil,
        goalMode: Bool = false,
        goalMaxTurns: Int? = nil,
        modelOverride: String? = nil,
        providerOverride: String? = nil,
        reasoningEffort: String? = nil,
        projectId: String? = nil
    ) {
        self.title = title
        self.body = body
        self.assignee = assignee
        self.tenant = tenant
        self.priority = priority
        self.workspaceKind = workspaceKind
        self.workspacePath = workspacePath
        self.parents = parents
        self.triage = triage
        self.maxRuntimeSeconds = maxRuntimeSeconds
        self.skills = skills
        self.goalMode = goalMode
        self.goalMaxTurns = goalMaxTurns
        self.modelOverride = modelOverride
        self.providerOverride = providerOverride
        self.reasoningEffort = reasoningEffort
        self.projectId = projectId
    }
}

// MARK: - Patch

/// `PATCH /tasks/{id}` body. `nil` = "field not sent" (server semantics —
/// this is how partial edits stay partial). Empty-string assignee = unassign.
public struct KanbanTaskPatch: Sendable, Equatable {
    public var status: String?
    public var assignee: String?
    public var priority: Int?
    public var title: String?
    public var body: String?
    public var result: String?
    public var blockReason: String?
    public var summary: String?
    public var metadata: [String: String]?
    public var modelOverride: String?
    public var providerOverride: String?
    public var clearModelOverride: Bool
    public var reasoningEffort: String?
    public var clearReasoningEffort: Bool

    public init(
        status: String? = nil,
        assignee: String? = nil,
        priority: Int? = nil,
        title: String? = nil,
        body: String? = nil,
        result: String? = nil,
        blockReason: String? = nil,
        summary: String? = nil,
        metadata: [String: String]? = nil,
        modelOverride: String? = nil,
        providerOverride: String? = nil,
        clearModelOverride: Bool = false,
        reasoningEffort: String? = nil,
        clearReasoningEffort: Bool = false
    ) {
        self.status = status
        self.assignee = assignee
        self.priority = priority
        self.title = title
        self.body = body
        self.result = result
        self.blockReason = blockReason
        self.summary = summary
        self.metadata = metadata
        self.modelOverride = modelOverride
        self.providerOverride = providerOverride
        self.clearModelOverride = clearModelOverride
        self.reasoningEffort = reasoningEffort
        self.clearReasoningEffort = clearReasoningEffort
    }

    public var isEmpty: Bool {
        status == nil && assignee == nil && priority == nil && title == nil
            && body == nil && result == nil && blockReason == nil && summary == nil
            && metadata == nil && modelOverride == nil && providerOverride == nil
            && !clearModelOverride && reasoningEffort == nil && !clearReasoningEffort
    }
}

/// `POST /tasks/bulk` body — the shared patch plus bulk-only flags.
public struct KanbanBulkPatch: Sendable, Equatable {
    public var ids: [String]
    public var status: String?
    public var assignee: String?
    public var priority: Int?
    public var archive: Bool
    public var reclaimFirst: Bool

    public init(
        ids: [String],
        status: String? = nil,
        assignee: String? = nil,
        priority: Int? = nil,
        archive: Bool = false,
        reclaimFirst: Bool = false
    ) {
        self.ids = ids
        self.status = status
        self.assignee = assignee
        self.priority = priority
        self.archive = archive
        self.reclaimFirst = reclaimFirst
    }
}

/// One per-id outcome row from `POST /tasks/bulk` (`{id, ok, error?}`).
public struct KanbanBulkOutcome: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let ok: Bool
    public let error: String?
    public init(id: String, ok: Bool, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.error = error
    }
}

/// `POST /tasks` result: the created card plus the server's optional warning
/// banner (a `ready`+assigned create with no running dispatcher would sit
/// idle — the dashboard's own copy). `warning == nil` when the server sent
/// none; the card is always present on success.
public struct KanbanTaskCreation: Sendable, Equatable {
    public let card: KanbanCard
    public let warning: String?

    public init(card: KanbanCard, warning: String? = nil) {
        self.card = card
        self.warning = warning
    }
}

// MARK: - Detail bundle

    /// `GET /tasks/{id}` response: the full task plus comments, events, links,
    /// child results, and runs. Cards on `/board` carry truncated previews; this
    /// is the authoritative per-task read.
    public struct KanbanTaskDetail: Sendable, Equatable, Decodable {
        public let task: KanbanTaskRecord
        public let comments: [KanbanComment]
        public let events: [KanbanTaskEventRecord]
        public let links: KanbanTaskLinks
        public let childResults: [KanbanChildResult]
        public let runs: [KanbanRunRecord]

        public init(
            task: KanbanTaskRecord,
            comments: [KanbanComment] = [],
            events: [KanbanTaskEventRecord] = [],
            links: KanbanTaskLinks = KanbanTaskLinks(parents: [], children: []),
            childResults: [KanbanChildResult] = [],
            runs: [KanbanRunRecord] = []
        ) {
            self.task = task
            self.comments = comments
            self.events = events
            self.links = links
            self.childResults = childResults
            self.runs = runs
        }

        private enum CodingKeys: String, CodingKey {
            case task, comments, events, links, runs
            case childResults = "child_results"
        }

        /// Tolerant decode: `task` is required (the bundle's subject), every
        /// section reads as EMPTY when the server omits the key or sends
        /// `null` — matching the memberwise defaults. A missing section (a
        /// task with no runs, no child results, an older plugin build) must
        /// degrade to "no rows", never fail the whole detail read.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            task = try c.decode(KanbanTaskRecord.self, forKey: .task)
            comments = try c.decodeIfPresent([KanbanComment].self, forKey: .comments) ?? []
            events = try c.decodeIfPresent([KanbanTaskEventRecord].self, forKey: .events) ?? []
            links = try c.decodeIfPresent(KanbanTaskLinks.self, forKey: .links) ?? KanbanTaskLinks()
            childResults = try c.decodeIfPresent([KanbanChildResult].self, forKey: .childResults) ?? []
            runs = try c.decodeIfPresent([KanbanRunRecord].self, forKey: .runs) ?? []
        }
    }

/// The full task row (`asdict(kanban_db.Task)` + derived fields).
public struct KanbanTaskRecord: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let title: String?
    public let body: String?
    public let assignee: String?
    public let status: String?
    public let priority: Int?
    public let createdAt: Double?
    public let startedAt: Double?
    public let completedAt: Double?
    public let workspaceKind: String?
    public let workspacePath: String?
    public let tenant: String?
    public let branchName: String?
    public let projectId: String?
    public let result: String?
    public let skills: [String]?
    public let modelOverride: String?
    public let providerOverride: String?
    public let reasoningEffort: String?
    public let goalMode: Bool?
    public let goalMaxTurns: Int?
    public let maxRuntimeSeconds: Int?
    public let maxRetries: Int?
    public let consecutiveFailures: Int?
    public let lastFailureError: String?
    public let currentRunID: Int?
    public let blockKind: String?
    public let latestSummary: String?

    public init(
        id: String,
        title: String? = nil,
        body: String? = nil,
        assignee: String? = nil,
        status: String? = nil,
        priority: Int? = nil,
        createdAt: Double? = nil,
        startedAt: Double? = nil,
        completedAt: Double? = nil,
        workspaceKind: String? = nil,
        workspacePath: String? = nil,
        tenant: String? = nil,
        branchName: String? = nil,
        projectId: String? = nil,
        result: String? = nil,
        skills: [String]? = nil,
        modelOverride: String? = nil,
        providerOverride: String? = nil,
        reasoningEffort: String? = nil,
        goalMode: Bool? = nil,
        goalMaxTurns: Int? = nil,
        maxRuntimeSeconds: Int? = nil,
        maxRetries: Int? = nil,
        consecutiveFailures: Int? = nil,
        lastFailureError: String? = nil,
        currentRunID: Int? = nil,
        blockKind: String? = nil,
        latestSummary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.assignee = assignee
        self.status = status
        self.priority = priority
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.workspaceKind = workspaceKind
        self.workspacePath = workspacePath
        self.tenant = tenant
        self.branchName = branchName
        self.projectId = projectId
        self.result = result
        self.skills = skills
        self.modelOverride = modelOverride
        self.providerOverride = providerOverride
        self.reasoningEffort = reasoningEffort
        self.goalMode = goalMode
        self.goalMaxTurns = goalMaxTurns
        self.maxRuntimeSeconds = maxRuntimeSeconds
        self.maxRetries = maxRetries
        self.consecutiveFailures = consecutiveFailures
        self.lastFailureError = lastFailureError
        self.currentRunID = currentRunID
        self.blockKind = blockKind
        self.latestSummary = latestSummary
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, assignee, status, priority, skills, result
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case workspaceKind = "workspace_kind"
        case workspacePath = "workspace_path"
        case tenant
        case branchName = "branch_name"
        case projectId = "project_id"
        case modelOverride = "model_override"
        case providerOverride = "provider_override"
        case reasoningEffort = "reasoning_effort"
        case goalMode = "goal_mode"
        case goalMaxTurns = "goal_max_turns"
        case maxRuntimeSeconds = "max_runtime_seconds"
        case maxRetries = "max_retries"
        case consecutiveFailures = "consecutive_failures"
        case lastFailureError = "last_failure_error"
        case currentRunID = "current_run_id"
        case blockKind = "block_kind"
        case latestSummary = "latest_summary"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        assignee = try c.decodeIfPresent(String.self, forKey: .assignee)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt)
        startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(Double.self, forKey: .completedAt)
        workspaceKind = try c.decodeIfPresent(String.self, forKey: .workspaceKind)
        workspacePath = try c.decodeIfPresent(String.self, forKey: .workspacePath)
        tenant = try c.decodeIfPresent(String.self, forKey: .tenant)
        branchName = try c.decodeIfPresent(String.self, forKey: .branchName)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        result = try c.decodeIfPresent(String.self, forKey: .result)
        skills = try c.decodeIfPresent([String].self, forKey: .skills)
        modelOverride = try c.decodeIfPresent(String.self, forKey: .modelOverride)
        providerOverride = try c.decodeIfPresent(String.self, forKey: .providerOverride)
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
        goalMode = try c.decodeIfPresent(Bool.self, forKey: .goalMode)
        goalMaxTurns = try c.decodeIfPresent(Int.self, forKey: .goalMaxTurns)
        maxRuntimeSeconds = try c.decodeIfPresent(Int.self, forKey: .maxRuntimeSeconds)
        maxRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries)
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures)
        lastFailureError = try c.decodeIfPresent(String.self, forKey: .lastFailureError)
        currentRunID = try c.decodeIfPresent(Int.self, forKey: .currentRunID)
        blockKind = try c.decodeIfPresent(String.self, forKey: .blockKind)
        latestSummary = try c.decodeIfPresent(String.self, forKey: .latestSummary)
    }
}

/// One comment row.
public struct KanbanComment: Sendable, Equatable, Identifiable, Decodable {
    public let id: Int
    public let taskID: String
    public let author: String?
    public let body: String
    public let createdAt: Double?

    public init(id: Int, taskID: String, author: String?, body: String, createdAt: Double?) {
        self.id = id
        self.taskID = taskID
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, author, body
        case taskID = "task_id"
        case createdAt = "created_at"
    }
}

/// One `task_events` row (detail bundle form).
public struct KanbanTaskEventRecord: Sendable, Equatable, Identifiable, Decodable {
    public let id: Int
    public let taskID: String
    public let runID: Int?
    public let kind: String
    public let createdAt: Double?

    public init(id: Int, taskID: String, runID: Int?, kind: String, createdAt: Double?) {
        self.id = id
        self.taskID = taskID
        self.runID = runID
        self.kind = kind
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind
        case taskID = "task_id"
        case runID = "run_id"
        case createdAt = "created_at"
    }
}

/// Parent/child ids for a task (`links`).
public struct KanbanTaskLinks: Sendable, Equatable, Decodable {
    public let parents: [String]
    public let children: [String]

    public init(parents: [String] = [], children: [String] = []) {
        self.parents = parents
        self.children = children
    }
}

/// `child_results` row: one child's id/title/status/summary/result.
public struct KanbanChildResult: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let title: String?
    public let status: String?
    public let latestSummary: String?
    public let result: String?

    public init(id: String, title: String?, status: String?, latestSummary: String?, result: String?) {
        self.id = id
        self.title = title
        self.status = status
        self.latestSummary = latestSummary
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, status, result
        case latestSummary = "latest_summary"
    }
}

/// One `task_runs` row.
public struct KanbanRunRecord: Sendable, Equatable, Identifiable, Decodable {
    public let id: Int
    public let taskID: String
    public let profile: String?
    public let status: String?
    public let startedAt: Double?
    public let endedAt: Double?
    public let outcome: String?
    public let summary: String?
    public let error: String?
    public let workerPID: Int?

    private enum CodingKeys: String, CodingKey {
        case id, profile, status, startedAt = "started_at", endedAt = "ended_at",
              outcome, summary, error
        case taskID = "task_id"
        case workerPID = "worker_pid"
    }
}

// MARK: - Auxiliary outcomes (specify / decompose / reassign / reclaim)

/// `POST /tasks/{id}/specify` — non-OK is NOT an HTTP error; the UI renders
/// the reason inline.
public struct KanbanSpecifyOutcome: Sendable, Equatable, Decodable {
    public let ok: Bool
    public let taskID: String?
    public let reason: String?
    public let newTitle: String?

    public init(ok: Bool, taskID: String?, reason: String?, newTitle: String?) {
        self.ok = ok
        self.taskID = taskID
        self.reason = reason
        self.newTitle = newTitle
    }

    private enum CodingKeys: String, CodingKey {
        case ok, reason
        case taskID = "task_id"
        case newTitle = "new_title"
    }
}

/// `POST /tasks/{id}/decompose`.
public struct KanbanDecomposeOutcome: Sendable, Equatable, Decodable {
    public let ok: Bool
    public let taskID: String?
    public let reason: String?
    public let fanout: Bool
    public let childIDs: [String]
    public let newTitle: String?

    public init(ok: Bool, taskID: String?, reason: String?, fanout: Bool, childIDs: [String], newTitle: String?) {
        self.ok = ok
        self.taskID = taskID
        self.reason = reason
        self.fanout = fanout
        self.childIDs = childIDs
        self.newTitle = newTitle
    }

    private enum CodingKeys: String, CodingKey {
        case ok, reason, fanout
        case taskID = "task_id"
        case childIDs = "child_ids"
        case newTitle = "new_title"
    }

    /// Tolerant decode for the VALUE path: a non-OK outcome (`ok == false` +
    /// `reason`) is data the UI renders inline, not an error — an absent or
    /// `null` `fanout`/`child_ids` reads as false/[] so the reason reaches the
    /// caller instead of being re-thrown as `.malformedResponse`. `ok` stays
    /// required (it is the value/error discriminator).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        fanout = try c.decodeIfPresent(Bool.self, forKey: .fanout) ?? false
        childIDs = try c.decodeIfPresent([String].self, forKey: .childIDs) ?? []
        newTitle = try c.decodeIfPresent(String.self, forKey: .newTitle)
    }
}

// MARK: - Orchestration settings

/// `GET/PUT /orchestration` — config knobs plus resolved values.
public struct KanbanOrchestrationSettings: Sendable, Equatable, Decodable {
    public let orchestratorProfile: String?
    public let defaultAssignee: String?
    public let autoDecompose: Bool
    public let autoPromoteChildren: Bool
    public let resolvedOrchestratorProfile: String?
    public let resolvedDefaultAssignee: String?
    public let activeProfile: String?

    public init(
        orchestratorProfile: String?,
        defaultAssignee: String?,
        autoDecompose: Bool,
        autoPromoteChildren: Bool,
        resolvedOrchestratorProfile: String?,
        resolvedDefaultAssignee: String?,
        activeProfile: String?
    ) {
        self.orchestratorProfile = orchestratorProfile
        self.defaultAssignee = defaultAssignee
        self.autoDecompose = autoDecompose
        self.autoPromoteChildren = autoPromoteChildren
        self.resolvedOrchestratorProfile = resolvedOrchestratorProfile
        self.resolvedDefaultAssignee = resolvedDefaultAssignee
        self.activeProfile = activeProfile
    }

    private enum CodingKeys: String, CodingKey {
        case autoDecompose = "auto_decompose"
        case autoPromoteChildren = "auto_promote_children"
        case orchestratorProfile = "orchestrator_profile"
        case defaultAssignee = "default_assignee"
        case resolvedOrchestratorProfile = "resolved_orchestrator_profile"
        case resolvedDefaultAssignee = "resolved_default_assignee"
        case activeProfile = "active_profile"
    }
}

/// `PUT /orchestration` body — only explicitly-set fields are written.
public struct KanbanOrchestrationPatch: Sendable, Equatable {
    public var orchestratorProfile: String?
    public var defaultAssignee: String?
    public var autoDecompose: Bool?
    public var autoPromoteChildren: Bool?

    public init(
        orchestratorProfile: String? = nil,
        defaultAssignee: String? = nil,
        autoDecompose: Bool? = nil,
        autoPromoteChildren: Bool? = nil
    ) {
        self.orchestratorProfile = orchestratorProfile
        self.defaultAssignee = defaultAssignee
        self.autoDecompose = autoDecompose
        self.autoPromoteChildren = autoPromoteChildren
    }
}

// MARK: - Dispatch nudge

/// `POST /dispatch` — the dashboard's dispatch-now result (subset the UI
/// shows; unknown fields ignored).
public struct KanbanDispatchResult: Sendable, Equatable, Decodable {
    public let reclaimed: Int?
    public let promoted: Int?
    public let spawned: [Spawned]?
    public let skippedUnassigned: [String]?
    public let skippedPerProfileCapped: [Capped]?
    public let crashed: [String]?
    public let autoBlocked: [String]?
    public let timedOut: [String]?
    public let stale: [String]?
    public let rateLimited: [String]?
    public let skippedLocked: Bool?
    public let memoryPressure: String?

    public struct Spawned: Sendable, Equatable, Decodable {
        public let taskID: String
        public let assignee: String
        public let workspacePath: String

        public init(taskID: String, assignee: String, workspacePath: String) {
            self.taskID = taskID
            self.assignee = assignee
            self.workspacePath = workspacePath
        }
    }

    public struct Capped: Sendable, Equatable, Decodable {
        public let taskID: String
        public let assignee: String
        public let runningCount: Int

        public init(taskID: String, assignee: String, runningCount: Int) {
            self.taskID = taskID
            self.assignee = assignee
            self.runningCount = runningCount
        }
    }

    private enum CodingKeys: String, CodingKey {
        case reclaimed, promoted, crashed, stale
        case spawned
        case skippedUnassigned = "skipped_unassigned"
        case skippedPerProfileCapped = "skipped_per_profile_capped"
        case autoBlocked = "auto_blocked"
        case timedOut = "timed_out"
        case rateLimited = "rate_limited"
        case skippedLocked = "skipped_locked"
        case memoryPressure = "memory_pressure"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reclaimed = try c.decodeIfPresent(Int.self, forKey: .reclaimed)
        promoted = try c.decodeIfPresent(Int.self, forKey: .promoted)
        skippedUnassigned = try c.decodeIfPresent([String].self, forKey: .skippedUnassigned)
        crashed = try c.decodeIfPresent([String].self, forKey: .crashed)
        autoBlocked = try c.decodeIfPresent([String].self, forKey: .autoBlocked)
        timedOut = try c.decodeIfPresent([String].self, forKey: .timedOut)
        stale = try c.decodeIfPresent([String].self, forKey: .stale)
        rateLimited = try c.decodeIfPresent([String].self, forKey: .rateLimited)
        skippedLocked = try c.decodeIfPresent(Bool.self, forKey: .skippedLocked)
        memoryPressure = try c.decodeIfPresent(String.self, forKey: .memoryPressure)
        // Tuples arrive as JSON arrays; decode positionally, tolerating gaps.
        spawned = try Self.decodeTriples(c, forKey: .spawned)
        skippedPerProfileCapped = try Self.decodeCapped(c, forKey: .skippedPerProfileCapped)
    }

    public init(
        reclaimed: Int? = nil,
        promoted: Int? = nil,
        spawned: [Spawned]? = nil,
        skippedUnassigned: [String]? = nil,
        skippedPerProfileCapped: [Capped]? = nil,
        crashed: [String]? = nil,
        autoBlocked: [String]? = nil,
        timedOut: [String]? = nil,
        stale: [String]? = nil,
        rateLimited: [String]? = nil,
        skippedLocked: Bool? = nil,
        memoryPressure: String? = nil
    ) {
        self.reclaimed = reclaimed
        self.promoted = promoted
        self.spawned = spawned
        self.skippedUnassigned = skippedUnassigned
        self.skippedPerProfileCapped = skippedPerProfileCapped
        self.crashed = crashed
        self.autoBlocked = autoBlocked
        self.timedOut = timedOut
        self.stale = stale
        self.rateLimited = rateLimited
        self.skippedLocked = skippedLocked
        self.memoryPressure = memoryPressure
    }

    private static func decodeTriples(
        _ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> [Spawned]? {
        guard var rows = try c.decodeIfPresent([[String]].self, forKey: key) else { return nil }
        // Tolerate a missing third element (workspacePath) on older servers.
        func pad(_ row: [String]) -> [String] {
            row + Array(repeating: "", count: max(0, 3 - row.count))
        }
        rows = rows.map(pad)
        return rows.compactMap { row in
            guard row.count >= 2 else { return nil }
            return Spawned(taskID: row[0], assignee: row[1], workspacePath: row[2])
        }
    }

    private static func decodeCapped(
        _ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> [Capped]? {
        struct LaxRow: Decodable {
            let taskID: String
            let assignee: String
            let runningCount: Int
            init(from decoder: Decoder) throws {
                var u = try decoder.unkeyedContainer()
                taskID = try u.decode(String.self)
                assignee = try u.decode(String.self)
                runningCount = (try? u.decode(Int.self)) ?? 0
            }
        }
        return try c.decodeIfPresent([LaxRow].self, forKey: key)?
            .map { Capped(taskID: $0.taskID, assignee: $0.assignee, runningCount: $0.runningCount) }
    }
}

// MARK: - Mutation errors

/// Errors surfaced by board mutations. `rejected` carries the server's
/// user-facing detail (409/400 `detail` — e.g. the blocking parents for a
/// refused `ready` promotion) so the UI can render an actionable message.
public enum KanbanMutationError: Error, Sendable, Equatable, LocalizedError {
    case httpStatus(Int)
    case rejected(String)
    case malformedResponse(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "kanban: HTTP \(code)"
        case .rejected(let detail):
            return detail
        case .malformedResponse(let detail):
            return "kanban: malformed response (\(detail))"
        case .unsupported(let detail):
            return "kanban: \(detail)"
        }
    }
}

// MARK: - Operating seam

/// Build 41: a Kanban surface that can MUTATE the board, not just watch it.
///
/// Same pattern as `KanbanBoardWatching`: FleetUI depends only on this
/// FleetCore protocol; the concrete `KanbanEventStreamClient` (FleetNetworking)
/// implements it against the dashboard plugin REST surface. Watchers that do
/// NOT conform (e.g. an unconfigured gateway stub) fail closed — the board
/// renders its read-only/unavailable state and mutation controls are absent,
/// never silently dropped.
public protocol KanbanBoardOperating: KanbanBoardWatching {
    /// Fetch the board snapshot, optionally including the archived column.
    func snapshot(includeArchived: Bool) async throws -> KanbanBoardSnapshot
    /// `POST /tasks` — returns the created task (as a card).
    func createTask(_ draft: KanbanTaskDraft) async throws -> KanbanCard
    /// `POST /tasks` — the created card PLUS the server's optional warning
    /// banner. Default implementation delegates to `createTask` (a conformer
    /// with no warning channel reports `warning == nil`); the REST client
    /// overrides it to surface the wire `warning`.
    func createTaskWithWarning(_ draft: KanbanTaskDraft) async throws -> KanbanTaskCreation
    /// `PATCH /tasks/{id}` — returns the updated task.
    func updateTask(id: String, patch: KanbanTaskPatch) async throws -> KanbanCard
    /// `DELETE /tasks/{id}` — hard delete (destructive; UI confirms).
    func deleteTask(id: String) async throws
    /// `GET /tasks/{id}` — the full detail bundle.
    func fetchTaskDetail(id: String) async throws -> KanbanTaskDetail
    /// `POST /tasks/{id}/comments`.
    func addComment(taskID: String, body: String, author: String?) async throws
    /// `POST /links` — returns whether the link is dependency-gated.
    func linkTasks(parentID: String, childID: String) async throws -> Bool
    /// `DELETE /links?parent_id&child_id`.
    func unlinkTasks(parentID: String, childID: String) async throws
    /// `POST /tasks/bulk` — per-id outcomes (partials allowed).
    func bulkUpdate(_ patch: KanbanBulkPatch) async throws -> [KanbanBulkOutcome]
    /// `POST /tasks/{id}/reclaim`.
    func reclaimTask(id: String, reason: String?) async throws
    /// `POST /tasks/{id}/specify` (auxiliary LLM; non-OK is a value).
    func specifyTask(id: String, author: String?) async throws -> KanbanSpecifyOutcome
    /// `POST /tasks/{id}/decompose` (auxiliary LLM fan-out).
    func decomposeTask(id: String, author: String?) async throws -> KanbanDecomposeOutcome
    /// `POST /tasks/{id}/reassign`.
    func reassignTask(id: String, profile: String?, reclaimFirst: Bool, reason: String?) async throws
    /// `GET /assignees` — union of gateway profiles and board assignees.
    func fetchAssignees() async throws -> [String]
    /// `GET /orchestration`.
    func orchestrationSettings() async throws -> KanbanOrchestrationSettings
    /// `PUT /orchestration` — returns the resolved state.
    func updateOrchestrationSettings(_ patch: KanbanOrchestrationPatch) async throws -> KanbanOrchestrationSettings
    /// `POST /dispatch` — dispatcher nudge (don't wait out the tick).
    func dispatchNudge(dryRun: Bool, max: Int) async throws -> KanbanDispatchResult
}

public extension KanbanBoardOperating {
    /// Warning-less default: a conformer that only witnesses `createTask`
    /// (scripted doubles, older stubs) reports no server warning.
    func createTaskWithWarning(_ draft: KanbanTaskDraft) async throws -> KanbanTaskCreation {
        KanbanTaskCreation(card: try await createTask(draft))
    }
}
