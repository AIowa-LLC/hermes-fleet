import Foundation
import os
import FleetCore

/// R9-T1 — concrete `ApprovalsProviding` over the conversation transport:
/// respond to pending dangerous-command approvals + flip the per-session
/// YOLO bypass. The push event (`approval.request`) is decoded by
/// `GatewayConversationClient.decodeEvent` (it rides the SAME event channel
/// as the turn events — no second subscription, mirroring the M5 pattern).
///
/// Wire ground truth (hermes-agent 0.21.0):
/// - `approval.respond` — tui_gateway/methods_prompt.py:1881:
///   params `{session_id, choice: once|session|always|deny, request_id?,
///   all?}` → `{"resolved": N}`; a stale live sid falls back to durable-id
///   resolution server-side (#91684), so an old session id still resolves.
/// - `config.set key=yolo` — tui_gateway/server.py:14967-15035:
///   `scope=session` (default) flips ONLY the session's `_session_yolo`
///   flag (tools/approval.py:2977 `enable_session_yolo`), never global
///   config; result `{key, value: "1"|"0", scope: "session"}`.
/// - `approval.pending` — methods_prompt.py:1804: params `{session_id}` →
///   `{"approvals": [...]}` (replay-safe snapshots) for reconnect restore.
public struct GatewayApprovalClient: ApprovalsProviding {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    private static let log = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "approval-client")

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: ApprovalsProviding

    public func respond(
        sessionID: String,
        requestID: String,
        choice: ApprovalChoice,
        all: Bool
    ) async throws -> Int {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        // EXACTLY the four documented params (methods_prompt.py:1882-1906).
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "choice": .string(choice.rawValue),
            "request_id": .string(requestID),
            "all": .bool(all),
        ])
        do {
            let result = try await transport.request(method: "approval.respond", params: params)
            let resolved = result["resolved"]?.numberValue.map(Int.init) ?? 0
            Self.log.info(
                "approval.respond choice=\(choice.rawValue, privacy: .public) resolved=\(resolved, privacy: .public)")
            return resolved
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
    }

    public func setSessionYolo(_ enabled: Bool, sessionID: String) async throws -> Bool {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        // server.py:15016-15032: per-session scope — value "1"/"0"; the
        // session's flag flips and a session.info event reflects the change.
        let params: JSONValue = .object([
            "key": .string("yolo"),
            "value": .string(enabled ? "1" : "0"),
            "scope": .string("session"),
            "session_id": .string(sessionID),
        ])
        do {
            let result = try await transport.request(method: "config.set", params: params)
            let value = result["value"]?.stringValue ?? (enabled ? "1" : "0")
            return value == "1"
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
    }

    // MARK: Pending snapshot (reconnect restore)

    /// `approval.pending` — the replay-safe list of unresolved approvals for
    /// a session (methods_prompt.py:1804). Used to restore a banner whose
    /// push event was missed while detached (the server queue stays
    /// authoritative — this is a read, not a claim).
    public func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        let params: JSONValue = .object(["session_id": .string(sessionID)])
        do {
            let result = try await transport.request(method: "approval.pending", params: params)
            let rows = result["approvals"]?.arrayValue ?? []
            // Same tolerant decode as the push event: rows without a
            // request_id are dropped (never surfaced, never fatal).
            return rows.compactMap { Self.decodeApprovalRequest(payload: $0, sessionID: sessionID) }
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
    }

    // MARK: decoding (wire → domain, shared with the push event path)

    /// Decode one approval payload (`_approval_request_payload` shape,
    /// server.py:3036) into the domain. Returns nil — fail-soft — when the
    /// required `request_id` is missing or not a string.
    public static func decodeApprovalRequest(payload: JSONValue?, sessionID: String) -> ApprovalRequest? {
        guard let o = payload?.objectValue,
              let requestID = o["request_id"]?.stringValue, !requestID.isEmpty else {
            log.warning("approval.request dropped: missing request_id (fail-soft)")
            return nil
        }
        return ApprovalRequest(
            requestID: requestID,
            sessionID: sessionID,
            command: o["command"]?.stringValue ?? "",
            detail: o["description"]?.stringValue,
            choices: o["choices"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }

    // MARK: error mapping (mirrors GatewayConversationClient)

    static func mapError(_ error: JSONRPCError) -> ConversationError {
        switch error.code {
        case 4001, 4007:
            return .sessionNotFound(error.message)
        case 4006, 4002:
            return .invalidRequest(error.message)
        default:
            return .rpcFailed("\(error.message) (\(error.code))")
        }
    }

    static func mapTransportError(_ error: TransportError) -> ConversationError {
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
