import Combine
import Foundation
import SwiftUI
import SwiftStreamingMarkdown
import FleetCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Fleet-owned presentation boundary for Hermes assistant Markdown.
///
/// The raw Markdown string remains the durable/wire value. This view only
/// creates a disposable rendering projection and deliberately keeps the
/// third-party renderer out of the rest of FleetUI. Streaming rows feed full,
/// progressively larger snapshots into one stable source keyed by the row's
/// identity; SwiftUI body recomputation never creates a parser per delta.
public struct AssistantRichTextView: View {
    private let markdown: String
    private let isStreaming: Bool
    private let identity: String
    @StateObject private var model: AssistantRichTextModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(markdown: String, isStreaming: Bool, identity: String) {
        self.markdown = markdown
        self.isStreaming = isStreaming
        self.identity = identity
        _model = StateObject(
            wrappedValue: AssistantRichTextModel(
                identity: identity,
                markdown: markdown,
                isStreaming: isStreaming))
    }

    public var body: some View {
        StreamedMarkdownView(
            source: model.source,
            config: FleetMarkdownRenderConfiguration.make(
                reduceMotion: reduceMotion,
                dynamicTypeSize: dynamicTypeSize))
        // A row identity is stable for a message. If SwiftUI ever reuses this
        // view for a different row, the renderer controller is replaced only
        // at that identity boundary, never for an ordinary text snapshot.
        .id(model.renderIdentity)
        .frame(maxWidth: .infinity, alignment: .leading)
        // SwiftStreamingMarkdown routes link activation through openURL. The
        // policy is an explicit-action gate and rejects every non-HTTPS URL.
        .environment(\.openURL, OpenURLAction { url in
            AssistantRichTextURLPolicy.open(url)
        })
        // Fleet intentionally disables token/reveal animation. This avoids
        // streaming flicker and makes Reduce Motion a hard no-animation path.
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityIdentifier("fleet.rich-text.\(identity)")
        .task {
            model.update(markdown: markdown, isStreaming: isStreaming)
        }
        .onChange(of: markdown) { _, value in
            model.update(markdown: value, isStreaming: isStreaming)
        }
        .onChange(of: isStreaming) { _, value in
            model.update(markdown: markdown, isStreaming: value)
        }
        .onChange(of: identity) { _, value in
            model.replaceIdentity(value, markdown: markdown, isStreaming: isStreaming)
        }
    }
}

/// Role gate shared by the direct and hosted conversation surfaces. Keeping
/// this decision pure makes the "never render user-authored Markdown" rule
/// testable without relying on dependency internals or UI snapshots.
public enum AssistantRichTextPresentation {
    public static func shouldRenderDirect(_ kind: ConversationRow.Kind) -> Bool {
        kind == .assistant
    }

    public static func shouldRenderRoom(_ flavor: RoomTranscriptEntry.Flavor) -> Bool {
        flavor == .message(isUser: false)
    }
}

/// V1 URL policy for assistant Markdown. The renderer may parse a URL-like
/// destination, but only this policy can make it actionable.
public enum AssistantRichTextURLPolicy {
    /// Only explicit HTTPS links with a host are actionable in V1.
    public static func isActionable(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }

    fileprivate static func open(_ url: URL) -> OpenURLAction.Result {
        isActionable(url) ? .systemAction(url) : .discarded
    }
}

/// Display-only Markdown safety projection.
///
/// SwiftStreamingMarkdown already leaves HTML inert and its image support is
/// disabled by Fleet's config. This pass additionally removes unsafe inline
/// Markdown links from the renderer input, so `file:`, `javascript:`, custom
/// schemes, malformed destinations, and relative destinations are visibly
/// inert rather than merely blocked at activation time. Fenced/inline code is
/// copied byte-for-byte because code is content, not navigation.
public enum AssistantRichTextMarkdownSafety {
    public static func sanitizedMarkdown(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return markdown }

