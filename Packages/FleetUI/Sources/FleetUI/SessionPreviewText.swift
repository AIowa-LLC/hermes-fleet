import Foundation

/// Chat-list polish (dogfood finding 2) — a PRESENTATION-ONLY, human-readable
/// rendering of a session preview.
///
/// The gateway stores the user's message verbatim, so a `SessionSummary.preview`
/// can carry the client's own attachment/control markup and the user's machine
/// topology:
/// - a collapsed large paste, stored as
///   `[Pasted text #N: K lines → /path/to/pastes/paste_N.txt]`;
/// - lower-case `@file:` / `@folder:` attachment refs (`@file:attachments/notes.md`,
///   `@file: `.hermes/attachments/Pasted content (12.3 KB)``, `@file:`C:\…\report.txt``);
/// - a bare internal path (`.hermes/attachments/…`, `.hermes/pastes/…`,
///   `desktop-attachments/…`).
///
/// None of that is prose, and the paths are the user's machine topology. This
/// derives a row's display line from the stored string WITHOUT mutating
/// `SessionSummary` or the stored payload: counters and referenced names
/// survive, the markup and every internal path do not.
///
/// Behavior contract (pinned by `SessionPreviewTextTests`):
/// - ordinary text passes through untouched (byte-for-byte when nothing is
///   rewritten);
/// - `@url:` / `@diff` / upper-cased `@File:` are NOT path markup — verbatim;
/// - a malformed or empty ref is dropped entirely (never rendered as the raw
///   control vocabulary);
/// - several refs, quoted values, and trailing text all render correctly;
/// - every step is fail-safe: an unrecognised shape is left alone, never
///   guessed at and never crashed on.
public enum SessionPreviewText {

