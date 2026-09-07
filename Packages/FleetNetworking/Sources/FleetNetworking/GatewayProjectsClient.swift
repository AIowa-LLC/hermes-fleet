import Foundation
import os
import FleetCore

/// R10-T3 — concrete `GatewayProjectsProviding` over the conversation
/// transport: the remote file browser surface (`projects.tree`,
/// `projects.project_sessions`, `complete.path`).
///
/// Wire ground truth (hermes-agent 0.21.0, verified 2026-09-04):
/// - `projects.tree` (tui_gateway/methods_config.py:117-153): params
///   `{profile?}` (preview_limit/session_limit stay server-default —
///   3 previews / 2000 sessions are the 0.21 overview defaults,
///   :136-139). Result `{projects[], active_id, scoped_session_ids}`.
///   Empty profile DB is an honest blank (`:128-131`); runtime
///   failure is 5061 (`:151`).
/// - `projects.project_sessions` (methods_config.py:157-191): params
///   `{project_id, profile?}`; 5063 when project_id missing
///   (`:163-165`); result `{project: <hydrated node|null>}`.
/// - `complete.path` (methods_complete.py:41-326): params
///   `{word, cwd?}`; result `{items: [{text, display, meta}]}` with
///   `text` pre-composed with the `@file:`/`@folder:` prefix
///   (`:294-302`); empty word is the server's own `{items: []}` fast
///   path (`:42-44`) — mirrored client-side, no round trip.
public struct GatewayProjectsClient: GatewayProjectsProviding {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    private static let log = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "gateway-projects")

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: - GatewayProjectsProviding

    public func projectTree(profile: String?) async throws -> ProjectsTree {
        var params: [String: JSONValue] = [:]
        if let profile { params["profile"] = .string(profile) }
        let result = try await request(method: "projects.tree", params: .object(params))
        return try Self.decodeTree(result)
    }

    public func projectSessions(projectID: String, profile: String?) async throws -> ProjectNode? {
        // Client-side mirror of the server's fail-closed check
        // (methods_config.py:163-165) — an empty id fails BEFORE the
        // round trip instead of learning 5063.
        guard !projectID.isEmpty else {
            throw GatewayProjectsError.projectRequired("project_id required")
        }
        var params: [String: JSONValue] = ["project_id": .string(projectID)]
        if let profile { params["profile"] = .string(profile) }
        let result = try await request(
            method: "projects.project_sessions", params: .object(params))
        guard let object = result.objectValue else {
            throw GatewayProjectsError.malformedResponse(
                "projects.project_sessions result was not an object")
        }
        guard let projectValue = object["project"] else {
            throw GatewayProjectsError.malformedResponse(
                "projects.project_sessions result missing 'project'")
        }
        return Self.decodeProject(projectValue)
    }

    public func completePath(word: String, cwd: String?) async throws -> [PathCompletionItem] {
        // Empty word is the server's own no-op fast path
        // (methods_complete.py:42-44) — skip the round trip.
        guard !word.isEmpty else { return [] }
        var params: [String: JSONValue] = ["word": .string(word)]
        if let cwd { params["cwd"] = .string(cwd) }
        let result = try await request(method: "complete.path", params: .object(params))
        guard let object = result.objectValue else {
            throw GatewayProjectsError.malformedResponse(
                "complete.path result was not an object")
        }
        return (object["items"]?.arrayValue ?? []).compactMap { item in
            guard let o = item.objectValue,
                  let text = o["text"]?.stringValue else { return nil }
            return PathCompletionItem(
                text: text,
                display: o["display"]?.stringValue ?? text,
                meta: o["meta"]?.stringValue ?? "")
        }
    }

    // MARK: decoding (wire → domain)

    /// `{projects[], active_id, scoped_session_ids}` → domain
    /// (methods_config.py:141-149).
    static func decodeTree(_ result: JSONValue) throws -> ProjectsTree {
        guard let object = result.objectValue else {
            throw GatewayProjectsError.malformedResponse("projects.tree result was not an object")
        }
        guard let projectRows = object["projects"]?.arrayValue else {
            throw GatewayProjectsError.malformedResponse("projects.tree result missing 'projects'")
        }
        let projects = projectRows.compactMap { Self.decodeProject($0) }
        return ProjectsTree(
            projects: projects,
            activeID: object["active_id"]?.stringValue,
            scopedSessionIDs: object["scoped_session_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    /// `_project_node` (project_tree.py:540-571) → domain.
    static func decodeProject(_ value: JSONValue) -> ProjectNode? {
        guard let o = value.objectValue,
              let id = o["id"]?.stringValue, !id.isEmpty else { return nil }
        let repos = (o["repos"]?.arrayValue ?? []).compactMap(Self.decodeRepo)
        let previews = (o["previewSessions"]?.arrayValue ?? []).compactMap(Self.decodeSession)
        return ProjectNode(
            id: id,
            label: o["label"]?.stringValue ?? id,
            path: o["path"]?.stringValue,
            color: o["color"]?.stringValue,
            isAuto: o["isAuto"]?.boolValue ?? false,
            isNoProject: o["isNoProject"]?.boolValue ?? false,
            sessionCount: o["sessionCount"]?.numberValue.map(Int.init) ?? repos.reduce(0) { $0 + $1.sessionCount },
            lastActive: o["lastActive"]?.numberValue ?? 0,
            totalTokens: o["totalTokens"]?.numberValue.map(Int.init) ?? 0,
            totalCostUsd: o["totalCostUsd"]?.numberValue ?? 0,
            repos: repos,
            previewSessions: previews)
    }

    /// `_build_repos` repo rows (project_tree.py:397-405).
    static func decodeRepo(_ value: JSONValue) -> ProjectRepoNode? {
        guard let o = value.objectValue,
              let id = o["id"]?.stringValue, !id.isEmpty else { return nil }
        let groups = (o["groups"]?.arrayValue ?? []).compactMap(Self.decodeLane)
        return ProjectRepoNode(
            id: id,
            label: o["label"]?.stringValue ?? id,
            path: o["path"]?.stringValue,
            sessionCount: o["sessionCount"]?.numberValue.map(Int.init) ?? groups.reduce(0) { $0 + $1.sessions.count },
            groups: groups)
    }

    /// Lane rows (project_tree.py:373-382) — `sessions` populated only
    /// on the hydrated drill-in payload.
    static func decodeLane(_ value: JSONValue) -> ProjectLaneNode? {
        guard let o = value.objectValue,
              let id = o["id"]?.stringValue, !id.isEmpty else { return nil }
        return ProjectLaneNode(
            id: id,
            label: o["label"]?.stringValue ?? id,
            path: o["path"]?.stringValue,
            isMain: o["isMain"]?.boolValue ?? false,
            isKanban: o["isKanban"]?.boolValue ?? false,
            sessions: (o["sessions"]?.arrayValue ?? []).compactMap(Self.decodeSession))
    }

    /// `_project_tree_row` (server.py:15827-15866) → domain.
    static func decodeSession(_ value: JSONValue) -> ProjectSessionRow? {
        guard let o = value.objectValue,
              let id = o["id"]?.stringValue, !id.isEmpty else { return nil }
        return ProjectSessionRow(
            id: id,
            title: o["title"]?.stringValue ?? "",
            preview: o["preview"]?.stringValue ?? "",
            startedAt: o["started_at"]?.numberValue ?? 0,
            lastActive: o["last_active"]?.numberValue
                ?? o["started_at"]?.numberValue ?? 0,
            endedAt: o["ended_at"]?.numberValue,
            cwd: o["cwd"]?.stringValue ?? "",
            gitBranch: o["git_branch"]?.stringValue ?? "",
            messageCount: o["message_count"]?.numberValue.map(Int.init) ?? 0,
            toolCallCount: o["tool_call_count"]?.numberValue.map(Int.init) ?? 0,
            inputTokens: o["input_tokens"]?.numberValue.map(Int.init) ?? 0,
            outputTokens: o["output_tokens"]?.numberValue.map(Int.init) ?? 0,
            actualCostUsd: o["actual_cost_usd"]?.numberValue,
            estimatedCostUsd: o["estimated_cost_usd"]?.numberValue,
            model: o["model"]?.stringValue ?? "",
            profile: o["profile"]?.stringValue ?? "")
    }

    // MARK: transport

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        // Idempotent connect (P0-7) — the browser's transport starts
        // cold; the first projects RPC opens it.
        if !isTransportReady {
            try await transport.connect()
        }
        do {
            return try await transport.request(method: method, params: params)
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
    }

    private var isTransportReady: Bool {
        if case .connected = transport.state { return true }
        return false
    }

    static func mapError(_ error: JSONRPCError) -> GatewayProjectsError {
        switch error.code {
        case 5063:
            return .projectRequired(error.message)
        default:
            return .rpcFailed("\(error.message) (\(error.code))")
        }
    }

    static func mapTransportError(_ error: TransportError) -> GatewayProjectsError {
        switch error {
        case .connectionClosed(let reason):
            return .rpcFailed("connection closed: \(reason.debugDescription)")
        case .requestTimeout:
            return .rpcFailed("request timed out")
        case .invalidState(let s):
            return .rpcFailed("invalid state: \(s)")
        default:
            return .rpcFailed(String(describing: error))
        }
    }
}
