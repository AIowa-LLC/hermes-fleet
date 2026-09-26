import Foundation
import FleetCore


/// Stage 1 assistant-reply footer actions — presentation-agnostic policy.
///
/// One pure gate decides whether a completed assistant reply is addressable
/// by the footer toolbar, so the 1:1 conversation (ConversationRow) and the
/// bridged-group transcript (RoomTranscriptEntry) render the SAME rules and
/// can never drift:
/// - only assistant-flavored rows (member replies are assistant content);
/// - only COMPLETED replies (never mid-stream: text still mutating, the
///   footer's copy/share/speak payloads would be lies);
/// - never failed/error placeholders (there is no real reply text to act on);
/// - never empty/whitespace text (nothing to copy, share, or speak —
///   `speakAssistant`'s own guard, lifted to the surface so the footer does
///   not render inert buttons);
/// - Copy/Share share the exact same payload (the row's literal text — the
///   user acts on what they see, never hidden transcript history).
public enum AssistantReplyFooterPolicy {

    /// The payload every footer action operates on (copy, share, read
    /// aloud): the reply's literal rendered text. No history, no metadata.
    public static func actionableText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    /// 1:1 conversation rows: a completed, non-failed assistant row with
    /// actionable text gets the footer.
    public static func showsFooter(kind: ConversationRow.Kind, text: String, isStreaming: Bool, isFailed: Bool) -> Bool {
        guard kind == .assistant, !isStreaming, !isFailed else { return false }
        return actionableText(text) != nil
    }

    /// Bridged-group transcript entries: a member message (assistant
    /// content) with actionable text gets the footer. Failure flavor and
    /// user messages never do.
    public static func showsFooter(roomFlavor: RoomTranscriptEntry.Flavor, text: String?) -> Bool {
        guard case .message(let isUser) = roomFlavor, !isUser else { return false }
        return actionableText(text) != nil
    }
}
