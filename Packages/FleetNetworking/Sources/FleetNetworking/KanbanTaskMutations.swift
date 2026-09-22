import Foundation
import os
import FleetCore

/// Build 41 — REST mutations on the kanban dashboard plugin surface,
/// implemented by the existing `KanbanEventStreamClient` actor.
///
/// Wire contract (verified against `plugins/kanban/dashboard/plugin_api.py`):
/// every call targets `…/api/plugins/kanban/...` with `?board=<pinned slug>`
/// when a board is pinned, authenticates via the same HTTP credential seam
/// as the snapshot fetch (session-token header or login cookie), and maps
/// 4xx `detail` payloads to `KanbanMutationError.rejected` (user-facing)
/// rather than raw status codes.
extension KanbanEventStreamClient: KanbanBoardOperating {

    // MARK: - Shared request plumbing

    /// Type-erasing box so one helper can take any request body.
    private struct AnyEncodable: Encodable {
        let encodeFunc: (Encoder) throws -> Void
        init(_ wrapped: some Encodable) {
            encodeFunc = { try wrapped.encode(to: $0) }
        }
        func encode(to encoder: Encoder) throws {
            try encodeFunc(encoder)
        }
    }

    /// One authenticated plugin request: build → credential → send →
    /// status-map. Returns the raw body bytes.
    private func pluginRequest(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil
    ) async throws -> Data {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/api/plugins/kanban\(path)"
        var allQuery = query
        if let pinnedBoard, !pinnedBoard.isEmpty {
            allQuery.append(URLQueryItem(name: "board", value: pinnedBoard))
        }
        if !allQuery.isEmpty { components?.queryItems = allQuery }
        guard let url = components?.url else {
            throw KanbanMutationError.malformedResponse("bad URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        AuthREST.bounded(&request)
        try await applyHTTPCredential(to: &request)

        let (data, response) = try await urlSession.data(for: request)
        guard data.count <= AuthREST.maxResponseBytes else {
            throw KanbanMutationError.malformedResponse("response too large")
        }
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                // 400/409 `detail` is user-facing server copy — surface it.
                if let detail = Self.errorDetail(from: data) {
                    throw KanbanMutationError.rejected(detail)
                }
                Self.mutationLog.error("kanban \(path, privacy: .public): HTTP \(http.statusCode, privacy: .public)")
                throw KanbanMutationError.httpStatus(http.statusCode)
            }
        }
        return data
    }

