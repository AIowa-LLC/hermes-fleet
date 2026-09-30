import SwiftUI
import UIKit
import XCTest
@testable import FleetUI

/// Issue #109 (D6): pure-logic and hosted coverage for the assistant code-block
/// chrome. Synthetic fixtures only; no renderer snapshots.
@MainActor
final class CodeBlockChromeTests: XCTestCase {

    // MARK: - Language label

    func testLanguageLabelComesFromFenceInfoString() {
        XCTAssertEqual(CodeFenceInfo.languageLabel(from: "swift"), "swift")
        XCTAssertEqual(CodeFenceInfo.languageLabel(from: "  python  "), "python")
        XCTAssertEqual(CodeFenceInfo.languageLabel(from: "python title=x"), "python")
        XCTAssertEqual(CodeFenceInfo.languageLabel(from: "{.python .numberLines}"), "python")
        XCTAssertEqual(CodeFenceInfo.languageLabel(from: "c++"), "c++")
        XCTAssertEqual(CodeFenceInfo.languageLabel(from: "c#"), "c#")
        XCTAssertEqual(CodeFenceInfo.languageLabel(from: "Objective-C"), "Objective-C")
        // Unknown languages are shown as authored, never guessed or dropped.
        XCTAssertEqual(CodeFenceInfo.languageLabel(from: "brainfuck"), "brainfuck")
    }

    func testMissingOrUnusableInfoStringShowsNoLabel() {
        XCTAssertNil(CodeFenceInfo.languageLabel(from: ""))
        XCTAssertNil(CodeFenceInfo.languageLabel(from: "   "))
        XCTAssertNil(CodeFenceInfo.languageLabel(from: "title=x"))
        XCTAssertNil(CodeFenceInfo.languageLabel(from: "<script>"))
        XCTAssertNil(CodeFenceInfo.languageLabel(from: String(repeating: "a", count: 200)))
        XCTAssertNil(CodeFenceInfo.highlightAlias(from: ""))
        XCTAssertEqual(CodeFenceInfo.highlightAlias(from: "Swift title=x"), "swift")
    }

    // MARK: - Segmentation

    func testMarkdownWithoutFencesIsOneUntouchedProseSegment() {
        let markdown = "Plain **text**\n\n- item"
        XCTAssertEqual(AssistantRichTextView.segments(for: markdown), [.prose(markdown)])
        XCTAssertEqual(AssistantRichTextView.segments(for: ""), [.prose("")])
    }

    func testClosedFenceBecomesCodeSegmentWithExactBody() {
        let markdown = "Before\n\n```swift\n    let a = 1\n\nlet b = 2\n```\n\nAfter"
        XCTAssertEqual(AssistantMarkdownSegmenter.split(markdown), [
            .prose("Before\n"),
            .code(CodeFence(info: "swift", body: "    let a = 1\n\nlet b = 2", isClosed: true)),
            .prose("\nAfter")
        ])
    }

    func testUnclosedFenceStreamsAsOpenBlock() {
        let split = AssistantMarkdownSegmenter.split("Intro\n```python\nprint(1)\nprint(")
        XCTAssertEqual(split, [
            .prose("Intro"),
            .code(CodeFence(info: "python", body: "print(1)\nprint(", isClosed: false))
        ])
    }

    func testInfoStringIsWithheldUntilItsLineIsTerminated() {
        // "```swi" may still be growing; it must not flash as a label.
        XCTAssertEqual(
            AssistantMarkdownSegmenter.split("```swi"),
            [.code(CodeFence(info: "", body: "", isClosed: false))])
        XCTAssertEqual(
            AssistantMarkdownSegmenter.split("```swift\n"),
            [.code(CodeFence(info: "swift", body: "", isClosed: false))])
    }

    func testLongerFenceContainsShorterFenceAndTildesWork() {
        let nested = "````markdown\n```swift\nlet x = 1\n```\n````"
        XCTAssertEqual(AssistantMarkdownSegmenter.split(nested), [
            .code(CodeFence(info: "markdown", body: "```swift\nlet x = 1\n```", isClosed: true))
        ])
        XCTAssertEqual(AssistantMarkdownSegmenter.split("~~~sh\nls\n~~~"), [
            .code(CodeFence(info: "sh", body: "ls", isClosed: true))
        ])
    }

    func testIndentedFencesAndInlineTripleBackticksStayInProse() {
        let listFence = "- item\n  ```swift\n  let a = 1\n  ```"
        XCTAssertEqual(AssistantMarkdownSegmenter.split(listFence), [.prose(listFence)])
        let inline = "```not a fence``` in a sentence"
        XCTAssertEqual(AssistantMarkdownSegmenter.split(inline), [.prose(inline)])
    }

    func testCarriageReturnsDoNotLeakIntoBodyOrBreakClosing() {
        let split = AssistantMarkdownSegmenter.split("```sh\r\nls\r\n```\r\n")
        XCTAssertEqual(split.first, .code(CodeFence(info: "sh", body: "ls", isClosed: true)))
    }

