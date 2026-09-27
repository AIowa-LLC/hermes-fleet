import Foundation
import os
import FleetCore

/// Live Ops v1 — concrete `LiveOpsProviding` (fleet-wide, read-only session
/// observation) + `LiveOpsSubagentControlling` (attached-session child
/// controls) over ONE gateway's conversation transport. Mirrors
/// `GatewayApprovalClient`'s shape (same guard/error-mapping style, same
/// per-gateway construction) so the app composition root wires it exactly
/// like the other per-gateway clients: one `GatewayWebSocketTransport`, one
/// client.
///
/// Wire ground truth (hermes-agent origin/main 6636b08) — see the extended
/// notes at the top of `FleetCore/LiveOps.swift` for the full join-key
/// derivation; the short version:
/// - `session.active_list` (tui_gateway/methods_session.py:908) →
///   `{"sessions": [{current, id, last_active, message_count, model,
///   preview, session_key, started_at, status, title}]}`.
/// - `delegation.status` (methods_session.py:2133) →
///   `{"active": [...], "paused", "max_spawn_depth",
///   "max_concurrent_children"}`; each `active` row is the public projection
///   of a registry record (`_PRIVATE_RECORD_KEYS` stripped — agent handle,
///   the PRIVATE `owner_session_id`, owner transport/session objects, and
///   `accepting_steer` never cross this RPC). The row's PUBLIC
///   `owner_agent_session_id` is the durable owning-conversation session id
///   (`tools/delegate_tool_child_run.py:328`) — it joins against
///   `active_list`'s `session_key`, never its `id`.
/// - `subagent.list` (tui_gateway/methods_subagents.py:29) is SESSION-scoped
///   (params `{session_id}`) and requires `_current_session_steer_authority`
///   — this client's transport must be the one attached to that live
///   session, or the gateway answers JSON-RPC error 4001. Its rows DO
///   include `accepting_steer` (`_SUBAGENT_SNAPSHOT_FIELDS`,
///   methods_subagents.py:12) since the caller is already authorized for
///   that session.
/// - `subagent.tail` → `{available, text, truncated}` (≤16 KiB,
///   methods_subagents.py:66); `subagent.interrupt` → `{found, subagent_id}`
///   (methods_subagents.py:42); `subagent.steer`
///   (methods_session.py:2147) → `{"status": "queued"|"rejected",
///   subagent_id, text}` — NOTE steer never throws 4001 for a not-attached
///   transport (it degrades to `status: "rejected"`, ok response); 4001 from
///   `subagent.steer` only means the `session_id` itself is not a live
///   session at all (`_sess_nowait`).
/// - Any unknown method answers JSON-RPC -32601 → `.unsupported` (a coverage
///   state / typed error here, never a hard failure).
/// - `session.activate` is NEVER called anywhere in this file — the
///   monitoring path here only ever READS `session.active_list` /
///   `delegation.status` / `subagent.*`; attaching to a session is a
///   separate, deliberate user action outside this client's scope.
public struct GatewayLiveOpsClient: LiveOpsProviding, LiveOpsSubagentControlling {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    /// Hostile/misbehaving-gateway bound (spec: "a hostile gateway can't
    /// blow memory") — independent of any real fleet's expected scale.
    static let maxSessionRows = 200
    static let maxSubagentRows = 500

