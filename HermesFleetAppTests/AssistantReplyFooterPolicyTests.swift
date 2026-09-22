import XCTest
import FleetCore
@testable import FleetUI

/// Stage 1 — assistant-reply footer policy unit tests (pure logic, no UI).
/// The policy is the ONE gate both surfaces (1:1 conversation rows and
/// bridged-group transcript entries) render from, so these invariants pin
/// the footer can never appear on streaming, failed, empty, or non-assistant
/// content — and that the action payload is the literal reply text only.
@MainActor
final class AssistantReplyFooterPolicyTests: XCTestCase {

    // MARK: - 1:1 conversation rows

    func testCompletedAssistantRowShowsFooter() {
        XCTAssertTrue(AssistantReplyFooterPolicy.showsFooter(
            kind: .assistant, text: "Here is the answer.", isStreaming: false, isFailed: false))
    }

    func testStreamingAssistantRowHidesFooter() {
        XCTAssertFalse(AssistantReplyFooterPolicy.showsFooter(
            kind: .assistant, text: "partial…", isStreaming: true, isFailed: false))
    }

    func testFailedAssistantRowHidesFooter() {
        XCTAssertFalse(AssistantReplyFooterPolicy.showsFooter(
            kind: .assistant, text: "Turn failed", isStreaming: false, isFailed: true))
    }

    func testEmptyAssistantRowHidesFooter() {
        XCTAssertFalse(AssistantReplyFooterPolicy.showsFooter(
            kind: .assistant, text: "   \n  ", isStreaming: false, isFailed: false))
        XCTAssertFalse(AssistantReplyFooterPolicy.showsFooter(
            kind: .assistant, text: "", isStreaming: false, isFailed: false))
    }

    func testUserToolStatusRowsHideFooter() {
        XCTAssertFalse(AssistantReplyFooterPolicy.showsFooter(
            kind: .user, text: "a user row", isStreaming: false, isFailed: false))
        XCTAssertFalse(AssistantReplyFooterPolicy.showsFooter(
            kind: .tool, text: "terminal", isStreaming: false, isFailed: false))
        XCTAssertFalse(AssistantReplyFooterPolicy.showsFooter(
            kind: .status, text: "connected", isStreaming: false, isFailed: false))
    }

    // MARK: - Bridged-group transcript entries

    func testMemberMessageEntryShowsFooter() {
        XCTAssertTrue(AssistantReplyFooterPolicy.showsFooter(
            roomFlavor: .message(isUser: false), text: "Draft is ready for review."))
    }

    func testUserRoomEntryHidesFooter() {
        XCTAssertFalse(AssistantReplyFooterPolicy.showsFooter(
            roomFlavor: .message(isUser: true), text: "please review"))
    }

    func testFailureRoomEntryHidesFooter() {
        XCTAssertFalse(AssistantReplyFooterPolicy.showsFooter(
            roomFlavor: .failure, text: "Provider rejected the request (auth)."))
    }

    func testEmptyMemberEntryHidesFooter() {
        XCTAssertFalse(AssistantReplyFooterPolicy.showsFooter(
            roomFlavor: .message(isUser: false), text: "   "))
        XCTAssertFalse(AssistantReplyFooterPolicy.showsFooter(
            roomFlavor: .message(isUser: false), text: nil))
    }

    // MARK: - Payload

    func testActionableTextIsLiteralReplyText() {
        XCTAssertEqual(
            AssistantReplyFooterPolicy.actionableText("  padded reply  "),
            "  padded reply  ",
            "the action payload is the literal text — trimmed for emptiness only, never normalized")
        XCTAssertNil(AssistantReplyFooterPolicy.actionableText(" \n\t "))
        XCTAssertNil(AssistantReplyFooterPolicy.actionableText(nil))
    }

    // MARK: - Advanced action availability

    func testBranchCountStopsAtSelectedAssistantAndIncludesVisiblePrefix() {
        let rows = [
            ConversationRow(id: "u1", kind: .user, text: "first"),
            ConversationRow(id: "a1", kind: .assistant, text: "answer one"),
            ConversationRow(id: "u2", kind: .user, text: "later"),
            ConversationRow(id: "a2", kind: .assistant, text: "answer two"),
        ]
        XCTAssertEqual(
            AssistantReplyActionPolicy.branchMessageCount(rows: rows, selectedRowID: "a1"),
            2,
            "session.branch count must exclude later turns")
        XCTAssertEqual(
            AssistantReplyActionPolicy.branchMessageCount(rows: rows, selectedRowID: "a2"),
            4)
    }

    func testRetryIsLatestCompletedReplyOnly() {
        let rows = [
            ConversationRow(id: "u1", kind: .user, text: "first"),
            ConversationRow(id: "a1", kind: .assistant, text: "answer one"),
            ConversationRow(id: "u2", kind: .user, text: "later"),
            ConversationRow(id: "a2", kind: .assistant, text: "answer two"),
        ]
        XCTAssertFalse(AssistantReplyActionPolicy.canRetry(rows: rows, selectedRowID: "a1", isStreaming: false))
        XCTAssertTrue(AssistantReplyActionPolicy.canRetry(rows: rows, selectedRowID: "a2", isStreaming: false))
        XCTAssertFalse(AssistantReplyActionPolicy.canRetry(rows: rows, selectedRowID: "a2", isStreaming: true))
    }
}
