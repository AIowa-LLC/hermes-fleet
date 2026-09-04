import Foundation
import FleetCore

/// Concrete `SessionHistoryProviding` that reads session history/status from a
/// Hermes gateway over the WebSocket JSON-RPC transport.
///
/// M4 scope (spec §31 Sessions + §5.4): read-only `session.history` /
/// `session.status`. This type sends ONLY those two read methods — it contains
/// no code path that creates, resumes, interrupts, closes, or deletes a
/// session, and no prompt submission. A caller that wants to mutate a session
/// must go through a different (later-milestone) type; the read path never
/// implies ownership.
public struct GatewaySessionHistoryClient: SessionHistoryProviding {
    /// The gateway this client is bound to.
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: SessionHistoryProviding

    public func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
        // M9 fail-closed guard (precedes the connected-state check on purpose).
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw SessionHistoryError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw SessionHistoryError.notConnected }
        let params: JSONValue = .object(["session_id": .string(sessionID)])
        do {
            let result = try await transport.request(method: "session.history", params: params)
            return try Self.decodeHistory(sessionID: sessionID, result)
        } catch let error as SessionHistoryError {
            // Decode-level failures (malformed payload) pass through unchanged.
            throw error
        } catch let error as JSONRPCError where error.code == 4001 {
            throw SessionHistoryError.sessionNotFound(error.message)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw SessionHistoryError.rpcFailed(String(describing: error))
        }
    }

    public func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
        // M9 fail-closed guard (precedes the connected-state check on purpose).
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw SessionHistoryError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw SessionHistoryError.notConnected }
        let params: JSONValue = .object(["session_id": .string(sessionID)])
        do {
            let result = try await transport.request(method: "session.status", params: params)
            return try Self.decodeStatus(sessionID: sessionID, result)
        } catch let error as SessionHistoryError {
            // Decode-level failures (malformed payload) pass through unchanged.
            throw error
        } catch let error as JSONRPCError where error.code == 4001 {
            throw SessionHistoryError.sessionNotFound(error.message)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw SessionHistoryError.rpcFailed(String(describing: error))
        }
    }

    // MARK: decoding (wire → domain)

    /// `session.history` → `{"count": N, "messages": [ ... ]}` where each
    /// message follows the `_history_to_messages` projection (`server.py:9296`).
    static func decodeHistory(sessionID: String, _ result: JSONValue) throws -> SessionHistory {
        let object = result.objectValue
        let messagesJSON = object?["messages"]?.arrayValue ?? []
        let messages = messagesJSON.compactMap(Self.decodeMessage)
        let count = object?["count"]?.numberValue.map(Int.init) ?? messages.count
        return SessionHistory(sessionID: sessionID, count: count, messages: messages)
    }

    /// One projected message:
    /// `{role, text, timestamp?, row_id?, display_kind?, reasoning?, ...}` and
    /// tool rows `{role: "tool", name, context, args?}`. Tolerant: any
    /// missing/unknown member defaults rather than failing the whole history.
    static func decodeMessage(_ json: JSONValue) -> SessionMessage? {
        guard let object = json.objectValue else { return nil }
        let roleWire = object["role"]?.stringValue ?? ""
        let role = SessionMessageRole(wire: roleWire)
        // Preserve content even for unknown roles (tolerant decode); drop only
        // rows with no renderable content at all.
        let text = object["text"]?.stringValue ?? ""
        let reasoning = Self.firstReasoningText(in: object)
        let toolName = object["name"]?.stringValue
        let toolContext = object["context"]?.stringValue
        let rowID: String?
        if let r = object["row_id"]?.numberValue {
            rowID = String(Int(r))
        } else {
            rowID = object["row_id"]?.stringValue
        }
        // R10-T2: `display_metadata.reactions` — the read-back surface for
        // reactions (durable rows only; `_history_to_messages` server.py:
        // 9936 forwards display_metadata per message). Tolerant of every
        // malformed shape: nil when absent, empty when undecodable.
        let reactions = object["display_metadata"].flatMap {
            Self.decodeReactions(fromMetadata: $0)
        }
        let message = SessionMessage(
            role: role,
            text: text,
            timestamp: object["timestamp"]?.numberValue,
            rowID: rowID,
            displayKind: object["display_kind"]?.stringValue,
            reasoning: reasoning,
            toolName: toolName,
            toolContext: toolContext,
            reactions: reactions
        )
        guard message.hasContent else { return nil }
        return message
    }

    /// `display_metadata.reactions` → domain reactions. Returns nil when the
    /// metadata discloses no decodable reactions (absent / non-object /
    /// reactions not an array) — malformed shapes are treated as not
    /// disclosed, matching the SessionMessage nil contract.
    static func decodeReactions(fromMetadata metadata: JSONValue) -> [MessageReaction]? {
        guard let meta = metadata.objectValue,
              let list = meta["reactions"]?.arrayValue else { return nil }
        return list.compactMap { item in
            guard let entry = item.objectValue,
                  let emoji = entry["emoji"]?.stringValue,
                  !emoji.isEmpty else { return nil }
            return MessageReaction(
                emoji: emoji,
                author: entry["author"]?.stringValue ?? "user",
                at: entry["at"]?.numberValue
            )
        }
    }

    /// The gateway discloses reasoning under several key names across versions
    /// (`reasoning`, `reasoning_content`, `reasoning_details`); take the first
    /// non-empty one (spec §5.5 tolerant decode).
    static func firstReasoningText(in object: [String: JSONValue]) -> String? {
        for key in ["reasoning", "reasoning_content", "reasoning_details"] {
            if let value = object[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// `session.status` → `{"output": "..."}` (methods_session.py:2775).
    static func decodeStatus(sessionID: String, _ result: JSONValue) throws -> SessionStatus {
        guard let output = result["output"]?.stringValue else {
            throw SessionHistoryError.malformedPayload("session.status result missing 'output'")
        }
        var parsed = SessionStatus.parse(output: output)
        if parsed.sessionID == nil {
            parsed = SessionStatus(
                rawOutput: parsed.rawOutput,
                sessionID: sessionID.isEmpty ? nil : sessionID,
                model: parsed.model,
                provider: parsed.provider,
                title: parsed.title,
                agentRunning: parsed.agentRunning
            )
        }
        return parsed
    }

    /// Map a transport-level failure onto the read-path error vocabulary
    /// (the seam stays free of `TransportError`).
    static func mapTransportError(_ error: TransportError) -> SessionHistoryError {
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
