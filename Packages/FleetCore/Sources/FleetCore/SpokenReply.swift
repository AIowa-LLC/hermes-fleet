import Foundation

// Spoken-reply text preparation for voice mode.
//
// Voice mode must speak whole sentences and must never read markdown symbols
// aloud ("pound pound", "asterisk", backtick fences). These two pure value
// types sit between the streamed assistant reply and the speech synthesizer:
// `SentenceChunker` cuts the incoming deltas into speakable segments, and
// `SpokenText.plain(fromMarkdown:)` turns each raw segment into plain prose.
// FleetUI uses them; no AVFoundation or Speech is imported here (the concrete
// synthesizer is injected through `VoiceTranscribing` in FleetCore).

/// Converts an assistant's markdown reply into text a speech synthesizer can
/// read naturally. Pure Foundation string handling, no state.
public enum SpokenText {

    /// Returns the speakable plain-text form of a markdown reply.
    ///
    /// - Fenced code blocks (``` or ~~~, closed or unclosed) are removed.
    /// - Inline code keeps its content; images and links keep their text;
    ///   bare http(s) URLs are dropped.
    /// - Heading, blockquote and list markers are removed. Headings and list
    ///   items are read as separate phrases.
    /// - Emphasis markers (`**`, `__`, `~~`, and word-wrapping `*` or `_`) are
    ///   removed. Underscores inside words (snake_case_name) are kept.
    /// - Table separator rows and horizontal rules are dropped; other table
    ///   rows read their cells separated by ", ".
    /// - Whitespace runs collapse to single spaces.
    public static func plain(fromMarkdown markdown: String) -> String {
        var pieces: [Piece] = []
        var inFence = false
        var breakPending = false

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                breakPending = true
                continue
            }
            if inFence { continue }