    // MARK: - Overflow fades

    func testFadesAppearOnlyWhileContentOverflows() {
        XCTAssertEqual(
            CodeBlockEdgeFades.resolve(contentWidth: 300, viewportWidth: 320, offset: 0), .none)
        // Exact fit and sub-point rounding never fade.
        XCTAssertEqual(
            CodeBlockEdgeFades.resolve(contentWidth: 320.4, viewportWidth: 320, offset: 0), .none)
        XCTAssertEqual(
            CodeBlockEdgeFades.resolve(contentWidth: 1400, viewportWidth: 320, offset: 0),
            CodeBlockEdgeFades(leading: false, trailing: true))
        XCTAssertEqual(
            CodeBlockEdgeFades.resolve(contentWidth: 1400, viewportWidth: 320, offset: 500),
            CodeBlockEdgeFades(leading: true, trailing: true))
        XCTAssertEqual(
            CodeBlockEdgeFades.resolve(contentWidth: 1400, viewportWidth: 320, offset: 1080),
            CodeBlockEdgeFades(leading: true, trailing: false))
        XCTAssertEqual(
            CodeBlockEdgeFades.resolve(contentWidth: 1400, viewportWidth: 0, offset: 0), .none)
    }

    // MARK: - Syntax palette selection and contrast gate

    private func theme(
        text: UInt32, background: UInt32, dark: Bool, increased: Bool = false
    ) -> FleetThemeValues {
        FleetThemeValues(
            palette: FleetThemePalette(
                highlight: FleetStoredColor(hex: 0x5B35D5),
                text: FleetStoredColor(hex: text),
                background: FleetStoredColor(hex: background)),
            isDarkAppearance: dark,
            isIncreasedContrast: increased)
    }

