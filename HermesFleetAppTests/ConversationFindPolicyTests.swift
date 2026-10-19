import XCTest
@testable import FleetCore
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

/// DEV19 L2 — group-chat (RoomChatView) parity with the 1:1 conversation for
/// Copy Message, Find in Conversation over group rows, and the Retry
/// availability gate. Pure policy only: no view construction, no gateway.
/// Lives beside the find-policy tests (no new test file, so the generated
/// project stays in sync).
final class RoomChatParityTests: XCTestCase {

    private func entry(
        _ id: String,
        _ flavor: RoomTranscriptEntry.Flavor,
        _ text: String?,
        seq: Int = 1
    ) -> RoomTranscriptEntry {
        RoomTranscriptEntry(
            id: id, seq: seq, flavor: flavor, speaker: "Speaker",
            text: text, failure: nil, createdAt: 0)
    }

    // MARK: - Copy Message (shared policy, group rows)

    func testCopyPayloadIsTheLiteralVisibleText() {
        let markdown = "  **bold** and `code`\n\n- item  "
        XCTAssertEqual(MessageCopyPolicy.copyPayload(text: markdown), markdown,
                       "copy keeps Markdown and surrounding whitespace, exactly like 1:1")
    }

    func testCopyPayloadIsNilWhenThereIsNoVisibleText() {
        XCTAssertNil(MessageCopyPolicy.copyPayload(text: nil))
        XCTAssertNil(MessageCopyPolicy.copyPayload(text: ""))
        XCTAssertNil(MessageCopyPolicy.copyPayload(text: " \n\t "),
                     "whitespace-only rows offer no Copy Message item")
    }

    func testGroupCopyEligibilityFollowsMessageRowsWithText() {
        let user = entry("u", .message(isUser: true), "hello")
        let member = entry("m", .message(isUser: false), "hi there")
        let failed = entry("f", .failure, "Turn failed")
        let empty = entry("e", .message(isUser: false), "  ")

        XCTAssertEqual(MessageCopyPolicy.copyPayload(text: user.text), "hello")
        XCTAssertEqual(MessageCopyPolicy.copyPayload(text: member.text), "hi there")
        XCTAssertNil(MessageCopyPolicy.copyPayload(text: empty.text))
        XCTAssertFalse(RoomChatView.findSearchable([failed]).contains { $0.id == failed.id },
                       "failure chrome is not conversation text")
    }

    // MARK: - Find in Conversation over group rows

    func testFindSearchableKeepsMessagesAndDropsFailureAndEmptyRows() {
        let rows = [
            entry("u1", .message(isUser: true), "deploy the zebra"),
            entry("m1", .message(isUser: false), "the zebra is deployed"),
            entry("f1", .failure, "zebra turn failed"),
            entry("n1", .message(isUser: false), nil),
            entry("n2", .message(isUser: false), ""),
        ]
        XCTAssertEqual(RoomChatView.findSearchable(rows).map(\.id), ["u1", "m1"],
                       "only message rows are conversation content")
    }

    func testGroupFindIsCaseAndDiacriticInsensitiveWithOneMatchPerRow() {
        let rows = [
            entry("u1", .message(isUser: true), "Café closed, CAFE again"),
            entry("m1", .message(isUser: false), "no match here"),
            entry("m2", .message(isUser: false), "cafe?"),
        ]
        let matches = ConversationFindPolicy.matches(
            searchable: RoomChatView.findSearchable(rows), query: "CAFÉ")
        XCTAssertEqual(matches.map(\.rowID), ["u1", "m2"],
                       "first occurrence per row, in transcript order")
    }

    func testGroupFindCountsEveryMatchingRow() {
        let rows = [
            entry("m1", .message(isUser: false), "alpha beta"),
            entry("m2", .message(isUser: false), "beta gamma beta"),
            entry("m3", .message(isUser: false), "nothing"),
        ]
        let matches = ConversationFindPolicy.matches(
            searchable: RoomChatView.findSearchable(rows), query: "beta")
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches[0].snippet.contains("beta"))
        XCTAssertEqual(ConversationFindPolicy.positionText(index: 0, count: matches.count), "1 of 2")
    }

    func testGroupFindNavigationWrapsInBothDirections() {
        XCTAssertEqual(ConversationFindPolicy.nextIndex(current: 2, count: 3), 0,
                       "next wraps from the last match to the first")
        XCTAssertEqual(ConversationFindPolicy.previousIndex(current: 0, count: 3), 2,
                       "previous wraps from the first match to the last")
        XCTAssertEqual(ConversationFindPolicy.nextIndex(current: 0, count: 0), 0)
        XCTAssertEqual(ConversationFindPolicy.previousIndex(current: 0, count: 0), 0)
    }

    func testGroupFindBlankQueryMatchesNothing() {
        let rows = [entry("m1", .message(isUser: false), "anything")]
        XCTAssertTrue(ConversationFindPolicy.matches(
            searchable: RoomChatView.findSearchable(rows), query: "  ").isEmpty)
    }

    // MARK: - Retry availability (failure and outcome-unknown surfaces)

    func testRetryIsEnabledOnlyWhenCapableAndIdle() {
        XCTAssertTrue(RoomRetryAvailability.isEnabled(canRetry: true, isSending: false, isMutating: false))
    }

    func testRetryIsDisabledWithoutTheRetryCapability() {
        XCTAssertFalse(RoomRetryAvailability.isEnabled(canRetry: false, isSending: false, isMutating: false),
                       "a legacy or read-only room never offers a live retry")
    }

    func testRetryIsDisabledWhileSending() {
        XCTAssertFalse(RoomRetryAvailability.isEnabled(canRetry: true, isSending: true, isMutating: false),
                       "retry is disabled while a send is in flight, like 1:1 while streaming")
    }

    func testRetryIsDisabledWhileAnotherMutationIsInFlight() {
        XCTAssertFalse(RoomRetryAvailability.isEnabled(canRetry: true, isSending: false, isMutating: true))
    }
}