import Foundation

/// P0-B (RC-84) — pure policy for "Find in Conversation": matching,
/// snippet shaping, wrap-around navigation, and the status line.
///
/// The policy searches the LOADED (bounded) transcript the view model
/// exposes — the same rows the user can see or scroll back to. It never
/// mutates conversation state and never talks to the gateway: find is a
/// reader over already-available history, not a server-side search.
public enum ConversationFindPolicy {

    /// One navigation stop: the row that matched and a one-line snippet
    /// around the occurrence (for the "n of m" context line).
    public struct Match: Equatable, Sendable {
        public let rowID: String
        public let snippet: String

        public init(rowID: String, snippet: String) {
            self.rowID = rowID
            self.snippet = snippet
        }
    }

    /// Rows that carry searchable conversation content: user and assistant
    /// turns. Tool payloads, status lines, system notes, and error chrome
    /// are machinery, not conversation content — their raw dumps are not
    /// what a reader scanning for a phrase means, so they never produce
    /// matches. Failed rows stay INCLUDED (the text is what the user typed
    /// or the model said, regardless of the turn's terminal state).
    public static func isSearchable(_ row: ConversationRow) -> Bool {
        switch row.kind {
        case .user, .assistant: return true
        case .tool, .status, .system, .error: return false
        }
    }

    /// Case/diacritic-insensitive matches over the loaded transcript, in
    /// transcript order, ONE match per row (the first occurrence) — every
    /// stop is a row the transcript can scroll to.
    public static func matches(rows: [ConversationRow], query: String) -> [Match] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var out: [Match] = []
        for row in rows where isSearchable(row) {
            let text = row.text
            guard !text.isEmpty else { continue }
            guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            out.append(Match(rowID: row.id, snippet: snippet(in: text, around: range)))
        }
        return out
    }

    /// A ~34-character context window on both sides of the match, collapsed
    /// to one line (newlines become spaces) and ellipsised on each cut side
    /// so the excerpt never reads as the full message.
    public static func snippet(in text: String, around range: Range<String.Index>, context: Int = 34) -> String {
        let start = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end])
        snippet = snippet.replacingOccurrences(of: "\n", with: " ")
        if start != text.startIndex { snippet = "…" + snippet }
        if end != text.endIndex { snippet = snippet + "…" }
        return snippet
    }

    /// Wrap-around navigation over `count` matches; a zero count stays at 0.
    public static func nextIndex(current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (current + 1) % count
    }

    public static func previousIndex(current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (current - 1 + count) % count
    }

    /// The find bar's position text: "n of m". An empty string is returned
    /// when there are no matches (the caller renders the explicit
    /// no-results copy instead — never "0 of 0").
    public static func positionText(index: Int, count: Int) -> String {
        guard count > 0 else { return "" }
        let clamped = min(max(index, 0), count - 1)
        return "\(clamped + 1) of \(count)"
    }
}