    private func assertGate(
        _ appearance: CodeBlockAppearance, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            FleetThemeContrast.ratio(appearance.ink, appearance.card),
            FleetThemeContrast.normalTextMinimum, "ink", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            FleetThemeContrast.ratio(appearance.chromeInk, appearance.card),
            FleetThemeContrast.normalTextMinimum, "chrome ink", file: file, line: line)
        for (token, color) in appearance.tokenColors {
            XCTAssertGreaterThanOrEqual(
                FleetThemeContrast.ratio(color, appearance.card),
                appearance.minimumContrast, "\(token)", file: file, line: line)
        }
    }

    func testBuiltInDarkThemeUsesDarkCardPaletteWithLegibleTokens() {
        for increased in [false, true] {
            let values = FleetThemeValues(
                palette: .fleetDefault, isDarkAppearance: true, isIncreasedContrast: increased)
            let appearance = CodeBlockAppearance.make(theme: values)
            XCTAssertEqual(appearance.palette, .darkCard)
            XCTAssertEqual(appearance.tokenColors.count, CodeBlockAppearance.Token.allCases.count)
            XCTAssertEqual(appearance.minimumContrast, increased ? 7.0 : 4.5)
            assertGate(appearance)
        }
    }

    func testBuiltInLightThemeUsesLightCardPaletteWithLegibleTokens() {
        for increased in [false, true] {
            let values = FleetThemeValues(
                palette: .fleetDefault, isDarkAppearance: false, isIncreasedContrast: increased)
            let appearance = CodeBlockAppearance.make(theme: values)
            XCTAssertEqual(appearance.palette, .lightCard)
            assertGate(appearance)
        }
    }

    func testPaletteFollowsTheCardNotTheSystemAppearance() {
        // Light ink on a stored dark canvas while the DEVICE is light: the old
        // fixed `.xcode` theme picked its light-ink-on-light variant here.
        let values = theme(text: 0xFFFFFF, background: 0x000000, dark: false)
        let appearance = CodeBlockAppearance.make(theme: values)
        XCTAssertEqual(appearance.palette, .darkCard)
        assertGate(appearance)
    }

    func testCustomThemesKeepTokensLegibleOrFallBackToMonochrome() {
        let warm = CodeBlockAppearance.make(
            theme: theme(text: 0xF1E8D8, background: 0x17202A, dark: true))
        XCTAssertNotEqual(warm.palette, .monochrome)
        assertGate(warm)

        let paper = CodeBlockAppearance.make(
            theme: theme(text: 0x2B2118, background: 0xFBF3E4, dark: false))
        assertGate(paper)

        // A mid-tone card no token color can satisfy falls back to one ink.
        let mono = CodeBlockAppearance.resolve(
            card: FleetStoredColor(hex: 0x777777),
            ink: FleetStoredColor(hex: 0x000000),
            minimumContrast: 7.0)
        XCTAssertEqual(mono.palette, .monochrome)
        XCTAssertTrue(mono.tokenColors.isEmpty)
        XCTAssertEqual(mono.css, "code { color: #000000 }")
    }

    func testCSSCarriesEveryTokenRoleForAHighlightedPalette() {
        let appearance = CodeBlockAppearance.make(
            theme: FleetThemeValues(
                palette: .fleetDefault, isDarkAppearance: true, isIncreasedContrast: false))
        for selector in [".hljs-keyword", ".hljs-string", ".hljs-comment", ".hljs-number"] {
            XCTAssertTrue(appearance.css.contains(selector), selector)
        }
    }

    func testCardFillStaysTheSameDerivationAsBefore() throws {
        let values = FleetThemeValues(
            palette: .fleetDefault, isDarkAppearance: true, isIncreasedContrast: false)
        XCTAssertEqual(
            FleetStoredColor(color: FleetMarkdownRenderConfiguration.codeCardBackground(theme: values)),
            CodeBlockAppearance.cardFill(theme: values))
    }

    func testRendererConfigurationUsesPaletteSelectedThemeNotFixedXcode() {
        let values = FleetThemeValues(
            palette: .fleetDefault, isDarkAppearance: false, isIncreasedContrast: false)
        let appearance = CodeBlockAppearance.make(theme: values)
        let config = FleetMarkdownRenderConfiguration.make(
            theme: values, reduceMotion: false, dynamicTypeSize: .large)
        XCTAssertEqual(
            config.codeBlockConfig.theme,
            .custom(lightCSS: appearance.css, darkCSS: appearance.css))
    }

    // MARK: - Copy

    private final class RecordingPasteboard: CodeBlockPasteboardWriting {
        var writes: [(String, CodeBlockPasteboardPolicy, Date)] = []
        func write(_ string: String, policy: CodeBlockPasteboardPolicy, now: Date) {
            writes.append((string, policy, now))
        }
    }

    func testCopyWritesExactBlockTextLocalOnlyWithExpiry() throws {
        let pasteboard = RecordingPasteboard()
        let now = Date(timeIntervalSince1970: 1_000)
        let code = "  indented\n\nlet x = \"quoted\"\t"
        XCTAssertTrue(CodeBlockCopier.copy(code, to: pasteboard, now: now))
        let write = try XCTUnwrap(pasteboard.writes.first)
        XCTAssertEqual(write.0, code)
        XCTAssertTrue(write.1.localOnly)
        XCTAssertGreaterThan(write.1.timeToLive, 0)
        XCTAssertLessThanOrEqual(write.1.timeToLive, 600)
        XCTAssertEqual(write.2, now)
    }

    func testEmptyBlockIsNeverCopied() {
        let pasteboard = RecordingPasteboard()
        XCTAssertFalse(CodeBlockCopier.copy("", to: pasteboard))
        XCTAssertTrue(pasteboard.writes.isEmpty)
    }

    func testLivePasteboardWritesPlainTextToTheGeneralPasteboard() {
        let code = "let synthetic = \"d6-\(UUID().uuidString)\""
        LiveCodeBlockPasteboard().write(code, policy: CodeBlockPasteboardPolicy(), now: Date())
        XCTAssertEqual(UIPasteboard.general.string, code)
        UIPasteboard.general.items = []
    }

    // MARK: - Hosted rendering (no snapshots)

    private func host(_ code: String, width: CGFloat = 320) -> (UIHostingController<AnyView>, UIWindow) {
        let appearance = CodeBlockAppearance.make(
            theme: FleetThemeValues(
                palette: .fleetDefault, isDarkAppearance: true, isIncreasedContrast: false))
        let view = FleetCodeBlockView(
            fence: CodeFence(info: "swift", body: code, isClosed: true),
            appearance: appearance)
        let controller = UIHostingController(rootView: AnyView(view.frame(width: width)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 800))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        if let scroll = view as? UIScrollView { result.append(scroll) }
        for child in view.subviews { result += scrollViews(in: child) }
        return result
    }

    func testLongLineDoesNotWrapAndScrollsHorizontally() throws {
        let long = String(repeating: "let value = compute(argument) + ", count: 10) // > 300 columns
        XCTAssertGreaterThan(long.count, 200)
        let (longHost, longWindow) = host(long)
        let (shortHost, shortWindow) = host("let a = 1")
        defer { longWindow.isHidden = true; shortWindow.isHidden = true }

        let longSize = longHost.sizeThatFits(in: CGSize(width: 320, height: .greatestFiniteMagnitude))
        let shortSize = shortHost.sizeThatFits(in: CGSize(width: 320, height: .greatestFiniteMagnitude))
        XCTAssertEqual(
            longSize.height, shortSize.height, accuracy: 1,
            "a single long line must not wrap into extra lines")

        let longScroll = try XCTUnwrap(scrollViews(in: longHost.view).first)
        XCTAssertGreaterThan(
            longScroll.contentSize.width, longScroll.bounds.width + 200,
            "long code must be horizontally scrollable")
        let shortScroll = try XCTUnwrap(scrollViews(in: shortHost.view).first)
        XCTAssertLessThanOrEqual(shortScroll.contentSize.width, shortScroll.bounds.width + 1)
    }
}
