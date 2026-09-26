import XCTest
@testable import FleetUI

/// P0-B (RC-84) — Find in Conversation policy: matching taxonomy, snippet
/// shaping, wrap-around navigation, and the status line. Pure logic; no UI.
final class ConversationFindPolicyTests: XCTestCase {

    private func row(_ id: String, _ kind: ConversationRow.Kind, _ text: String, failed: Bool = false) -> ConversationRow {
        ConversationRow(id: id, kind: kind, text: text, isFailed: failed)
    }

    // MARK: - Matching

    func testMatchesUserAndAssistantRowsOnly() {
        let rows = [
            row("u1", .user, "deploy the zebra"),
            row("a1", .assistant, "the zebra is deployed"),
            row("t1", .tool, "zebra tool output"),
            row("s1", .status, "zebra status line"),
            row("y1", .system, "zebra system note"),
            row("e1", .error, "zebra error"),
        ]
        let matches = ConversationFindPolicy.matches(rows: rows, query: "zebra")
        XCTAssertEqual(matches.map(\.rowID), ["u1", "a1"],
                       "tool/status/system/error chrome is not conversation content")
    }

    func testMatchingIsCaseAndDiacriticInsensitive() {
        let rows = [row("u1", .user, "Café closed at CAFE o'clock")]
        XCTAssertEqual(ConversationFindPolicy.matches(rows: rows, query: "cafe").count, 1)
        XCTAssertEqual(ConversationFindPolicy.matches(rows: rows, query: "CAFÉ").count, 1)
    }

    func testEmptyBlankAndWhitespaceQueriesMatchNothing() {
        let rows = [row("u1", .user, "anything")]
        XCTAssertTrue(ConversationFindPolicy.matches(rows: rows, query: "").isEmpty)
        XCTAssertTrue(ConversationFindPolicy.matches(rows: rows, query: "   ").isEmpty)
        XCTAssertTrue(ConversationFindPolicy.matches(rows: rows, query: "\n\t").isEmpty)
    }

    func testFailedRowRemainsSearchable() {
        let rows = [row("u1", .user, "retry me", failed: true)]
        XCTAssertEqual(ConversationFindPolicy.matches(rows: rows, query: "retry").count, 1)
    }

    func testEmptyTextRowsAreSkipped() {
        let rows = [row("u1", .user, ""), row("a1", .assistant, "")]
        XCTAssertTrue(ConversationFindPolicy.matches(rows: rows, query: "  ").isEmpty)
    }

    func testOneMatchPerRow() {
        let rows = [row("u1", .user, "zebra zebra zebra")]
        XCTAssertEqual(ConversationFindPolicy.matches(rows: rows, query: "zebra").count, 1,
                       "one navigation stop per row")
    }

    // MARK: - Snippets

    func testSnippetCarriesContextAndEllipsisesBothSides() {
        let text = String(repeating: "pre ", count: 40) + "zebra" + String(repeating: " post", count: 40)
        let range = text.range(of: "zebra")!
        let snippet = ConversationFindPolicy.snippet(in: text, around: range)
        XCTAssertTrue(snippet.contains("zebra"))
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    func testSnippetCollapsesNewlines() {
        let text = "line one\nline two zebra line three\nline four"
        let range = text.range(of: "zebra")!
        let snippet = ConversationFindPolicy.snippet(in: text, around: range)
        XCTAssertFalse(snippet.contains("\n"))
        XCTAssertTrue(snippet.contains("zebra"))
    }

    func testSnippetAtTextEdgesAddsNoLeadingEllipsis() {
        let text = "zebra at the start"
        let range = text.range(of: "zebra")!
        XCTAssertFalse(ConversationFindPolicy.snippet(in: text, around: range).hasPrefix("…"))
    }

    // MARK: - Navigation

    func testNextIndexWraps() {
        XCTAssertEqual(ConversationFindPolicy.nextIndex(current: 0, count: 3), 1)
        XCTAssertEqual(ConversationFindPolicy.nextIndex(current: 2, count: 3), 0)
    }

    func testPreviousIndexWraps() {
        XCTAssertEqual(ConversationFindPolicy.previousIndex(current: 1, count: 3), 0)
        XCTAssertEqual(ConversationFindPolicy.previousIndex(current: 0, count: 3), 2)
    }

    func testNavigationWithNoMatchesStaysAtZero() {
        XCTAssertEqual(ConversationFindPolicy.nextIndex(current: 0, count: 0), 0)
        XCTAssertEqual(ConversationFindPolicy.previousIndex(current: 0, count: 0), 0)
    }

    // MARK: - Status line

    func testPositionText() {
        XCTAssertEqual(ConversationFindPolicy.positionText(index: 0, count: 7), "1 of 7")
        XCTAssertEqual(ConversationFindPolicy.positionText(index: 6, count: 7), "7 of 7")
        XCTAssertEqual(ConversationFindPolicy.positionText(index: 99, count: 7), "7 of 7",
                       "index clamps to the loaded matches")
        XCTAssertEqual(ConversationFindPolicy.positionText(index: 0, count: 0), "")
    }
}