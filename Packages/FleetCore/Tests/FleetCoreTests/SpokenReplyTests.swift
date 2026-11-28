import XCTest
@testable import FleetCore

/// Spoken-reply preparation: SpokenText (markdown to speech text) and
/// SentenceChunker (streamed deltas to whole sentences).
final class SpokenReplyTests: XCTestCase {

    // MARK: - SpokenText

    func testHeadingsBecomePhrases() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "# Title\nBody text."),
            "Title. Body text."
        )
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "### Deep\n###### Deeper"),
            "Deep. Deeper"
        )
    }

    func testBulletsReadAsSeparatePhrases() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "- apples\n- pears\n* plums"),
            "apples. pears. plums"
        )
    }

    func testNumberedListMarkersRemoved() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "1. First\n2) Second"),
            "First. Second"
        )
    }

    func testBoldAndItalicStripped() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "This is **bold** and *italic* and ~~gone~~ text."),
            "This is bold and italic and gone text."
        )
    }

    func testUnderscoresInsideWordsArePreserved() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "Call my_snake_case_name now."),
            "Call my_snake_case_name now."
        )
    }

    func testWordWrappingUnderscoreEmphasisRemoved() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "This is _emphasized_ text."),
            "This is emphasized text."
        )
    }

    func testInlineCodeKeepsContentWithoutBackticks() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "Run `swift build` now."),
            "Run swift build now."
        )
    }

    func testClosedFencedBlockRemoved() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "Here is code:\n```swift\nlet x = 1\n```\nThat's it."),
            "Here is code: That's it."
        )
    }

    func testUnclosedFencedBlockRemoved() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "Intro sentence.\n```\nlet a = 1"),
            "Intro sentence."
        )
    }

    func testLinkKeepsTextAndDropsURL() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "See [the docs](https://example.com/docs) for more."),
            "See the docs for more."
        )
    }

    func testImageKeepsAltText() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "![Chart](https://x.test/c.png) shown"),
            "Chart shown"
        )
    }

    func testBareURLDropped() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "Visit https://example.com/page today."),
            "Visit today."
        )
    }

    func testTableRowsReadCellsAndDropSeparator() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "| Name | Age |\n|---|---|\n| Ann | 3 |"),
            "Name, Age. Ann, 3"
        )
    }

    func testHorizontalRuleDropped() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "Above line\n\n---\n\nBelow line"),
            "Above line. Below line"
        )
    }

    func testSoftWrappedParagraphLinesJoinWithSpace() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "This sentence wraps\nonto the next line."),
            "This sentence wraps onto the next line."
        )
    }

    func testBlockquoteMarkerRemoved() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "> A quoted line."),
            "A quoted line."
        )
    }

    func testDecimalNumbersUntouched() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "Pi is 3.14 exactly."),
            "Pi is 3.14 exactly."
        )
    }

    func testWhitespaceCollapsed() {
        XCTAssertEqual(
            SpokenText.plain(fromMarkdown: "a    b\t\tc"),
            "a b c"
        )
    }

    func testEmptyResults() {
        XCTAssertEqual(SpokenText.plain(fromMarkdown: ""), "")
        XCTAssertEqual(SpokenText.plain(fromMarkdown: "```\nonly code\n```"), "")
        XCTAssertEqual(SpokenText.plain(fromMarkdown: "   \n\n  "), "")
    }

    // MARK: - SentenceChunker

    func testTwoSentencesInOneDeltaYieldTwoSegments() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("First one. Second one! "), ["First one.", "Second one!"])
        XCTAssertFalse(chunker.hasPendingText)
    }

    func testSentenceSplitAcrossDeltasIsHeldUntilBoundary() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("Hello wor"), [])
        XCTAssertEqual(chunker.append("ld. Next"), ["Hello world."])
        XCTAssertTrue(chunker.hasPendingText)
        XCTAssertEqual(chunker.flush(), "Next")
    }

    func testDecimalNumberIsNotASplit() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("3.14 is pi. Done"), ["3.14 is pi."])
        XCTAssertEqual(chunker.flush(), "Done")
    }

    func testDomainNameIsNotASplit() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("example.com is nice. Yes"), ["example.com is nice."])
    }

    func testEllipsisRunIsOneBoundaryAndQuestionRunIsOne() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("Wait... what?"), ["Wait..."])
        XCTAssertEqual(chunker.flush(), "what?")

        var other = SentenceChunker()
        XCTAssertEqual(other.append("Really?! Yes."), ["Really?!"])
        XCTAssertEqual(other.flush(), "Yes.")
    }

    func testNewlineIsBoundary() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("Line one\nLine two\n"), ["Line one", "Line two"])
        XCTAssertFalse(chunker.hasPendingText)
    }

    func testWhitespaceOnlyNeverEmitted() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append(" \n \n"), [])
        XCTAssertFalse(chunker.hasPendingText)
        XCTAssertNil(chunker.flush())
    }

    func testCodeFenceHeldUntilClosedThenEmittedWhole() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("Here:\n```swift\nlet x = 1.\n"), ["Here:"])
        XCTAssertEqual(
            chunker.append("print(x)\n```\nDone. "),
            ["```swift\nlet x = 1.\nprint(x)\n```", "Done."]
        )
    }

    func testUnclosedFenceHeldUntilFlush() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("```\ncode. more\n"), [])
        XCTAssertTrue(chunker.hasPendingText)
        XCTAssertEqual(chunker.flush(), "```\ncode. more")
    }

    func testFlushReturnsRemainderThenNil() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("Partial sentence"), [])
        XCTAssertEqual(chunker.flush(), "Partial sentence")
        XCTAssertNil(chunker.flush())
    }

    func testResetClearsBuffer() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("abc"), [])
        XCTAssertTrue(chunker.hasPendingText)
        chunker.reset()
        XCTAssertFalse(chunker.hasPendingText)
        XCTAssertNil(chunker.flush())
    }

    func testFreshChunkerHasNoPendingText() {
        let chunker = SentenceChunker()
        XCTAssertFalse(chunker.hasPendingText)
    }
}
