import Foundation

/// A session row as reported by `session.list` (and nested in
/// `profiles.list` → `last_session` / `canonical_session`).
///
/// Wire shape (verified in `tui_gateway/methods_session.py`, `session.list`):
/// `{id, title, preview, started_at, message_count, source}`. `started_at` is
/// an epoch timestamp; `source` is a platform/surface label.
public struct SessionSummary: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let preview: String
    /// Epoch seconds at session creation.
    public let startedAt: Double
    public let messageCount: Int
    public let source: String?

    public init(
        id: String,
        title: String,
        preview: String = "",
        startedAt: Double = 0,
        messageCount: Int = 0,
        source: String? = nil
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.startedAt = startedAt
        self.messageCount = messageCount
        self.source = source
    }
}
