import Foundation
import os
import FleetCore

/// Dogfood r8 — concrete `ReasoningProviding` over the conversation
/// transport: read + session-scoped write of the session's reasoning level.
///
/// Wire ground truth (local gateway source, 2026-09-20):
/// - `config.get` — methods_config.py:232, key `reasoning` →
///   `_cfg_get_reasoning` (:151): `{value, display}`. Resolution: session
///   override → live agent config → global YAML default.
/// - `config.set` — methods_config_set.py:306 `_set_reasoning`:
///   `{key, value, scope: "session", session_id}` → `_kv` envelope
///   `{key, value, scope}`. Session-scoped like the YOLO toggle
///   (`config.set yolo`, server.py:14967) — never a global write.
/// - Accepted words — `hermes_constants.parse_reasoning_effort` +
///   `VALID_REASONING_EFFORTS` (the authoritative domain is FleetCore's
///   `FleetReasoningLevel`, re-verified live r8.4):
///   none|minimal|low|medium|high|xhigh|max|ultra — the slider's eight
///   stops. `setReasoning` forwards `level.rawValue` verbatim; anything
///   outside that set (numerics included) errors 4002.
public struct GatewayReasoningClient: ReasoningProviding {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    private static let log = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "reasoning-client")

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: ReasoningProviding

    public func reasoning(sessionID: String) async throws -> ReasoningState {
        // M9 fail-closed guard (precedes the connected-state check on purpose).
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        let params: JSONValue = .object([
            "key": .string("reasoning"),
            "session_id": .string(sessionID),
        ])
        do {
            let result = try await transport.request(method: "config.get", params: params)
            // `_cfg_get_reasoning` always carries `value` (defaults
            // "medium"); a missing/empty value is a malformed payload,
            // never a guess.
            guard let raw = result["value"]?.stringValue, !raw.isEmpty else {
                throw ConversationError.malformedPayload("config.get reasoning result missing 'value'")
            }
            let display = result["display"]?.stringValue
            return ReasoningState(
                level: FleetReasoningLevel(rawValue: raw),
                rawValue: raw,
                display: display
            )
        } catch let error as ConversationError {
            throw error
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw ConversationError.rpcFailed(Redaction.safeErrorDescription(error))
        }
    }

    public func setReasoning(_ level: FleetReasoningLevel, sessionID: String) async throws -> FleetReasoningLevel {
        // M9 fail-closed guard (precedes the connected-state check on purpose).
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        // EXACTLY the four params the YOLO setter uses (scope=session —
        // a menu pick must not rewrite the global).
        let params: JSONValue = .object([
            "key": .string("reasoning"),
            "value": .string(level.rawValue),
            "scope": .string("session"),
            "session_id": .string(sessionID),
        ])
        do {
            let result = try await transport.request(method: "config.set", params: params)
            // `_kv` always reports the value back; a mismatch means the
            // gateway normalized/ignored the pick — fail closed, never a
            // fake success.
            guard let reported = result["value"]?.stringValue,
                  let mapped = FleetReasoningLevel(rawValue: reported) else {
                throw ConversationError.malformedPayload("config.set reasoning result missing/unknown 'value'")
            }
            guard mapped == level else {
                throw ConversationError.rpcFailed(
                    "gateway kept a different level (\(reported)) than requested (\(level.rawValue))")
            }
            return mapped
        } catch let error as ConversationError {
            throw error
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw ConversationError.rpcFailed(Redaction.safeErrorDescription(error))
        }
    }

    // MARK: error mapping (mirrors GatewayApprovalClient)

    static func mapError(_ error: JSONRPCError) -> ConversationError {
        switch error.code {
        case 4001, 4007:
            return .sessionNotFound(Redaction.safeText(error.message))
        case 4006, 4002:
            return .invalidRequest(Redaction.safeText(error.message))
        default:
            return .rpcFailed("\(Redaction.safeText(error.message)) (\(error.code))")
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
            return .rpcFailed(Redaction.safeErrorDescription(error))
        }
    }
}
