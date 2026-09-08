import Foundation

/// A session row as reported by `session.list` (and nested in
/// `profiles.list` → `last_session` / `canonical_session`).
///
/// Wire shape (verified in `tui_gateway/methods_session.py`, `session.list`,
/// and `methods_profiles.py` `last_session`): `{id, title, preview,
/// started_at, last_active, message_count, source}`. `started_at` is an
/// epoch timestamp; `last_active` (epoch seconds) is the server's
/// last-activity stamp, present on modern gateways and ABSENT on older ones
/// — 0 means unknown, never "never active". `source` is a platform/surface
/// label.
public struct SessionSummary: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let preview: String
    /// Epoch seconds at session creation.
    public let startedAt: Double
    /// Epoch seconds of the server's last-activity stamp, 0 when the source
    /// did not supply one (FOS-5 §10: preserved through decoding now so a
    /// later ranking upgrade can use it — current sort semantics stay
    /// `startedAt`-based and are unchanged by this field).
    public let lastActive: Double
    public let messageCount: Int
    public let source: String?

    public init(
        id: String,
        title: String,
        preview: String = "",
        startedAt: Double = 0,
        lastActive: Double = 0,
        messageCount: Int = 0,
        source: String? = nil
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.startedAt = startedAt
        self.lastActive = lastActive
        self.messageCount = messageCount
        self.source = source
    }
}