        var result = ""
        var inFence = false
        for index in lines.indices {
            let line = String(lines[index])
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")

            result += inFence ? line : sanitizeInlineLinks(in: line)
            if isFence {
                inFence.toggle()
            }
            if index != lines.index(before: lines.endIndex) {
                result.append("\n")
            }
        }
        return result
    }

    private static func sanitizeInlineLinks(in line: String) -> String {
        var result = ""
        var cursor = line.startIndex
        var inlineCodeTicks = 0

        while cursor < line.endIndex {
            let character = line[cursor]

            if character == "`" {
                let end = runEnd(of: "`", in: line, from: cursor)
                let count = line.distance(from: cursor, to: end)
                result += String(line[cursor..<end])
                if inlineCodeTicks == 0 {
                    inlineCodeTicks = count
                } else if inlineCodeTicks == count {
                    inlineCodeTicks = 0
                }
                cursor = end
                continue
            }

            if inlineCodeTicks == 0, character == "[",
               let close = matchingBracket(in: line, from: cursor) {
                let afterClose = line.index(after: close)
                var destinationStart = afterClose
                while destinationStart < line.endIndex,
                      line[destinationStart] == " " || line[destinationStart] == "\t" {
                    destinationStart = line.index(after: destinationStart)
                }

                if destinationStart < line.endIndex,
                   line[destinationStart] == "(",
                   let end = matchingParenthesis(in: line, from: destinationStart) {
                    let destination = markdownDestination(
                        in: line,
                        from: line.index(after: destinationStart),
                        through: end)
                    if isSafeDestination(destination) {
                        result += String(line[cursor...end])
                    } else {
                        // Keep the label's Markdown styling, but remove the
                        // link target and therefore all interactive behavior.
                        result += String(line[line.index(after: cursor)..<close])
                    }
                    cursor = line.index(after: end)
                    continue
                }
            }

            if inlineCodeTicks == 0, character == "<",
               let close = line[cursor...].firstIndex(of: ">") {
                let candidate = String(line[line.index(after: cursor)..<close])
                if !candidate.isEmpty, candidate.contains(":"),
                   !isSafeDestination(candidate) {
                    // Autolinks are the only URL-like angle-bracket form
                    // handled here; ordinary raw HTML remains untouched.
                    result += candidate
                    cursor = line.index(after: close)
                    continue
                }
            }

            result.append(character)
            cursor = line.index(after: cursor)
        }
        return result
    }

    private static func runEnd(of character: Character, in string: String, from start: String.Index) -> String.Index {
        var index = start
        while index < string.endIndex, string[index] == character {
            index = string.index(after: index)
        }
        return index
    }

    private static func matchingBracket(in string: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var index = start
        while index < string.endIndex {
            let character = string[index]
            if character == "\\" {
                index = string.index(after: index)
                if index < string.endIndex { index = string.index(after: index) }
                continue
            }
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = string.index(after: index)
        }
        return nil
    }

    private static func matchingParenthesis(in string: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var index = start
        while index < string.endIndex {
            let character = string[index]
            if character == "\\" {
                index = string.index(after: index)
                if index < string.endIndex { index = string.index(after: index) }
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = string.index(after: index)
        }
        return nil
    }

    private static func markdownDestination(
        in string: String,
        from start: String.Index,
        through end: String.Index
    ) -> String {
        guard start < end else { return "" }
        var destinationStart = start
        while destinationStart < end,
              string[destinationStart] == " " || string[destinationStart] == "\t" {
            destinationStart = string.index(after: destinationStart)
        }
        guard destinationStart < end else { return "" }

        if string[destinationStart] == "<" {
            let afterOpen = string.index(after: destinationStart)
            if let close = string[afterOpen..<end].firstIndex(of: ">") {
                return String(string[afterOpen..<close])
            }
        }

        var destinationEnd = destinationStart
        while destinationEnd < end,
              string[destinationEnd] != " " && string[destinationEnd] != "\t" {
            destinationEnd = string.index(after: destinationEnd)
        }
        return String(string[destinationStart..<destinationEnd])
    }

    private static func isSafeDestination(_ destination: String) -> Bool {
        guard let url = URL(string: destination.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return AssistantRichTextURLPolicy.isActionable(url)
    }
}

/// Stable full-snapshot source consumed by `StreamedMarkdownView`.
/// `bufferingNewest(1)` intentionally coalesces bursts of deltas while the
/// renderer is parsing; the newest complete snapshot is always authoritative.
final class AssistantRichTextStreamSource: StreamedMarkdownSource {
    private var stream: AsyncStream<String>
    private var continuation: AsyncStream<String>.Continuation

    private(set) var identity: String
    private(set) var latestSnapshot: String
    private(set) var snapshotUpdateCount = 0
    private(set) var isFinished = false

    var text: AsyncStream<String> { stream }

    init(identity: String, snapshot: String, isStreaming: Bool) {
        self.identity = identity
        self.latestSnapshot = snapshot
        let pair = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.stream = pair.stream
        self.continuation = pair.continuation
        continuation.yield(snapshot)
        if !isStreaming {
            continuation.finish()
            isFinished = true
        }
    }

    func publish(_ snapshot: String) {
        guard !isFinished, snapshot != latestSnapshot else { return }
        latestSnapshot = snapshot
        snapshotUpdateCount += 1
        continuation.yield(snapshot)
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        continuation.finish()
    }

    func cancel() {
        finish()
    }

    func replace(identity: String, snapshot: String, isStreaming: Bool) {
        cancel()
        self.identity = identity
        self.latestSnapshot = snapshot
        self.snapshotUpdateCount = 0
        self.isFinished = false
        let pair = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.stream = pair.stream
        self.continuation = pair.continuation
        continuation.yield(snapshot)
        if !isStreaming {
            finish()
        }
    }
}

private final class AssistantRichTextModel: ObservableObject {
    let source: AssistantRichTextStreamSource
    @Published private(set) var renderIdentity: String
    private var lastStreamingState: Bool

    init(identity: String, markdown: String, isStreaming: Bool) {
        let snapshot = AssistantRichTextMarkdownSafety.sanitizedMarkdown(markdown)
        self.source = AssistantRichTextStreamSource(
            identity: identity,
            snapshot: snapshot,
            isStreaming: isStreaming)
        self.renderIdentity = identity
        self.lastStreamingState = isStreaming
    }

    func update(markdown: String, isStreaming: Bool) {
        let snapshot = AssistantRichTextMarkdownSafety.sanitizedMarkdown(markdown)
        if source.isFinished,
           isStreaming != lastStreamingState || snapshot != source.latestSnapshot {
            // A stable row should not normally move after completion, but
            // reconnect/history hydration can reuse its identity with a new
            // authoritative snapshot. Restart only at that lifecycle
            // boundary; ordinary streaming updates stay on the same source.
            renderIdentity += ":restarted"
            source.replace(
                identity: renderIdentity,
                snapshot: snapshot,
                isStreaming: isStreaming)
        } else {
            source.publish(snapshot)
        }
        if !isStreaming {
            source.finish()
        }
        lastStreamingState = isStreaming
    }

    func replaceIdentity(_ identity: String, markdown: String, isStreaming: Bool) {
        renderIdentity = identity
        lastStreamingState = isStreaming
        source.replace(
            identity: identity,
            snapshot: AssistantRichTextMarkdownSafety.sanitizedMarkdown(markdown),
            isStreaming: isStreaming)
    }

    deinit {
        source.cancel()
    }
}

// Internal for deterministic FleetUI tests; it is not part of the app's
// public rendering surface.
enum FleetMarkdownRenderConfiguration {
    static func make(
        reduceMotion: Bool,
        dynamicTypeSize: DynamicTypeSize
    ) -> MarkdownRenderConfig {
        // Reading dynamicTypeSize makes the configuration recompute when the
        // user changes Dynamic Type. The actual fonts are preferred system
        // fonts, which carry the platform's scaling curve.
        _ = dynamicTypeSize

        let body = FleetMarkdownFonts.body
        let small = FleetMarkdownFonts.small
        let heading1 = FleetMarkdownFonts.heading1
        let heading2 = FleetMarkdownFonts.heading2
        let heading3 = FleetMarkdownFonts.heading3
        let code = FleetMarkdownFonts.code

        return MarkdownRenderConfig(
            // No token/reveal animation is used, even when Reduce Motion is
            // off; this is both calmer for chat and avoids per-delta flicker.
            shouldAnimateText: false && !reduceMotion,
            blockQuoteStyle: .init(textFonts: body, textColor: FleetTheme.textSecondary),
            headingStyle: .init(
                h1Font: heading1,
                h2Font: heading2,
                h3Font: heading3,
                h4Font: heading3,
                h5Font: small,
                h6Font: small,
                textColor: FleetTheme.textPrimary),
            orderedListStyle: .init(textFonts: body, textColor: FleetTheme.textPrimary),
            paragraphStyle: .init(textFonts: body, textColor: FleetTheme.textPrimary),
            tableStyle: .init(
                textFonts: small,
                headerTextColor: FleetTheme.textPrimary,
                regularTextColor: FleetTheme.textPrimary,
                headerBackgroundColor: FleetTheme.surfaceElevated,
                borderColor: FleetTheme.border,
                actionButtonColor: FleetTheme.accent),
            inlineStyle: .init(
                boldTextColor: FleetTheme.textPrimary,
                linkTextFont: body.normal,
                linkTextColor: FleetTheme.accent,
                linkUnderlineStyle: .single,
                codeTextFont: code.normal,
                codeTextColor: FleetTheme.textPrimary,
                codeBackgroundColor: FleetTheme.surfaceElevated,
                codeUnderlineColor: FleetTheme.accent),
            citationConfig: .init(
                isEnabled: false,
                font: small.normal,
                textColor: FleetTheme.textSecondary,
                backgroundColor: FleetTheme.surfaceElevated),
            codeBlockConfig: .init(
                theme: .xcode,
                backgroundColor: FleetTheme.surfaceElevated,
                foregroundColor: FleetTheme.textSecondary,
                codeTextFonts: code,
                chromeTextFonts: small),
            blockSpacing: FleetTheme.spacingMd,
            thematicBreakColor: FleetTheme.border,
            // Hard V1 privacy gate: no arbitrary Markdown image requests.
            imageConfig: .disabled)
    }
}

private enum FleetMarkdownFonts {
    #if canImport(UIKit)
    private static func regular(_ style: UIFont.TextStyle, weight: UIFont.Weight, monospaced: Bool = false) -> MDFont {
        let preferred = UIFont.preferredFont(forTextStyle: style)
        if monospaced {
            return UIFont.monospacedSystemFont(ofSize: preferred.pointSize, weight: weight)
        }
        return UIFont.systemFont(ofSize: preferred.pointSize, weight: weight)
    }

    private static func italic(_ font: MDFont) -> MDFont {
        let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
        return UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits) ?? font.fontDescriptor,
                      size: font.pointSize)
    }

    private static func textFonts(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> TextFonts {
        let normal = regular(style, weight: weight)
        let bold = regular(style, weight: .bold)
        return TextFonts(
            normal: normal,
            italic: italic(normal),
            bold: bold,
            boldItalic: italic(bold),
            preferredLetterSpacing: nil,
            preferredLineHeight: normal.lineHeight)
    }

    // Computed properties are intentional: SwiftUI re-evaluates the render
    // configuration when Dynamic Type changes, and UIKit's preferred fonts
    // must be read again instead of being frozen at first transcript render.
    static var body: TextFonts { textFonts(.body, weight: .regular) }
    static var small: TextFonts { textFonts(.footnote, weight: .regular) }
    static var heading1: TextFonts { textFonts(.title2, weight: .semibold) }
    static var heading2: TextFonts { textFonts(.title3, weight: .semibold) }
    static var heading3: TextFonts { textFonts(.headline, weight: .semibold) }
    static var code: TextFonts { textFonts(.callout, weight: .regular).withMonospacedVariants() }
    #elseif canImport(AppKit)
    private static func regular(_ size: CGFloat, weight: NSFont.Weight, monospaced: Bool = false) -> MDFont {
        monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func italic(_ font: MDFont) -> MDFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private static func textFonts(_ size: CGFloat, weight: NSFont.Weight) -> TextFonts {
        let normal = regular(size, weight: weight)
        let bold = regular(size, weight: .bold)
        return TextFonts(
            normal: normal,
            italic: italic(normal),
            bold: bold,
            boldItalic: italic(bold),
            preferredLetterSpacing: nil,
            preferredLineHeight: normal.lineHeight)
    }

    static var body: TextFonts { textFonts(17, weight: .regular) }
    static var small: TextFonts { textFonts(13, weight: .regular) }
    static var heading1: TextFonts { textFonts(24, weight: .semibold) }
    static var heading2: TextFonts { textFonts(20, weight: .semibold) }
    static var heading3: TextFonts { textFonts(17, weight: .semibold) }
    static var code: TextFonts { textFonts(15, weight: .regular).withMonospacedVariants() }
    #endif
}

private extension TextFonts {
    func withMonospacedVariants() -> TextFonts {
        #if canImport(UIKit)
        let normal = UIFont.monospacedSystemFont(ofSize: self.normal.pointSize, weight: .regular)
        let bold = UIFont.monospacedSystemFont(ofSize: (self.bold ?? self.normal).pointSize, weight: .bold)
        return TextFonts(
            normal: normal,
            italic: normal,
            bold: bold,
            boldItalic: bold,
            preferredLetterSpacing: preferredLetterSpacing,
            preferredLineHeight: preferredLineHeight)
        #elseif canImport(AppKit)
        let normal = NSFont.monospacedSystemFont(ofSize: self.normal.pointSize, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: (self.bold ?? self.normal).pointSize, weight: .bold)
        return TextFonts(
            normal: normal,
            italic: normal,
            bold: bold,
            boldItalic: bold,
            preferredLetterSpacing: preferredLetterSpacing,
            preferredLineHeight: preferredLineHeight)
        #endif
    }
}
