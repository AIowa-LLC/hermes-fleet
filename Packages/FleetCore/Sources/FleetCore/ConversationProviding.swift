import Foundation

/// The conversation streaming seam that keeps SwiftUI free of JSON-RPC /
/// WebSocket plumbing (mirrors `SessionHistoryProviding` / M0 guard).
///
/// M5 scope (spec §31 Conversation): create/resume a session, submit a prompt,
/// render the streamed message/tool/status/thinking/reasoning events, complete
/// a turn (`message.complete`) and interrupt a running turn. The seam is
/// EXPLICIT-ACTION ONLY: every method corresponds to a deliberate user action
/// (open/create a chat, send, stop) — never an implicit ownership claim
/// (spec §5.4). Unlike the M4 read path this seam intentionally mutates the
/// session transport, so it is a separate protocol from
/// `SessionHistoryProviding`: a read-only screen cannot reach it.
public protocol ConversationProviding: Sendable {
    /// Create a new conversation via `session.create`.
    /// - Returns: the lightweight session (builds the agent in the background).
    func createSession(
        title: String?,
        profile: String?,
        model: String?,
        provider: String?,
        cols: Int?
    ) async throws -> ConversationSession

    /// Resume an existing conversation via `session.resume`.
    /// - Parameter sessionID: the runtime session id to reattach.
    func resumeSession(sessionID: String) async throws -> ConversationSession

    /// Submit a prompt via `prompt.submit` (returns `{"status": "streaming"}`
    /// immediately; the turn's events arrive on `events`).
    func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission

    /// Interrupt a running turn via `session.interrupt`.
    func interrupt(sessionID: String) async throws -> InterruptResult

    /// The stream of conversation events (message/tool/status/thinking/
    /// reasoning + message.complete) for sessions on this gateway.
    var events: AsyncStream<ConversationEvent> { get }
}

/// Errors thrown by the conversation path (self-contained to the seam).
public enum ConversationError: Error, Sendable, Equatable, LocalizedError {
    /// The transport is not connected to the gateway.
    case notConnected
    /// The gateway returned a malformed conversation payload.
    case malformedPayload(String)
    /// The gateway rejected the conversation RPC (method/transport error).
    case rpcFailed(String)
    /// The gateway reported the session does not exist / is not resumable.
    case sessionNotFound(String)
    /// The gateway rejected the request params (e.g. `session_id` required).
    case invalidRequest(String)
    /// The session key or profile is not a safe routing key (path traversal,
    /// separators) — fail closed before any RPC is sent (M9).
    case invalidSessionKey(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "gateway not connected"
        case .malformedPayload(let s): return "malformed conversation payload: \(s)"
        case .rpcFailed(let s): return "conversation RPC failed: \(s)"
        case .sessionNotFound(let s): return "session not found: \(s)"
        case .invalidRequest(let s): return "invalid conversation request: \(s)"
        case .invalidSessionKey(let s): return "invalid session key: \(s)"
        }
    }
}
