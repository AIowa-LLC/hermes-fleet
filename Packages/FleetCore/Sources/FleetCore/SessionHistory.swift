import Foundation

/// A session's message history as returned by the read-only `session.history`
/// method.
///
/// Wire shape (verified in `tui_gateway/methods_session.py:2778-2807`):
/// `{"count": N, "messages": [ ... ]}` where each message follows the
/// `_history_to_messages` projection (`server.py:9296`).
///
/// This type is part of the M4 session READ path only. It carries no mutating
/// operations — per spec §5.4, reading history must never activate, resume,
/// mutate, or seize the session's live transport.
public struct SessionHistory: Hashable, Sendable {
    /// The session this history belongs to (echoed from the caller's request).
    public let sessionID: String
    /// The gateway's reported message count.
    public let count: Int
    /// Messages in transcript order (chronological).
    public let messages: [SessionMessage]

    public init(sessionID: String, count: Int, messages: [SessionMessage]) {
        self.sessionID = sessionID
        self.count = count
        self.messages = messages
    }

    public var isEmpty: Bool { messages.isEmpty }
}
