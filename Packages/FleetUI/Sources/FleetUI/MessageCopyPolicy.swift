import Foundation

/// Shared "Copy Message" payload rule for transcript rows.
///
/// The 1:1 conversation (ConversationBubbleView) and the group transcript
/// (RoomChatView) offer the same long-press Copy Message action. Both copy the
/// row's literal text — Markdown, interior whitespace, and all — and never
/// hidden scaffolding (speaker labels, timestamps, tool payloads). A row with
/// no visible text offers no copy action at all.
public enum MessageCopyPolicy {

    /// The exact string to place on the pasteboard, or nil when the row has
    /// no visible text (nothing to copy, so the menu item is not offered).
    public static func copyPayload(text: String?) -> String? {
        guard let text else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
