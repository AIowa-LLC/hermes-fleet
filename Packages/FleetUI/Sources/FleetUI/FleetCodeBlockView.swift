import HighlightSwift
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Issue #109 (D6): Fleet-owned code card for top-level fenced blocks in
/// assistant Markdown. Drawn by `AssistantRichTextView` between the prose
/// runs it hands to the third-party renderer.
///
/// - Opaque card (no glass on content).
/// - Header: language label from the fence info string (absent when the
///   fence declares none) and a Copy control with a 44 pt target.
/// - Code scrolls horizontally instead of wrapping; a trailing/leading fade
///   marks hidden content only while the line overflows.
/// - Syntax colors come from `CodeBlockAppearance` (palette chosen from the
///   active card, contrast-gated), not from the system color scheme.
struct FleetCodeBlockView: View {
    let fence: CodeFence
    let appearance: CodeBlockAppearance

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var copyCount = 0
    @State private var highlighted: HighlightedCode?
    @State private var scrollMetrics = ScrollMetrics()

    private static let cornerRadius = FleetTheme.radiusRow
    private static let fadeWidth: CGFloat = 28
    private static let copiedResetDelay: Duration = .milliseconds(1500)

    private var languageLabel: String? {
        CodeFenceInfo.languageLabel(from: fence.info)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            codeScroller
        }
        .background(appearance.card.swiftUIColor)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(appearance.chromeInk.swiftUIColor.opacity(0.14), lineWidth: 0.5)
        }
        .sensoryFeedback(.success, trigger: copyCount)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("fleet.conversation.code.block")
        .task(id: HighlightRequest(code: fence.body, info: fence.info, css: appearance.css, isClosed: fence.isClosed)) {
            await refreshHighlight()
        }
        .task(id: copyCount) {
            guard copyCount > 0 else { return }
            try? await Task.sleep(for: Self.copiedResetDelay)
            guard !Task.isCancelled else { return }
            setCopied(false)
        }
    }

    private var accessibilityLabel: String {
        if let languageLabel { "Code block, \(languageLabel)" } else { "Code block" }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: FleetTheme.spacingSm) {
            if let languageLabel {
                Text(languageLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(appearance.chromeInk.swiftUIColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true) // folded into the block label
                    .accessibilityIdentifier("fleet.conversation.code.language")
            }
            Spacer(minLength: 0)
            copyButton
        }
        .padding(.leading, FleetTheme.spacingLg)
        .padding(.trailing, FleetTheme.spacingXs)
    }

    private var copyButton: some View {
        Button(action: copy) {
            Label {
                Text(copied ? "Copied" : "Copy")
            } icon: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            .labelStyle(.titleAndIcon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(appearance.chromeInk.swiftUIColor)
            .padding(.horizontal, FleetTheme.spacingMd)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(fence.body.isEmpty)
        .opacity(fence.body.isEmpty ? 0.4 : 1)
        .accessibilityLabel("Copy code")
        .accessibilityIdentifier("fleet.conversation.code.copy")
    }

    // MARK: Code

    private var codeScroller: some View {
        let fades = CodeBlockEdgeFades.resolve(
            contentWidth: scrollMetrics.contentWidth,
            viewportWidth: scrollMetrics.viewportWidth,
            offset: scrollMetrics.offset)
        return ScrollView(.horizontal, showsIndicators: false) {
            codeText
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: true, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, FleetTheme.spacingLg)
                .padding(.top, FleetTheme.spacingXs)
                .padding(.bottom, FleetTheme.spacingLg)
                .accessibilityIdentifier("fleet.conversation.code.text")
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .fixedSize(horizontal: false, vertical: true)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                contentWidth: Double(geometry.contentSize.width),
                viewportWidth: Double(geometry.containerSize.width),
                offset: Double(geometry.contentOffset.x))
        } action: { _, metrics in
            scrollMetrics = metrics
        }
        .mask { fadeMask(fades) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: fades)
        .accessibilityIdentifier("fleet.conversation.code.scroller")
        #if DEBUG
        // UI-test seam: lets the rendering test observe whether the fade edges
        // are active without a screenshot. Not shipped to VoiceOver users.
        .accessibilityValue(fades.trailing || fades.leading ? "overflowing" : "fits")
        #endif
    }

    private func fadeMask(_ fades: CodeBlockEdgeFades) -> some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(fades.leading ? 0 : 1), .black],
                startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fadeWidth)
            Rectangle().fill(.black)
            LinearGradient(
                colors: [.black, .black.opacity(fades.trailing ? 0 : 1)],
                startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fadeWidth)
        }
    }

    /// Highlighted text while it matches the current code; otherwise the last
    /// highlighted prefix plus the un-highlighted tail (streaming appends), so
    /// tokens never flash back to a single ink between deltas.
    private var codeText: Text {
        let ink = appearance.ink.swiftUIColor
        guard let highlighted else {
            return Text(fence.body).foregroundStyle(ink)
        }
        if highlighted.source == fence.body {
            return Text(highlighted.attributed)
        }
        if fence.body.hasPrefix(highlighted.source) {
            var tail = AttributedString(String(fence.body.dropFirst(highlighted.source.count)))
            tail.foregroundColor = ink
            return Text(highlighted.attributed + tail)
        }
        return Text(fence.body).foregroundStyle(ink)
    }

    // MARK: Actions

    private func copy() {
        guard CodeBlockCopier.copy(fence.body, to: LiveCodeBlockPasteboard()) else { return }
        copyCount += 1
        setCopied(true)
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: "Copied")
        #endif
    }

    private func setCopied(_ value: Bool) {
        if reduceMotion {
            copied = value
        } else {
            withAnimation(.snappy(duration: 0.2)) { copied = value }
        }
    }

    private func refreshHighlight() async {
        let code = fence.body
        guard !code.isEmpty, appearance.palette != .monochrome else {
            highlighted = nil
            return
        }
        if !fence.isClosed {
            // Coalesce streaming deltas; the last snapshot always wins.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
        }
        let result = await FleetCodeHighlighter.shared.highlight(
            code,
            alias: CodeFenceInfo.highlightAlias(from: fence.info),
            css: appearance.css)
        guard !Task.isCancelled, let result else { return }
        highlighted = HighlightedCode(source: code, attributed: result)
    }
}

