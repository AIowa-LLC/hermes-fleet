import Foundation

// Issue #109 (D6): pure, UI-free logic behind the assistant code-block chrome.
//
// The pinned SwiftStreamingMarkdown renderer draws its own code card (an
// always-present language `Text`, a tap-gesture "Copy" text with no haptic,
// `UIPasteboard.general.string` with no expiry, a fixed `.xcode` theme). It
// exposes no hook to replace that view, so Fleet splits top-level fences out
// of the Markdown projection and draws them itself (`FleetCodeBlockView`).
// Everything decidable without a view lives here so it can be unit tested.

// MARK: - Fence info string

/// Parsed view of a fenced code block's info string.
enum CodeFenceInfo {
    /// The language token to *show*, taken verbatim from the fence info
    /// string, or `nil` when the fence declares none. Never guessed from the
    /// code: an unlabeled fence shows no label at all.
    ///
    /// The first whitespace-delimited token is the language; the rest is
    /// author metadata (`python title=x`). Pandoc-style `{.python ...}`
    /// wrappers are unwrapped. A first token that is a `key=value` attribute,
    /// or that contains anything other than identifier-ish characters, is
    /// treated as "no language" instead of being rendered as a label.
    static func languageLabel(from info: String) -> String? {
        var token = info
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init) ?? ""
        while token.hasPrefix("{") || token.hasPrefix(".") { token.removeFirst() }
        while token.hasSuffix("}") || token.hasSuffix(",") { token.removeLast() }
        guard !token.isEmpty, token.count <= maxLabelLength else { return nil }
        guard token.unicodeScalars.allSatisfy(Self.allowedLabelScalars.contains) else { return nil }
        return token
    }

    /// The lowercase alias handed to the highlighter for a declared language.
    static func highlightAlias(from info: String) -> String? {
        languageLabel(from: info)?.lowercased()
    }

    static let maxLabelLength = 32

    private static let allowedLabelScalars: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "+#-_./")
        return set
    }()
}

// MARK: - Markdown segmentation

/// A top-level fenced code block lifted out of an assistant Markdown snapshot.
struct CodeFence: Equatable {
    /// Raw info string (`swift`, `python title=x`, ``). Empty while the
    /// opening line is still being streamed, so a half-typed `swi` never
    /// flashes as a label.
    let info: String
    /// Code between the fences, without the fence lines or the final newline.
    let body: String
    /// False while the closing fence has not arrived (streaming, or a model
    /// that never closes its fence).
    let isClosed: Bool
}

enum AssistantMarkdownSegment: Equatable {
    case prose(String)
    case code(CodeFence)
}

/// Splits Markdown into prose runs and top-level fenced code blocks.
///
/// Only fences that start in column 0 are lifted out. A column-0 fence can
/// never belong to a list item or block quote (both would put marker or
/// indentation in front of it), so the split cannot change the structure of
/// surrounding prose. Indented fences stay inside prose and keep rendering
/// through the third-party card, restyled by `CodeBlockAppearance`.
enum AssistantMarkdownSegmenter {
    static func split(_ markdown: String) -> [AssistantMarkdownSegment] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var segments: [AssistantMarkdownSegment] = []
        var prose: [Substring] = []
        var index = 0

        func flushProse() {
            let text = prose.joined(separator: "\n")
            prose.removeAll(keepingCapacity: true)
            if !text.allSatisfy(\.isWhitespace) {
                segments.append(.prose(text))
            }
        }

        while index < lines.count {
            let line = lines[index]
            guard let open = openingFence(line) else {
                prose.append(line)
                index += 1
                continue
            }

            flushProse()
            // The opening line has not been terminated yet: the info string
            // may still be growing.
            let isLastLine = index == lines.count - 1
            var body: [Substring] = []
            var isClosed = false
            var cursor = index + 1
            while cursor < lines.count {
                if isClosingFence(lines[cursor], matching: open) {
                    isClosed = true
                    break
                }
                body.append(lines[cursor])
                cursor += 1
            }
            segments.append(.code(CodeFence(
                info: isLastLine ? "" : open.info,
                body: body.map(stripCarriageReturn).joined(separator: "\n"),
                isClosed: isClosed)))
            index = isClosed ? cursor + 1 : cursor
        }
        flushProse()
        return segments
    }

    private struct Opening {
        let marker: Character
        let count: Int
        let info: String
    }

    private static func openingFence(_ line: Substring) -> Opening? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let run = line.prefix(while: { $0 == marker })
        guard run.count >= 3 else { return nil }
        let info = String(line.dropFirst(run.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // CommonMark: a backtick fence's info string cannot contain a
        // backtick (that is an inline code span such as ```code```).
        if marker == "`", info.contains("`") { return nil }
        return Opening(marker: marker, count: run.count, info: info)
    }

    private static func isClosingFence(_ line: Substring, matching open: Opening) -> Bool {
        let stripped = line.drop(while: { $0 == " " })
        guard line.count - stripped.count <= 3 else { return false }
        let run = stripped.prefix(while: { $0 == open.marker })
        guard run.count >= open.count else { return false }
        return stripped.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    private static func stripCarriageReturn(_ line: Substring) -> Substring {
        line.hasSuffix("\r") ? line.dropLast() : line
    }
}

// MARK: - Overflow fades

/// Which edges of the horizontally scrolling code line should fade out.
struct CodeBlockEdgeFades: Equatable {
    var leading: Bool
    var trailing: Bool

    static let none = CodeBlockEdgeFades(leading: false, trailing: false)

    /// Fades appear only while content overflows the viewport, on the side
    /// that still has hidden content. `tolerance` absorbs sub-point rounding
    /// so a block that exactly fits never shows a fade.
    static func resolve(
        contentWidth: Double,
        viewportWidth: Double,
        offset: Double,
        tolerance: Double = 1
    ) -> CodeBlockEdgeFades {
        guard viewportWidth > 0, contentWidth > viewportWidth + tolerance else { return .none }
        let maxOffset = contentWidth - viewportWidth
        return CodeBlockEdgeFades(
            leading: offset > tolerance,
            trailing: offset < maxOffset - tolerance)
    }
}

// MARK: - Pasteboard policy

/// How a code-block Copy writes to the general pasteboard.
///
/// Code in assistant replies can carry pasted secrets or private paths, so
/// the copy is device-local and short-lived. This mirrors the operational
/// copy policy of the clipboard-hygiene work (#146); when that shared
/// `FleetPasteboard` helper lands this policy should route through it.
struct CodeBlockPasteboardPolicy: Equatable {
    /// Seconds before the pasteboard entry expires.
    var timeToLive: TimeInterval = 300
    var localOnly = true
}

/// Test seam over `UIPasteboard`. The live implementation is in
/// `FleetCodeBlockView.swift` (UIKit); tests inject a recording fake.
protocol CodeBlockPasteboardWriting {
    func write(_ string: String, policy: CodeBlockPasteboardPolicy, now: Date)
}

enum CodeBlockCopier {
    /// Copies `code` exactly as received and reports whether anything was
    /// written. Empty blocks (a fence that just opened while streaming) are
    /// never copied.
    @discardableResult
    static func copy(
        _ code: String,
        to pasteboard: some CodeBlockPasteboardWriting,
        policy: CodeBlockPasteboardPolicy = CodeBlockPasteboardPolicy(),
        now: Date = Date()
    ) -> Bool {
        guard !code.isEmpty else { return false }
        pasteboard.write(code, policy: policy, now: now)
        return true
    }
}