    /// Extract FastAPI `{"detail": "..."}` from an error body (non-secret).
    static func errorDetail(from data: Data) -> String? {
        struct DetailEnvelope: Decodable { let detail: String }
        guard !data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(DetailEnvelope.self, from: data))?.detail
    }

    // MARK: - Snapshot (archived visibility)

    public func snapshot(includeArchived: Bool) async throws -> KanbanBoardSnapshot {
        // The pinned `board` query rides EVERY plugin request from
        // `pluginRequest` (single owner for the parameter); appending it here
        // as well duplicated it on the wire (`board=X&…&board=X`).
        var query: [URLQueryItem] = []
        if includeArchived {
            query.append(URLQueryItem(name: "include_archived", value: "true"))
        }
        let data = try await pluginRequest(path: "/board", method: "GET", query: query)
        let envelope: BoardEnvelope
        do {
            envelope = try JSONDecoder().decode(BoardEnvelope.self, from: data)
        } catch {
            throw KanbanMutationError.malformedResponse("board decode failed")
        }
        var cardsByColumn: [String: [KanbanCard]] = [:]
        for column in envelope.columns {
            cardsByColumn[column.name] = column.tasks.map { task in
                KanbanCard(
                    id: task.id,
                    title: task.title ?? task.id,
                    status: task.status ?? column.name,
                    assignee: task.assignee,
                    priority: task.priority,
                    createdAt: task.created_at,
                    latestSummary: task.latest_summary)
            }
        }
        let snapshot = KanbanBoardSnapshot(
            columns: envelope.columns.map(\.name),
            cardsByColumn: cardsByColumn,
            latestEventID: Int(envelope.latest_event_id),
            now: envelope.now)
        if snapshot.latestEventID > lastCursor {
            lastCursor = snapshot.latestEventID
        }
        return snapshot
    }

    // MARK: - Task CRUD

    public func createTask(_ draft: KanbanTaskDraft) async throws -> KanbanCard {
        try await createTaskWithWarning(draft).card
    }

    /// Same `POST /tasks`, keeping the server's optional `warning` (the
    /// dashboard's dispatcher-presence banner for a `ready`+assigned create
    /// that would otherwise sit idle).
    public func createTaskWithWarning(_ draft: KanbanTaskDraft) async throws -> KanbanTaskCreation {
        let data = try await pluginRequest(
            path: "/tasks", method: "POST", body: CreateTaskBody(draft))
        let envelope = try Self.decodeTaskEnvelope(data)
        guard let card = envelope.card else {
            throw KanbanMutationError.malformedResponse("created task decode failed")
        }
        return KanbanTaskCreation(card: card, warning: envelope.warning)
    }

    public func updateTask(id: String, patch: KanbanTaskPatch) async throws -> KanbanCard {
        let data = try await pluginRequest(
            path: "/tasks/\(id)", method: "PATCH", body: UpdateTaskBody(patch))
        return try Self.decodeCardResponse(data, context: "updated task")
    }

    public func deleteTask(id: String) async throws {
        _ = try await pluginRequest(path: "/tasks/\(id)", method: "DELETE")
    }

    public func fetchTaskDetail(id: String) async throws -> KanbanTaskDetail {
        let data = try await pluginRequest(path: "/tasks/\(id)", method: "GET")
        do {
            return try JSONDecoder().decode(KanbanTaskDetail.self, from: data)
        } catch {
            throw KanbanMutationError.malformedResponse("task detail decode failed")
        }
    }

    // MARK: - Comments / links

    public func addComment(taskID: String, body: String, author: String?) async throws {
        struct CommentBody: Encodable {
            let body: String
            let author: String?
        }
        _ = try await pluginRequest(
            path: "/tasks/\(taskID)/comments", method: "POST",
            body: CommentBody(body: body, author: author ?? "dashboard"))
    }

    public func linkTasks(parentID: String, childID: String) async throws -> Bool {
        struct LinkBody: Encodable { let parent_id: String; let child_id: String }
        struct GateEnvelope: Decodable { let gated: Bool? }
        let data = try await pluginRequest(
            path: "/links", method: "POST",
            body: LinkBody(parent_id: parentID, child_id: childID))
        return (try? JSONDecoder().decode(GateEnvelope.self, from: data))?.gated ?? false
    }

    public func unlinkTasks(parentID: String, childID: String) async throws {
        _ = try await pluginRequest(
            path: "/links", method: "DELETE",
            query: [
                URLQueryItem(name: "parent_id", value: parentID),
                URLQueryItem(name: "child_id", value: childID),
            ])
    }

    // MARK: - Bulk

    public func bulkUpdate(_ patch: KanbanBulkPatch) async throws -> [KanbanBulkOutcome] {
        struct ResultsEnvelope: Decodable { let results: [KanbanBulkOutcome] }
        let data = try await pluginRequest(
            path: "/tasks/bulk", method: "POST", body: BulkTaskBody(patch))
        guard let envelope = try? JSONDecoder().decode(ResultsEnvelope.self, from: data) else {
            throw KanbanMutationError.malformedResponse("bulk decode failed")
        }
        return envelope.results
    }

    // MARK: - Recovery / auxiliary actions

    public func reclaimTask(id: String, reason: String?) async throws {
        struct ReclaimBody: Encodable { let reason: String? }
        _ = try await pluginRequest(
            path: "/tasks/\(id)/reclaim", method: "POST",
            body: ReclaimBody(reason: reason))
    }

    public func specifyTask(id: String, author: String?) async throws -> KanbanSpecifyOutcome {
        struct SpecifyBody: Encodable { let author: String? }
        let data = try await pluginRequest(
            path: "/tasks/\(id)/specify", method: "POST",
            body: SpecifyBody(author: author))
        do {
            return try JSONDecoder().decode(KanbanSpecifyOutcome.self, from: data)
        } catch {
            throw KanbanMutationError.malformedResponse("specify decode failed")
        }
    }

    public func decomposeTask(id: String, author: String?) async throws -> KanbanDecomposeOutcome {
        struct DecomposeBody: Encodable { let author: String? }
        let data = try await pluginRequest(
            path: "/tasks/\(id)/decompose", method: "POST",
            body: DecomposeBody(author: author))
        do {
            return try JSONDecoder().decode(KanbanDecomposeOutcome.self, from: data)
        } catch {
            throw KanbanMutationError.malformedResponse("decompose decode failed")
        }
    }

    public func reassignTask(id: String, profile: String?, reclaimFirst: Bool, reason: String?) async throws {
        struct ReassignBody: Encodable {
            let profile: String?
            let reclaim_first: Bool
            let reason: String?
        }
        _ = try await pluginRequest(
            path: "/tasks/\(id)/reassign", method: "POST",
            body: ReassignBody(profile: profile, reclaim_first: reclaimFirst, reason: reason))
    }

    // MARK: - Assignees / orchestration / dispatch

    public func fetchAssignees() async throws -> [String] {
        struct AssigneesEnvelope: Decodable { let assignees: [String] }
        let data = try await pluginRequest(path: "/assignees", method: "GET")
        guard let envelope = try? JSONDecoder().decode(AssigneesEnvelope.self, from: data) else {
            throw KanbanMutationError.malformedResponse("assignees decode failed")
        }
        return envelope.assignees
    }

    public func orchestrationSettings() async throws -> KanbanOrchestrationSettings {
        let data = try await pluginRequest(path: "/orchestration", method: "GET")
        do {
            return try JSONDecoder().decode(KanbanOrchestrationSettings.self, from: data)
        } catch {
            throw KanbanMutationError.malformedResponse("orchestration decode failed")
        }
    }

    public func updateOrchestrationSettings(_ patch: KanbanOrchestrationPatch) async throws -> KanbanOrchestrationSettings {
        struct SettingsBody: Encodable {
            let orchestrator_profile: String?
            let default_assignee: String?
            let auto_decompose: Bool?
            let auto_promote_children: Bool?
        }
        let data = try await pluginRequest(
            path: "/orchestration", method: "PUT",
            body: SettingsBody(
                orchestrator_profile: patch.orchestratorProfile,
                default_assignee: patch.defaultAssignee,
                auto_decompose: patch.autoDecompose,
                auto_promote_children: patch.autoPromoteChildren))
        do {
            return try JSONDecoder().decode(KanbanOrchestrationSettings.self, from: data)
        } catch {
            throw KanbanMutationError.malformedResponse("orchestration decode failed")
        }
    }

    public func dispatchNudge(dryRun: Bool, max: Int) async throws -> KanbanDispatchResult {
        let data = try await pluginRequest(
            path: "/dispatch", method: "POST",
            query: [
                URLQueryItem(name: "dry_run", value: dryRun ? "true" : "false"),
                URLQueryItem(name: "max", value: String(max)),
            ])
        do {
            return try JSONDecoder().decode(KanbanDispatchResult.self, from: data)
        } catch {
            throw KanbanMutationError.malformedResponse("dispatch decode failed")
        }
    }

    // MARK: - Response decoding helpers

    /// `{"task": {...}, "warning": "..."}` — the create/PATCH response
    /// envelope. Returns `(nil, nil)` when the body is not that shape; the
    /// caller decides the failure copy.
    static func decodeTaskEnvelope(_ data: Data) throws -> (card: KanbanCard?, warning: String?) {
        struct TaskResponse: Decodable {
            let task: BoardEnvelope.TaskEnvelope?
            let warning: String?
        }
        guard let response = try? JSONDecoder().decode(TaskResponse.self, from: data) else {
            return (nil, nil)
        }
        let card = response.task.map { task in
            KanbanCard(
                id: task.id,
                title: task.title ?? task.id,
                status: task.status ?? "todo",
                assignee: task.assignee,
                priority: task.priority,
                createdAt: task.created_at,
                latestSummary: task.latest_summary)
        }
        return (card, response.warning)
    }

    /// `{"task": {...}}` → card (create/PATCH responses).
    static func decodeCardResponse(_ data: Data, context: String) throws -> KanbanCard {
        guard let card = try decodeTaskEnvelope(data).card else {
            throw KanbanMutationError.malformedResponse("\(context) decode failed")
        }
        return card
    }
}