// MARK: - Supporting types

private struct ScrollMetrics: Equatable {
    var contentWidth: Double = 0
    var viewportWidth: Double = 0
    var offset: Double = 0
}

private struct HighlightedCode {
    let source: String
    let attributed: AttributedString
}

private struct HighlightRequest: Equatable {
    let code: String
    let info: String
    let css: String
    let isClosed: Bool
}

/// One shared highlight.js context (each `Highlight()` evaluates the ~600 KB
/// script in its own JSContext, so per-block instances would be expensive).
actor FleetCodeHighlighter {
    static let shared = FleetCodeHighlighter()

    private let engine = Highlight()

    /// Highlights `code` with an explicit language when one is declared and
    /// known, otherwise with highlight.js auto-detection (the previous
    /// renderer behavior; the language *label* is never derived from it).
    /// Returns `nil` when highlighting fails, so the caller keeps plain ink.
    func highlight(_ code: String, alias: String?, css: String) async -> AttributedString? {
        // The importer trims surrounding whitespace; keep it so indentation
        // on the first line and trailing newlines survive.
        let core = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty,
              let coreRange = code.range(of: core) else { return nil }
        let leading = String(code[code.startIndex..<coreRange.lowerBound])
        let trailing = String(code[coreRange.upperBound...])
        let colors = HighlightColors.custom(css: css)

        var result: AttributedString?
        if let alias {
            result = try? await engine.request(
                core, mode: .languageAliasIgnoreIllegal(alias), colors: colors).attributedText
        }
        if result == nil {
            result = try? await engine.request(core, mode: .automatic, colors: colors).attributedText
        }
        guard let result else { return nil }
        return AttributedString(leading) + result + AttributedString(trailing)
    }
}

/// Live pasteboard writer: device-local and expiring (see
/// `CodeBlockPasteboardPolicy`).
struct LiveCodeBlockPasteboard: CodeBlockPasteboardWriting {
    func write(_ string: String, policy: CodeBlockPasteboardPolicy, now: Date) {
        #if canImport(UIKit)
        var options: [UIPasteboard.OptionsKey: Any] = [
            .expirationDate: now.addingTimeInterval(policy.timeToLive)
        ]
        if policy.localOnly { options[.localOnly] = true }
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: string]],
            options: options)
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
