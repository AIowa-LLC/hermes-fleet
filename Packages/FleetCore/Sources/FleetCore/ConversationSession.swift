import Foundation

/// The result of `session.create` / `session.resume`.
///
/// Wire shape (verified in `tui_gateway/methods_session.py`): both handlers
/// return `{session_id, stored_session_id, message_count, messages: [...],
/// info: {...}}`. `session_id` is the UI/runtime id (8-hex), `stored_session_id`
/// is the persisted row key; `messages` follow the same `_history_to_messages`
/// projection as `session.history` (reuses `SessionMessage`).
public struct ConversationSession: Hashable, Sendable {
    /// The runtime session id (8-hex) the client sends on later RPCs.
    public let sessionID: String
    /// The persisted row key when the gateway exposes one.
    public let storedSessionID: String?
    /// The gateway-reported message count.
    public let messageCount: Int
    /// Seed/current messages in transcript order (may be empty for a fresh
    /// `session.create`, or suppressed by `omit_messages` on resume).
    public let messages: [SessionMessage]
    /// Best-effort fields from `info.model` / `info.provider`.
    public let model: String?
    public let provider: String?
    /// Best-effort `info.profile_name` (the owning profile).
    public let profileName: String?

    public init(
        sessionID: String,
        storedSessionID: String? = nil,
        messageCount: Int = 0,
        messages: [SessionMessage] = [],
        model: String? = nil,
        provider: String? = nil,
        profileName: String? = nil
    ) {
        self.sessionID = sessionID
        self.storedSessionID = storedSessionID
        self.messageCount = messageCount
        self.messages = messages
        self.model = model
        self.provider = provider
        self.profileName = profileName
    }
}
