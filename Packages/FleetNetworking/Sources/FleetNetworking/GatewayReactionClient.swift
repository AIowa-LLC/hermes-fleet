import Foundation
import os
import FleetCore

/// R10-T2 — concrete `ReactionProviding` over the conversation transport:
/// the Tapback-style `message.react` write path.
///
/// Wire ground truth (hermes-agent 0.21.0, verified 2026-09-04):
/// - `message.react` (tui_gateway/methods_session.py:1563-1614): params
///   `{session_id, row_id? | newest_role in {user,assistant}, emoji}` —
///   `emoji` is a non-empty string OR an explicit JSON null (clear);
///   optional `author in {user,agent}` (server default "user", exactly the
///   local user reacting, so the client omits it). Result
///   `{row_id: Int, reactions: [{emoji, author, at?}]}` — the message's
///   FULL post-write reaction list (server truth for settling the
///   optimistic update).
/// - Errors: 4023 row_id-or-newest_role required, 4024 emoji empty, 4025
///   author invalid, 4040 message not found in this session / no message to
///   react to yet, 4001 runtime session not found (recover via
///   session.resume, server.py:3676-3696), 5007 db.
/// - Retract semantics are SERVER-side (hermes_state.set_message_reaction
///   :13008-13040): one reaction per author per message; re-sending the
///   same emoji retracts; different emoji replaces; null clears. The client
///   mirrors them only for the optimistic snapshot.
/// - Read-back rides `session.history` rows' `display_metadata.reactions`
///   (decoded in `GatewaySessionHistoryClient.decodeMessage`), NOT this
///   client — there is no separate reactions fetch RPC.
public struct GatewayReactionClient: ReactionProviding {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    private static let log = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "gateway-reactions")

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: - ReactionProviding

    public func react(
        sessionID: String,
        target: MessageReactionTarget,
        emoji: String?
    ) async throws -> MessageReactionResult {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ReactionError.rpcFailed("session_id is not a safe session key: \(sessionID)")
        }
        // Client-side guards mirroring the server's fail-closed checks —
        // fail BEFORE the RPC round trip rather than learning 4023/4024.
        if target.rowID == nil && target.newestRole == nil {
            throw ReactionError.targetRequired("row_id or newest_role required")
        }
        if let emoji, emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ReactionError.emptyEmoji("emoji must be a non-empty string or null")
        }
        guard case .connected = transport.state else {
            throw ReactionError.notConnected
        }

        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            // Explicit JSON null for the clear — the server distinguishes
            // `emoji: null` from an absent key (methods_session.py:1585).
            "emoji": emoji.map { JSONValue.string($0) } ?? .null,
        ]
        switch target {
        case .durable(let rowID):
            params["row_id"] = .number(Double(rowID) ?? 0)
        case .newest(let role):
            params["newest_role"] = .string(role)
        }

        let result: JSONValue
        do {
            result = try await transport.request(method: "message.react", params: .object(params))
        } catch let error as JSONRPCError {
            throw Self.mapRPCError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
        return try Self.decodeResult(result)
    }

    // MARK: decoding (wire → domain)

    /// `{row_id: Int, reactions: [{emoji, author, at?}]}` → domain.
    static func decodeResult(_ result: JSONValue) throws -> MessageReactionResult {
        guard let object = result.objectValue else {
            throw ReactionError.malformedResponse(detail: "message.react result was not an object")
        }
        guard let rowNumber = object["row_id"]?.numberValue else {
            throw ReactionError.malformedResponse(detail: "message.react result missing 'row_id'")
        }
        let reactions = (object["reactions"]?.arrayValue ?? []).compactMap { item -> MessageReaction? in
            guard let entry = item.objectValue else { return nil }
            guard let emoji = entry["emoji"]?.stringValue, !emoji.isEmpty else { return nil }
            return MessageReaction(
                emoji: emoji,
                author: entry["author"]?.stringValue ?? "user",
                at: entry["at"]?.numberValue
            )
        }
        return MessageReactionResult(rowID: String(Int(rowNumber)), reactions: reactions)
    }

    /// Gateway error codes onto the typed vocabulary
    /// (methods_session.py:1593-1611).
    static func mapRPCError(_ error: JSONRPCError) -> ReactionError {
        switch error.code {
        case 4023: return .targetRequired(error.message)
        case 4024: return .emptyEmoji(error.message)
        case 4040: return .messageNotFound(error.message)
        case 4001: return .sessionNotFound(error.message)
        default: return .rpcFailed(error.message)
        }
    }

    /// Transport-level failure onto the seam vocabulary (the seam stays
    /// free of `TransportError`).
    static func mapTransportError(_ error: TransportError) -> ReactionError {
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
