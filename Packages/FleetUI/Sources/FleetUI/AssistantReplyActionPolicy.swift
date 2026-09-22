import Foundation

/// Pure availability rules for actions attached to an assistant reply.
///
/// The gateway's branch contract accepts a prefix count, while `/retry` can
/// safely reconstruct only the latest completed user turn. Keeping those
/// rules independent of SwiftUI makes the toolbar fail closed and keeps the
/// unit tests about conversation invariants rather than view structure.
public enum AssistantReplyActionPolicy {
    /// Number of visible user/assistant rows through the selected assistant
    /// reply, suitable for `session.branch { count }`.
    public static func branchMessageCount(
        rows: [ConversationRow],
        selectedRowID: String
    ) -> Int? {
        guard let selectedIndex = rows.firstIndex(where: { $0.id == selectedRowID }),
              rows[selectedIndex].kind == .assistant,
              !rows[selectedIndex].isStreaming,
              !rows[selectedIndex].isFailed else { return nil }

        let prefix = rows.prefix(through: selectedIndex)
        let visibleCount = prefix.reduce(into: 0) { count, row in
            let isVisibleRole = row.kind == .user || row.kind == .assistant
            if isVisibleRole && !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        return visibleCount > 0 ? visibleCount : nil
    }

    /// `/retry` is a latest-turn operation. It is safe only for the final
    /// completed assistant reply and never while another turn is active.
    public static func canRetry(
        rows: [ConversationRow],
        selectedRowID: String,
        isStreaming: Bool
    ) -> Bool {
        guard !isStreaming,
              let selectedIndex = rows.firstIndex(where: { $0.id == selectedRowID }),
              rows[selectedIndex].kind == .assistant,
              !rows[selectedIndex].isStreaming,
              !rows[selectedIndex].isFailed,
              rows[..<selectedIndex].contains(where: { $0.kind == .user }) else { return false }

        // Tool/status rows may trail the assistant projection, but another
        // user/assistant row means this is not the latest regenerable turn.
        return !rows.dropFirst(selectedIndex + 1).contains {
            $0.kind == .user || $0.kind == .assistant
        }
    }
}