// MARK: - Wire bodies (private, field-for-field vs plugin_api.py)

private struct CreateTaskBody: Encodable {
    let title: String
    let body: String?
    let assignee: String?
    let tenant: String?
    let priority: Int
    let workspace_kind: String?
    let workspace_path: String?
    let parents: [String]
    let triage: Bool
    let idempotency_key: String?
    let max_runtime_seconds: Int?
    let skills: [String]?
    let goal_mode: Bool
    let goal_max_turns: Int?
    let model_override: String?
    let provider_override: String?
    let reasoning_effort: String?
    let project_id: String?

    init(_ draft: KanbanTaskDraft) {
        title = draft.title
        body = draft.body
        assignee = draft.assignee
        tenant = draft.tenant
        priority = draft.priority
        workspace_kind = draft.workspaceKind
        workspace_path = draft.workspacePath
        parents = draft.parents
        triage = draft.triage
        idempotency_key = nil
        max_runtime_seconds = draft.maxRuntimeSeconds
        skills = draft.skills
        goal_mode = draft.goalMode
        goal_max_turns = draft.goalMaxTurns
        model_override = draft.modelOverride
        provider_override = draft.providerOverride
        reasoning_effort = draft.reasoningEffort
        project_id = draft.projectId
    }
}

private struct UpdateTaskBody: Encodable {
    let status: String?
    let assignee: String?
    let priority: Int?
    let title: String?
    let body: String?
    let result: String?
    let block_reason: String?
    let summary: String?
    let metadata: [String: String]?
    let model_override: String?
    let provider_override: String?
    let clear_model_override: Bool?
    let reasoning_effort: String?
    let clear_reasoning_effort: Bool?

    init(_ patch: KanbanTaskPatch) {
        status = patch.status
        assignee = patch.assignee
        priority = patch.priority
        title = patch.title
        body = patch.body
        result = patch.result
        block_reason = patch.blockReason
        summary = patch.summary
        metadata = patch.metadata
        model_override = patch.modelOverride
        provider_override = patch.providerOverride
        clear_model_override = patch.clearModelOverride ? true : nil
        reasoning_effort = patch.reasoningEffort
        clear_reasoning_effort = patch.clearReasoningEffort ? true : nil
    }
}

private struct BulkTaskBody: Encodable {
    let ids: [String]
    let status: String?
    let assignee: String?
    let priority: Int?
    let archive: Bool?
    let reclaim_first: Bool?

    init(_ patch: KanbanBulkPatch) {
        ids = patch.ids
        status = patch.status
        assignee = patch.assignee
        priority = patch.priority
        archive = patch.archive ? true : nil
        reclaim_first = patch.reclaimFirst ? true : nil
    }
}
