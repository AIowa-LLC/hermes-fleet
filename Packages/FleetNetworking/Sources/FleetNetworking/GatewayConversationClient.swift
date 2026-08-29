import Foundation
import FleetCore

/// Concrete `ConversationProviding` for the Hermes gateway conversation path:
/// `session.create` / `session.resume` / `prompt.submit` / `session.interrupt`
/// over the WebSocket JSON-RPC transport, plus streamed turn-event rendering
/// (`message.*`, `tool.*`, `status.*`, `thinking/reasoning.*`,
/// `message.complete`).
///
/// M5 scope (spec §31 Conversation). Every RPC corresponds to an explicit user
/// action — this is the MUTATING seam and is deliberately separate from the M4
/// read-only `SessionHistoryProviding`: a read-only screen structurally cannot
/// reach this type (the composition root decides which seam to hand a screen).
public struct GatewayConversationClient: ConversationProviding {
    /// The gateway this client is bound to.
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    /// Stream of conversation events for this gateway's sessions. Created in
    /// `init` (single subscription) so repeated access returns the same
    /// stream; iterate it BEFORE submitting a prompt so no streamed event is
    /// missed.
    public let events: AsyncStream<ConversationEvent>

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
        self.events = Self.eventStream(transport: transport)
    }

    // MARK: ConversationProviding

    public func createSession(
        title: String?,
        profile: String?,
        model: String?,
        provider: String?,
        cols: Int?
    ) async throws -> ConversationSession {
        // M9 fail-closed guard: an unsafe profile slug never reaches the
        // transport (path traversal into the gateway's profile namespace).
        if let profile, !RoutingGuard.isValidRouteComponent(profile) {
            throw ConversationError.invalidSessionKey("profile is not a safe routing key: \(profile)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        var params: [String: JSONValue] = [:]
        if let title { params["title"] = .string(title) }
        if let profile { params["profile"] = .string(profile) }
        if let model { params["model"] = .string(model) }
        if let provider { params["provider"] = .string(provider) }
        if let cols { params["cols"] = .number(Double(cols)) }
        do {
            let result = try await transport.request(method: "session.create", params: .object(params))
            return try Self.decodeSession(result)
        } catch let error as JSONRPCError {
            throw Self.mapRPCError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw ConversationError.rpcFailed(String(describing: error))
        }
    }

    public func resumeSession(sessionID: String) async throws -> ConversationSession {
        // M9 fail-closed guard (precedes the connected-state check on purpose).
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        let params: JSONValue = .object(["session_id": .string(sessionID)])
        do {
            let result = try await transport.request(method: "session.resume", params: params)
            return try Self.decodeSession(result)
        } catch let error as JSONRPCError {
            throw Self.mapRPCError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw ConversationError.rpcFailed(String(describing: error))
        }
    }

    public func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
        // M9 fail-closed guard (precedes the connected-state check on purpose).
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        let params: JSONValue = .object([
            "session_id": .string(sessionID),
            "text": .string(text),
        ])
        do {
            let result = try await transport.request(method: "prompt.submit", params: params)
            guard let status = result["status"]?.stringValue else {
                throw ConversationError.malformedPayload("prompt.submit result missing 'status'")
            }
            return PromptSubmission(status: status)
        } catch let error as ConversationError {
            throw error
        } catch let error as JSONRPCError {
            throw Self.mapRPCError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw ConversationError.rpcFailed(String(describing: error))
        }
    }

    public func interrupt(sessionID: String) async throws -> InterruptResult {
        // M9 fail-closed guard (precedes the connected-state check on purpose).
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw ConversationError.invalidSessionKey("session_id is not a safe session key: \(sessionID)")
        }
        guard case .connected = transport.state else { throw ConversationError.notConnected }
        let params: JSONValue = .object(["session_id": .string(sessionID)])
        do {
            let result = try await transport.request(method: "session.interrupt", params: params)
            guard let status = result["status"]?.stringValue else {
                throw ConversationError.malformedPayload("session.interrupt result missing 'status'")
            }
            return InterruptResult(status: status, turnIsolation: result["turn_isolation"]?.boolValue)
        } catch let error as ConversationError {
            throw error
        } catch let error as JSONRPCError {
            throw Self.mapRPCError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        } catch {
            throw ConversationError.rpcFailed(String(describing: error))
        }
    }

    // MARK: decoding (wire → domain)

    /// `session.create` / `session.resume` →
    /// `{session_id, stored_session_id?, message_count, messages: [...],
    /// info?: {model?, provider?, profile_name?}}`.
    static func decodeSession(_ result: JSONValue) throws -> ConversationSession {
        guard let sessionID = result["session_id"]?.stringValue, !sessionID.isEmpty else {
            throw ConversationError.malformedPayload("conversation result missing 'session_id'")
        }
        let messages = result["messages"]?.arrayValue?
            .compactMap(GatewaySessionHistoryClient.decodeMessage) ?? []
        let count = result["message_count"]?.numberValue.map(Int.init) ?? messages.count
        let info = result["info"]?.objectValue ?? [:]
        return ConversationSession(
            sessionID: sessionID,
            storedSessionID: result["stored_session_id"]?.stringValue,
            messageCount: count,
            messages: messages,
            model: info["model"]?.stringValue,
            provider: info["provider"]?.stringValue,
            profileName: info["profile_name"]?.stringValue
        )
    }

    /// Map one inbound `GatewayEvent` onto the conversation domain. Returns
    /// `nil` for non-conversation handshake events (`gateway.ready` — consumed
    /// by the transport's own ready handshake, not a turn event). Unknown
    /// conversation event types are preserved as `.unknown` (spec §5.5).
    static func decodeEvent(_ event: GatewayEvent) -> ConversationEvent? {
        let sid = event.sessionID ?? ""
        let payload = event.payload?.objectValue ?? [:]

        switch event.type {
        case .gatewayReady:
            // Handshake only; not a conversation event.
            return nil
        case .sessionInfo:
            return .sessionInfo(
                sessionID: sid,
                model: payload["model"]?.stringValue,
                provider: payload["provider"]?.stringValue,
                title: payload["title"]?.stringValue,
                cwd: payload["cwd"]?.stringValue,
                profileName: payload["profile_name"]?.stringValue
            )
        case .messageStart:
            return .messageStart(sessionID: sid)
        case .messageDelta:
            return .messageDelta(
                sessionID: sid,
                text: payload["text"]?.stringValue ?? "",
                rendered: payload["rendered"]?.stringValue
            )
        case .messageInterim:
            return .messageInterim(
                sessionID: sid,
                text: payload["text"]?.stringValue ?? "",
                alreadyStreamed: payload["already_streamed"]?.boolValue ?? false
            )
        case .messageComplete:
            return .messageComplete(
                sessionID: sid,
                text: payload["text"]?.stringValue ?? "",
                status: payload["status"]?.stringValue,
                error: payload["error"]?.stringValue
            )
        case .thinkingDelta:
            return .thinkingDelta(sessionID: sid, text: payload["text"]?.stringValue ?? "")
        case .reasoningDelta:
            return .reasoningDelta(sessionID: sid, text: payload["text"]?.stringValue ?? "")
        case .reasoningAvailable:
            return .reasoningAvailable(sessionID: sid, text: payload["text"]?.stringValue ?? "")
        case .statusUpdate:
            return .statusUpdate(
                sessionID: sid,
                kind: payload["kind"]?.stringValue ?? "",
                text: payload["text"]?.stringValue ?? ""
            )
        case .toolStart:
            return .toolStart(
                sessionID: sid,
                toolID: payload["tool_id"]?.stringValue ?? "",
                name: payload["name"]?.stringValue ?? "",
                context: payload["context"]?.stringValue,
                argsText: Self.compactJSON(payload["args"])
            )
        case .toolGenerating:
            return .toolGenerating(sessionID: sid, name: payload["name"]?.stringValue ?? "")
        case .toolProgress:
            return .toolProgress(
                sessionID: sid,
                toolID: payload["tool_id"]?.stringValue,
                name: payload["name"]?.stringValue,
                text: payload["text"]?.stringValue ?? payload["preview"]?.stringValue
            )
        case .toolComplete:
            return .toolComplete(
                sessionID: sid,
                toolID: payload["tool_id"]?.stringValue ?? "",
                name: payload["name"]?.stringValue ?? "",
                summary: payload["summary"]?.stringValue
            )
        case .backgroundComplete:
            return .backgroundComplete(
                sessionID: sid,
                taskID: payload["task_id"]?.stringValue,
                text: payload["text"]?.stringValue
            )
        case .error:
            return .error(sessionID: sid, message: payload["message"]?.stringValue ?? "")
        case .unknown:
            return .unknown(sessionID: sid, rawType: event.rawType)
        }
    }

    /// The streamed event channel: maps every inbound `GatewayEvent` onto the
    /// conversation domain, dropping non-conversation handshake events and
    /// preserving unknown conversation types.
    static func eventStream(transport: GatewayWebSocketTransport) -> AsyncStream<ConversationEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await event in transport.subscribeToEvents() {
                    if let conversationEvent = decodeEvent(event) {
                        continuation.yield(conversationEvent)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Compact JSON text for an optional JSON member (tool args/result), nil
    /// when absent or unencodable — never a failure.
    static func compactJSON(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONRPCCodec.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: error mapping

    /// Map JSON-RPC error codes onto the conversation vocabulary.
    static func mapRPCError(_ error: JSONRPCError) -> ConversationError {
        switch error.code {
        case 4001:
            // `_sess_nowait` rejects a runtime id the gateway no longer holds
            // (prompt.submit / session.interrupt paths) with 4001.
            return .sessionNotFound(error.message)
        case 4007:
            // `session.resume` does its own DB lookup and reports an unknown
            // stored session with 4007 (methods_session.py). Both codes mean
            // "session gone — resume again / re-create".
            return .sessionNotFound(error.message)
        case 4006:
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