            var text = trimmed
            while text.hasPrefix(">") {
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if text.isEmpty {
                breakPending = true
                continue
            }
            if isRuleLine(text) {
                breakPending = true
                continue
            }

            var isItem = false
            if let rest = stripPrefix(text, #"^#{1,6}\s+"#) {
                text = rest
                isItem = true
            } else if let rest = stripPrefix(text, #"^(?:[-*+]|\d+[.)])\s+"#) {
                text = rest
                isItem = true
            }
            if text.contains("|") {
                text = tableRowText(text)
                isItem = true
            }

            let spoken = inline(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !spoken.isEmpty {
                pieces.append(Piece(text: spoken, isItem: isItem, breakBefore: breakPending))
                breakPending = false
            }
        }

        var result = ""
        var previous: Piece?
        for piece in pieces {
            if let prior = previous {
                let separator: String
                if endsWithPunctuation(prior.text) {
                    separator = " "
                } else if piece.breakBefore || prior.isItem || piece.isItem {
                    separator = ". "
                } else {
                    separator = " "
                }
                result += separator + piece.text
            } else {
                result = piece.text
            }
            previous = piece
        }

        return result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // MARK: - Private helpers

    private struct Piece {
        let text: String
        /// Heading, list item or table row: read as its own phrase.
        let isItem: Bool
        /// A blank line, fence or rule came just before this piece.
        let breakBefore: Bool
    }

    /// Separator rows (only `|`, `-`, `:`, spaces) and horizontal rules
    /// (three or more `-`, `*` or `_`).
    private static func isRuleLine(_ line: String) -> Bool {
        let chars = line.filter { !$0.isWhitespace }
        guard let first = chars.first else { return false }
        if chars.allSatisfy({ "|-:".contains($0) }) {
            return true
        }
        if chars.count >= 3, "*_-".contains(first), chars.allSatisfy({ $0 == first }) {
            return true
        }
        return false
    }

    /// `| a | b |` becomes `a, b`.
    private static func tableRowText(_ line: String) -> String {
        line.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private static func endsWithPunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?:;,…".contains(last)
    }

    /// Inline markdown to plain text. Order matters: images before links,
    /// links before bare URLs, double emphasis before single.
    private static func inline(_ input: String) -> String {
        var s = input
        s = replacing(s, #"!\[([^\]]*)\]\([^)]*\)"#, "$1")
        s = replacing(s, #"\[([^\]]*)\]\([^)]*\)"#, "$1")
        s = replacing(s, #"`([^`]*)`"#, "$1")
        s = replacing(s, #"https?://\S+"#, "")
        s = replacing(s, #"\*\*"#, "")
        s = replacing(s, #"~~"#, "")
        s = replacing(s, #"(?<!\w)__|__(?!\w)"#, "")
        s = replacing(s, #"\*(?=\S)([^*]*?\S)\*"#, "$1")
        s = replacing(s, #"(?<!\w)_(?=\S)([^_]*?\S)_(?!\w)"#, "$1")
        return s
    }

    private static func replacing(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// If `pattern` matches at the start of `text`, returns the rest of the
    /// text after the match; otherwise nil.
    private static func stripPrefix(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matched = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matched.upperBound...])
    }
}

/// Splits streamed assistant text into whole speakable segments, so voice
/// mode speaks sentences rather than fragments.
///
/// A segment ends at a run of `.`, `!`, `?` or `…` that is immediately
/// followed by whitespace, or at a newline once the text before it is
/// non-empty. Nothing is cut inside a code fence: the fence is held until it
/// closes and then goes out with the text that follows it. Returned segments
/// are raw (markdown not yet removed); pass them through
/// `SpokenText.plain(fromMarkdown:)` before speaking.
public struct SentenceChunker: Sendable {

    private var buffer: String = ""

    public init() {}

    /// Appends streamed text and returns the complete segments it finished,
    /// removing them from the buffer. Whitespace-only segments are dropped.
    public mutating func append(_ delta: String) -> [String] {
        buffer += delta
        var segments: [String] = []
        while let cut = nextCut() {
            let segment = buffer[buffer.startIndex..<cut.end].trimmedForSpeech
            if !segment.isEmpty {
                segments.append(segment)
            }
            buffer = String(buffer[cut.resume...])
        }
        return segments
    }

    /// Returns whatever is left in the buffer (trimmed), or nil when nothing
    /// non-whitespace remains. Clears the buffer.
    public mutating func flush() -> String? {
        let rest = buffer.trimmedForSpeech
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    /// Discards the buffer.
    public mutating func reset() {
        buffer = ""
    }

    /// True while the buffer holds non-whitespace text.
    public var hasPendingText: Bool {
        buffer.contains { !$0.isWhitespace }
    }

    // MARK: - Private

    /// The first complete segment in the buffer: `end` is where the segment's
    /// text stops, `resume` is where the remaining buffer starts.
    private func nextCut() -> (end: String.Index, resume: String.Index)? {
        var inFence = false
        var atLineStart = true
        var i = buffer.startIndex

        while i < buffer.endIndex {
            if atLineStart {
                atLineStart = false
                if SentenceChunker.isFenceLine(buffer[i...]) {
                    inFence.toggle()
                }
            }

            let c = buffer[i]

            if c == "\n" {
                if !inFence && buffer[buffer.startIndex..<i].contains(where: { !$0.isWhitespace }) {
                    return (end: i, resume: buffer.index(after: i))
                }
                atLineStart = true
                i = buffer.index(after: i)
                continue
            }

            if !inFence && SentenceChunker.isSentenceEnder(c) {
                var j = i
                while j < buffer.endIndex && SentenceChunker.isSentenceEnder(buffer[j]) {
                    j = buffer.index(after: j)
                }
                if j < buffer.endIndex && buffer[j].isWhitespace {
                    return (end: j, resume: j)
                }
                i = j
                continue
            }

            i = buffer.index(after: i)
        }
        return nil
    }

    private static func isSentenceEnder(_ c: Character) -> Bool {
        ".!?…".contains(c)
    }

    private static func isFenceLine(_ line: Substring) -> Bool {
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        return body.hasPrefix("```") || body.hasPrefix("~~~")
    }
}

private extension StringProtocol {
    var trimmedForSpeech: String {
        String(self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
