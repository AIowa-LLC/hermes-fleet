import Foundation

/// The session READ path seam: read-only session inspection that keeps SwiftUI
/// free of JSON-RPC / WebSocket plumbing (mirrors `RosterProviding` / M0 guard).
///
/// M4 scope (spec §31 Sessions + §5.4): `session.list` (via `RosterProviding`),
/// `session.history` and `session.status` — OBSERVATION ONLY. This protocol
/// deliberately exposes NO mutating operation: no create, resume, interrupt,
/// close, delete, undo, or prompt submission. A screen that renders session
/// history or status through this seam structurally cannot seize or mutate the
/// session's transport (spec §5.4 "Observation Must Not Imply Ownership";
/// spec §36 session-safety tests "read-only screens do not accidentally issue
/// mutating calls").
public protocol SessionHistoryProviding: Sendable {
    /// Fetch a session's message history via the read-only `session.history`.
    /// - Parameter sessionID: the session to read.
    func fetchSessionHistory(sessionID: String) async throws -> SessionHistory

    /// Fetch a session's status snapshot via the read-only `session.status`.
    /// - Parameter sessionID: the session to read.
    func fetchSessionStatus(sessionID: String) async throws -> SessionStatus
}

/// Errors thrown by the session read path (defined here so the seam stays
/// self-contained).
public enum SessionHistoryError: Error, Sendable, Equatable, LocalizedError {
    /// The transport is not connected to the gateway.
    case notConnected
    /// The gateway returned a malformed history/status payload.
    case malformedPayload(String)
    /// The gateway rejected the read (e.g. method error, transport error).
    case rpcFailed(String)
    /// The gateway reported the session does not exist / is not readable.
    case sessionNotFound(String)
    /// The session key is not a safe routing key (path traversal, separators)
    /// — fail closed before any RPC is sent (M9).
    case invalidSessionKey(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "gateway not connected"
        case .malformedPayload(let s): return "malformed session payload: \(s)"
        case .rpcFailed(let s): return "session read RPC failed: \(s)"
        case .sessionNotFound(let s): return "session not found: \(s)"
        case .invalidSessionKey(let s): return "invalid session key: \(s)"
        }
    }
}