    private static let log = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "liveops-client")

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: LiveOpsProviding

    /// This client is bound to exactly one gateway at construction; `gateway`
    /// is accepted to satisfy the fleet-wide `LiveOpsProviding` shape (a
    /// caller holding one client per registered gateway calls each with its
    /// own id) but the SNAPSHOT ALWAYS reports `self.gatewayID` — a caller
    /// that passes a mismatched id has a wiring bug, not a routing choice
    /// this client can correct.
    public func snapshot(gateway: GatewayID) async -> LiveOpsGatewaySnapshot {
        await snapshot()
    }

    /// `session.active_list` (+ best-effort `delegation.status` join).
    /// Never throws: every failure classifies into `LiveOpsGatewayCoverage`.
    public func snapshot() async -> LiveOpsGatewaySnapshot {
        let now = Date()
        let rows: [JSONValue]
        do {
            try await ensureTransportConnected()
            let result = try await transport.request(method: "session.active_list", params: .object([:]))
            rows = result["sessions"]?.arrayValue ?? []
        } catch let error as JSONRPCError {
            return LiveOpsGatewaySnapshot(
                gatewayID: gatewayID, coverage: Self.coverage(for: error), operations: [], observedAt: now)
        } catch let error as TransportError {
            return LiveOpsGatewaySnapshot(
                gatewayID: gatewayID, coverage: Self.coverage(for: error), operations: [], observedAt: now)
        } catch {
            return LiveOpsGatewaySnapshot(
                gatewayID: gatewayID,
                coverage: .failed(reason: Redaction.safeErrorDescription(error)),
                operations: [], observedAt: now)
        }

        // Bound the row count before any further work — a hostile/broken
        // gateway reporting an unbounded session list cannot blow memory.
        var operations = rows.prefix(Self.maxSessionRows).compactMap {
            Self.decodeOperation(gatewayID: gatewayID, row: $0)
        }

        // Best-effort delegation join: unsupported/failed delegation.status
        // leaves every operation's `subagents` `nil` (unknown), never `[]`
        // (known-empty) and never fails the whole snapshot — the sessions
        // themselves are still real, authoritative data.
        if let byOwner = await fetchSubagentsByOwner() {
            operations = operations.map { op in
                LiveOperation(
                    id: op.id,
                    sessionKey: op.sessionKey,
                    title: op.title,
                    preview: op.preview,
                    model: op.model,
                    startedAt: op.startedAt,
                    lastActive: op.lastActive,
                    messageCount: op.messageCount,
                    status: op.status,
                    subagents: byOwner[op.sessionKey] ?? []
                )
            }
        }

        return LiveOpsGatewaySnapshot(
            gatewayID: gatewayID, coverage: .reporting, operations: operations, observedAt: now)
    }

    /// `delegation.status` grouped by `owner_agent_session_id` (the durable
    /// join key — see file-top note). Returns `nil` on ANY failure
    /// (unsupported method, transport error, malformed response) so the
    /// caller can distinguish "known zero subagents fleet-wide" from
    /// "delegation status unavailable this refresh."
    private func fetchSubagentsByOwner() async -> [String: [LiveOpsSubagent]]? {
        do {
            let result = try await transport.request(method: "delegation.status", params: .object([:]))
            guard let rows = result["active"]?.arrayValue else { return nil }
            var grouped: [String: [LiveOpsSubagent]] = [:]
            for row in rows.prefix(Self.maxSubagentRows) {
                guard let (owner, subagent) = Self.decodeSubagentWithOwner(row) else { continue }
                grouped[owner, default: []].append(subagent)
            }
            return grouped
        } catch {
            return nil
        }
    }

    // MARK: LiveOpsSubagentControlling

    public func listSubagents(sessionID: String) async throws -> [LiveOpsSubagent] {
        try Self.requireValidSessionKey(sessionID)
        let params: JSONValue = .object(["session_id": .string(sessionID)])
        do {
            try await ensureTransportConnected()
            let result = try await transport.request(method: "subagent.list", params: params)
            let rows = result["subagents"]?.arrayValue ?? []
            return rows.prefix(Self.maxSubagentRows).compactMap(Self.decodeSubagent)
        } catch let error as JSONRPCError {
            throw Self.mapControlError(error)
        } catch let error as TransportError {
            throw Self.mapControlTransportError(error)
        }
    }

    public func tail(subagentID: String, sessionID: String) async throws -> LiveOpsSubagentTail {
        try Self.requireValidSessionKey(sessionID)
        guard !subagentID.isEmpty else {
            throw LiveOpsControlError.rpcFailed("subagent_id required")
        }
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "subagent_id": .string(subagentID),
        ])
        do {
            try await ensureTransportConnected()
            let result = try await transport.request(method: "subagent.tail", params: params)
            return LiveOpsSubagentTail(
                available: result["available"]?.boolValue ?? false,
                text: result["text"]?.stringValue ?? "",
                truncated: result["truncated"]?.boolValue ?? false
            )
        } catch let error as JSONRPCError {
            throw Self.mapControlError(error)
        } catch let error as TransportError {
            throw Self.mapControlTransportError(error)
        }
    }

    public func steer(subagentID: String, sessionID: String, text: String) async throws -> LiveOpsSteerResult {
        try Self.requireValidSessionKey(sessionID)
        guard !subagentID.isEmpty else {
            throw LiveOpsControlError.rpcFailed("subagent_id required")
        }
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "subagent_id": .string(subagentID),
            "text": .string(text),
        ])
        do {
            try await ensureTransportConnected()
            let result = try await transport.request(method: "subagent.steer", params: params)
            // "queued" is not "delivered" — surfaced verbatim as the enum;
            // anything else (including a missing/garbled status) is treated
            // as rejected, never silently upgraded to queued.
            return result["status"]?.stringValue == "queued" ? .queued : .rejected
        } catch let error as JSONRPCError {
            throw Self.mapControlError(error)
        } catch let error as TransportError {
            throw Self.mapControlTransportError(error)
        }
    }

    public func interrupt(subagentID: String, sessionID: String) async throws -> Bool {
        try Self.requireValidSessionKey(sessionID)
        guard !subagentID.isEmpty else {
            throw LiveOpsControlError.rpcFailed("subagent_id required")
        }
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "subagent_id": .string(subagentID),
        ])
        do {
            try await ensureTransportConnected()
            let result = try await transport.request(method: "subagent.interrupt", params: params)
            return result["found"]?.boolValue ?? false
        } catch let error as JSONRPCError {
            throw Self.mapControlError(error)
        } catch let error as TransportError {
            throw Self.mapControlTransportError(error)
        }
    }

    // MARK: session-key guard (M9)

    /// Per-gateway transports are created cold by the composition root. Every
    /// operation owns the responsibility for opening its transport, matching
    /// the other gateway clients. `connect()` is idempotent when already open.
    private func ensureTransportConnected() async throws {
        if case .connected = transport.state { return }
        try await transport.connect()
    }

    private static func requireValidSessionKey(_ sessionID: String) throws {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw LiveOpsControlError.rpcFailed("session_id is not a safe session key: \(sessionID)")
        }
    }

    // MARK: decoding (wire → domain, tolerant — malformed rows dropped, never fatal)

    /// One `active_list.sessions[]` row. Requires a non-empty `id` (runtime
    /// sid) AND a non-empty `session_key` (the durable join key) — a row
    /// missing either is dropped rather than surfaced with a fabricated
    /// identity.
    static func decodeOperation(gatewayID: GatewayID, row: JSONValue) -> LiveOperation? {
        guard let runtimeID = row["id"]?.stringValue, !runtimeID.isEmpty,
              let sessionKey = row["session_key"]?.stringValue, !sessionKey.isEmpty
        else {
            log.warning("session.active_list row dropped: missing id/session_key (fail-soft)")
            return nil
        }
        let statusWire = row["status"]?.stringValue ?? "idle"
        return LiveOperation(
            id: LiveOperationID(gatewayID: gatewayID, runtimeSessionID: runtimeID),
            sessionKey: sessionKey,
            title: row["title"]?.stringValue ?? "",
            preview: row["preview"]?.stringValue ?? "",
            model: row["model"]?.stringValue ?? "",
            startedAt: Date(timeIntervalSince1970: row["started_at"]?.numberValue ?? 0),
            lastActive: Date(timeIntervalSince1970: row["last_active"]?.numberValue ?? 0),
            messageCount: max(0, row["message_count"]?.intValue ?? 0),
            status: LiveOperationStatus(wireValue: statusWire),
            subagents: nil
        )
    }

    /// One `delegation.status.active[]` or `subagent.list.subagents[]` row.
    /// Requires a non-empty `subagent_id`; every other field degrades to a
    /// tolerant default rather than dropping the row.
    static func decodeSubagent(_ row: JSONValue) -> LiveOpsSubagent? {
        guard let subagentID = row["subagent_id"]?.stringValue, !subagentID.isEmpty else {
            log.warning("subagent row dropped: missing subagent_id (fail-soft)")
            return nil
        }
        let parentID = row["parent_id"]?.stringValue
        return LiveOpsSubagent(
            subagentID: subagentID,
            parentID: (parentID?.isEmpty ?? true) ? nil : parentID,
            depth: max(0, row["depth"]?.intValue ?? 0),
            goal: row["goal"]?.stringValue ?? "",
            model: row["model"]?.stringValue,
            startedAt: Date(timeIntervalSince1970: row["started_at"]?.numberValue ?? 0),
            status: row["status"]?.stringValue ?? "",
            toolCount: max(0, row["tool_count"]?.intValue ?? 0),
            lastTool: row["last_tool"]?.stringValue,
            acceptingSteer: row["accepting_steer"]?.boolValue
        )
    }

    /// `delegation.status` variant: additionally requires the PUBLIC
    /// `owner_agent_session_id` (the durable join key) — a row without one
    /// cannot be attributed to any operation and is dropped rather than
    /// guessed at.
    static func decodeSubagentWithOwner(_ row: JSONValue) -> (owner: String, subagent: LiveOpsSubagent)? {
        guard let owner = row["owner_agent_session_id"]?.stringValue, !owner.isEmpty else {
            return nil
        }
        guard let subagent = decodeSubagent(row) else { return nil }
        return (owner, subagent)
    }

    // MARK: error mapping

    static func coverage(for error: JSONRPCError) -> LiveOpsGatewayCoverage {
        error.code == -32601
            ? .unsupported
            : .failed(reason: "\(Redaction.safeText(error.message)) (\(error.code))")
    }

    static func coverage(for error: TransportError) -> LiveOpsGatewayCoverage {
        switch error {
        case .authenticationFailed, .authSurfaceStatus, .authStrategyRejected:
            return .authFailed
        default:
            return .failed(reason: Redaction.safeErrorDescription(error))
        }
    }

    static func mapControlError(_ error: JSONRPCError) -> LiveOpsControlError {
        switch error.code {
        case -32601:
            return .unsupported
        case 4001:
            return .notAttached
        default:
            return .rpcFailed("\(Redaction.safeText(error.message)) (\(error.code))")
        }
    }

    static func mapControlTransportError(_ error: TransportError) -> LiveOpsControlError {
        switch error {
        case .authenticationFailed(let s):
            return .authFailed(Redaction.safeText(s))
        case .authSurfaceStatus(let code):
            return .authFailed("HTTP \(code)")
        case .authStrategyRejected(let reason):
            return .authFailed(reason.rawValue)
        default:
            return .rpcFailed(Redaction.safeErrorDescription(error))
        }
    }
}