    /// The human-readable preview line for a session row.
    public static func humanReadable(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let collapsed = collapsePastePlaceholders(Array(raw))
        let referenced = rewriteControlRefs(Array(collapsed))
        let shortened = shortenInternalPaths(Array(referenced))
        let rendered = String(shortened)
        // Conservative: when nothing was rewritten the stored string is
        // returned untouched (whitespace included).
        guard rendered != raw else { return raw }
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pasted-content control markup

    private static let pasteMarker = Array("[Pasted text #")

    /// `[Pasted text #N: K lines → <file>]` → `Pasted text #N · K lines`.
    ///
    /// The file region is dropped whether or not it is closed by `]`, so an
    /// unterminated placeholder (the malformed case) still cannot leak a path.
    private static func collapsePastePlaceholders(_ chars: [Character]) -> String {
        var out = ""
        var index = 0
        while index < chars.count {
            guard matches(chars, at: index, pasteMarker) else {
                out.append(chars[index]); index += 1; continue
            }
            let headStart = index + pasteMarker.count
            var cursor = headStart
            var arrow: Int?
            while cursor < chars.count {
                if chars[cursor] == "→" { arrow = cursor; break }
                if chars[cursor] == "]" { break }
                cursor += 1
            }
            let headEnd = arrow ?? cursor
            out += pasteLabel(chars[headStart..<headEnd])

            if let arrow {
                var tail = arrow + 1
                while tail < chars.count, chars[tail] != "]" { tail += 1 }
                index = tail < chars.count ? tail + 1 : chars.count
            } else if cursor < chars.count {
                index = cursor + 1
            } else {
                index = chars.count
            }
        }
        return out
    }

    /// `N: K lines ` → `Pasted text #N · K lines` (the counters), never the file.
    private static func pasteLabel(_ head: ArraySlice<Character>) -> String {
        let text = String(head).trimmingCharacters(in: .whitespaces)
        let number = leadingDigits(text)
        let lines = lineCount(text)
        if let number, let lines {
            return "Pasted text #\(number) · \(lines) line\(lines == "1" ? "" : "s")"
        }
        if let number { return "Pasted text #\(number)" }
        return "Pasted content"
    }

    private static func leadingDigits(_ text: String) -> String? {
        let digits = text.prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : String(digits)
    }

    /// The count that precedes the word `line`/`lines`, e.g. `120` in
    /// `1: 120 lines`.
    private static func lineCount(_ text: String) -> String? {
        let chars = Array(text)
        guard let lineStart = firstIndex(of: "line", in: chars) else { return nil }
        var end = lineStart
        while end > 0, chars[end - 1].isWhitespace { end -= 1 }
        var start = end
        while start > 0, chars[start - 1].isNumber { start -= 1 }
        let digits = String(chars[start..<end])
        return digits.isEmpty ? nil : digits
    }

    // MARK: - `@file:` / `@folder:` control references

    /// Characters that end an UNQUOTED reference value. Whitespace is the
    /// common case; brackets/commas keep a ref embedded in a sentence readable.
    private static let valueTerminators: Set<Character> = [")", "]", ",", ";"]

    /// Rewrite each lower-case `@file:`/`@folder:` ref to the referenced name.
    /// A ref with no value is removed entirely. Unknown kinds (and any
    /// upper-cased spelling) are ordinary text and stay verbatim.
    private static func rewriteControlRefs(_ chars: [Character]) -> String {
        var out = ""
        var index = 0
        while index < chars.count {
            guard chars[index] == "@" else {
                out.append(chars[index]); index += 1; continue
            }
            var cursor = index + 1
            while cursor < chars.count, chars[cursor].isLetter { cursor += 1 }
            let kind = String(chars[(index + 1)..<cursor])
            guard (kind == "file" || kind == "folder"),
                  cursor < chars.count, chars[cursor] == ":" else {
                out.append(chars[index]); index += 1; continue
            }
            cursor += 1
            while cursor < chars.count, chars[cursor].isWhitespace { cursor += 1 }

            var value = ""
            if cursor < chars.count, let quote = quoteCharacter(chars[cursor]) {
                cursor += 1
                while cursor < chars.count, chars[cursor] != quote {
                    value.append(chars[cursor]); cursor += 1
                }
                if cursor < chars.count { cursor += 1 } // closing quote
            } else {
                while cursor < chars.count {
                    let character = chars[cursor]
                    if character.isWhitespace || valueTerminators.contains(character) { break }
                    value.append(character); cursor += 1
                }
            }
            // A malformed/empty ref is dropped (its whitespace already
            // consumed), never rendered as raw control vocabulary.
            let name = lastPathComponent(of: value)
            if !name.isEmpty { out += name }
            index = cursor
        }
        return out
    }

    // MARK: - Bare internal paths

    /// Internal storage markers: a path-like token carrying one is machine
    /// topology and renders as its file name only.
    private static let internalMarkers = [
        ".hermes/", "/attachments/", "/pastes/", "desktop-attachments/",
    ]

    /// Relative markers that form a path with no `/`, `~/`, `.hermes/` or
    /// drive-letter lead-in, so `isPathStart` must recognise the marker itself.
    private static let relativeInternalMarkers: [[Character]] = [
        Array(".hermes/"), Array("desktop-attachments/"),
    ]

    private static func shortenInternalPaths(_ chars: [Character]) -> String {
        var out = ""
        var index = 0
        while index < chars.count {
            guard isPathStart(chars, at: index) else {
                out.append(chars[index]); index += 1; continue
            }
            var cursor = index
            while cursor < chars.count, !isPathTerminator(chars[cursor]) { cursor += 1 }
            let token = String(chars[index..<cursor])
            if internalMarkers.contains(where: token.contains) {
                let name = lastPathComponent(of: token)
                out += name.isEmpty ? token : name
            } else {
                out += token
            }
            index = cursor
        }
        return out
    }

    /// `/`, `~/`, a `C:\`-style drive start, or an internal relative marker —
    /// but never a `/` inside a word (`reconnect/replay`) or a URL
    /// (`https://`). A quote or backtick opens a quoted span, so it is a token
    /// boundary too.
    private static func isPathStart(_ chars: [Character], at index: Int) -> Bool {
        guard index < chars.count else { return false }
        let boundary = index == 0 || {
            let previous = chars[index - 1]
            return previous.isWhitespace || previous == "(" || previous == "["
                || previous == "\"" || previous == "'" || previous == "`"
        }()
        guard boundary else { return false }
        if relativeInternalMarkers.contains(where: { matches(chars, at: index, $0) }) {
            return true
        }
        if chars[index] == "/" { return true }
        if chars[index] == "~", index + 1 < chars.count, chars[index + 1] == "/" { return true }
        if chars[index].isLetter, index + 2 < chars.count,
           chars[index + 1] == ":", chars[index + 2] == "\\" {
            return true
        }
        return false
    }

    private static func isPathTerminator(_ character: Character) -> Bool {
        character.isWhitespace || character == ")" || character == "]"
            || character == "\"" || character == "'" || character == "`"
            || character == "," || character == ";"
    }

    // MARK: - Shared helpers

    private static func quoteCharacter(_ character: Character) -> Character? {
        character == "`" || character == "\"" || character == "'" ? character : nil
    }

    /// The referenced file name: the last path component, with POSIX and
    /// Windows separators handled and trailing separators dropped.
    private static func lastPathComponent(of value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let components = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return components.last.map(String.init) ?? trimmed
    }

    private static func matches(_ chars: [Character], at index: Int, _ marker: [Character]) -> Bool {
        guard index + marker.count <= chars.count else { return false }
        for offset in 0..<marker.count where chars[index + offset] != marker[offset] {
            return false
        }
        return true
    }

    private static func firstIndex(of needle: String, in chars: [Character]) -> Int? {
        let pattern = Array(needle)
        guard !pattern.isEmpty, chars.count >= pattern.count else { return nil }
        for start in 0...(chars.count - pattern.count) where matches(chars, at: start, pattern) {
            return start
        }
        return nil
    }
}