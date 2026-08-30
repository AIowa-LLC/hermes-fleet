import XCTest
@testable import FleetCore

/// M4 session READ path domain: `SessionMessageRole`, `SessionMessage`,
/// `SessionHistory`, `SessionStatus` — spec §31 Sessions + §5.4
/// (observation never implies ownership) + §5.5 tolerant decoding.
final class SessionReadDomainTests: XCTestCase {

    // MARK: SessionMessageRole

    func testRoleVocabularyAndTolerantDecode() {
        // The upstream `_history_to_messages` projection emits user/assistant/
        // tool/system (server.py:9306-9308); anything else must decode to
        // `.unknown` without crashing (spec §5.5).
        XCTAssertEqual(SessionMessageRole(wire: "user"), .user)
        XCTAssertEqual(SessionMessageRole(wire: "assistant"), .assistant)
        XCTAssertEqual(SessionMessageRole(wire: "tool"), .tool)
        XCTAssertEqual(SessionMessageRole(wire: "system"), .system)
        XCTAssertEqual(SessionMessageRole(wire: "developer"), .unknown)
        XCTAssertEqual(SessionMessageRole(wire: ""), .unknown)
        // Round-trip wire value.
        XCTAssertEqual(SessionMessageRole(wire: "unknown").wireValue, "unknown")
        XCTAssertEqual(SessionMessageRole(wire: "user").wireValue, "user")
    }

    // MARK: SessionMessage

    func testMessageContentDetection() {
        let withText = SessionMessage(role: .user, text: "hello")
        XCTAssertTrue(withText.hasContent)

        // Reasoning-only assistant turns are kept (server.py #44022) so the
        // "Thinking…" block can render.
        let reasoningOnly = SessionMessage(role: .assistant, text: "", reasoning: "deep thinking")
        XCTAssertTrue(reasoningOnly.hasContent)

        let empty = SessionMessage(role: .system, text: "", reasoning: nil)
        XCTAssertFalse(empty.hasContent)
    }

    func testMessageIdentityPrefersRowID() {
        let a = SessionMessage(role: .user, text: "hi", timestamp: 100, rowID: "42")
        let b = SessionMessage(role: .user, text: "different", timestamp: 100, rowID: "42")
        XCTAssertEqual(a.id, b.id, "row_id is the durable identity")

        let noRowA = SessionMessage(role: .user, text: "hi", timestamp: 100, rowID: nil)
        let noRowB = SessionMessage(role: .user, text: "hi", timestamp: 100, rowID: nil)
        XCTAssertNotEqual(a.id, noRowA.id, "row_id and synthesized id never collide")
        // B1: the synthesized id is a launch-stable UUID minted per message —
        // never a randomized hash — so duplicate-text messages keep distinct ids.
        XCTAssertNotEqual(noRowA.id, noRowB.id, "duplicate-text messages keep distinct ids")
    }

    // MARK: B1 — launch-stable message identity (no hashValue fallback)

    func testDuplicateTextMessagesKeepDistinctIDs() {
        // Two independently-constructed messages with identical content and no
        // row_id must NOT collide on id. On the pre-B1 code the fallback was
        // `text.hashValue` — same content → same id → collision.
        let a = SessionMessage(role: .user, text: "same text", timestamp: 100, rowID: nil)
        let b = SessionMessage(role: .user, text: "same text", timestamp: 100, rowID: nil)
        XCTAssertNotEqual(a.id, b.id, "duplicate-text messages keep distinct ids")
    }

    func testSynthesizedIDIsLaunchStableUUID() {
        // The synthesized id must be a launch-stable UUID minted at message
        // construction — never a per-launch-randomized hashValue (B1).
        let noRow = SessionMessage(role: .assistant, text: "thinking out loud", timestamp: nil, rowID: nil)
        XCTAssertNotNil(UUID(uuidString: noRow.id), "synthesized id is a UUID, not a hash-derived string")
    }

    func testMessageToolFields() {
        let tool = SessionMessage(
            role: .tool, text: "", timestamp: 5, rowID: "7",
            toolName: "web_search", toolContext: "search(\"hermes\")")
        XCTAssertEqual(tool.toolName, "web_search")
        XCTAssertEqual(tool.toolContext, "search(\"hermes\")")
        XCTAssertTrue(tool.hasContent)
    }

    // MARK: SessionHistory

    func testSessionHistoryValue() {
        let history = SessionHistory(
            sessionID: "sess-1",
            count: 2,
            messages: [
                SessionMessage(role: .user, text: "hi"),
                SessionMessage(role: .assistant, text: "hello!"),
            ]
        )
        XCTAssertEqual(history.sessionID, "sess-1")
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.messages.count, 2)
        XCTAssertFalse(history.isEmpty)
        XCTAssertTrue(SessionHistory(sessionID: "x", count: 0, messages: []).isEmpty)
    }

    func testSessionHistoryHashable() {
        let a = SessionHistory(sessionID: "s", count: 1, messages: [SessionMessage(role: .user, text: "x")])
        let b = SessionHistory(sessionID: "s", count: 1, messages: [SessionMessage(role: .user, text: "x")])
        let c = SessionHistory(sessionID: "s", count: 1, messages: [SessionMessage(role: .user, text: "y")])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: SessionStatus — the gateway returns a text block; §5.5 tolerant parse

    func testStatusParseTypicalOutput() {
        let output = """
        Hermes TUI Status

        Session ID: sess-abc
        Path: /Users/t/.hermes
        Title: Research plans
        Model: deepseek-v4-flash (nous)
        Created: 2026-08-29 12:00
        Last Activity: 2026-08-29 12:30
        Tokens: 12,345
        Agent Running: Yes
        """
        let status = SessionStatus.parse(output: output)
        XCTAssertEqual(status.sessionID, "sess-abc")
        XCTAssertEqual(status.title, "Research plans")
        XCTAssertEqual(status.model, "deepseek-v4-flash")
        XCTAssertEqual(status.provider, "nous")
        XCTAssertEqual(status.agentRunning, true)
        // Raw output is preserved verbatim for a faithful renderer.
        XCTAssertEqual(status.rawOutput, output)
    }

    func testStatusParseNoRunning() {
        let output = """
        Hermes TUI Status

        Session ID: s1
        Model: gpt-5 (openai)
        Agent Running: No
        """
        let status = SessionStatus.parse(output: output)
        XCTAssertEqual(status.sessionID, "s1")
        XCTAssertEqual(status.model, "gpt-5")
        XCTAssertEqual(status.provider, "openai")
        XCTAssertEqual(status.agentRunning, false)
    }

    func testStatusParseMissingFieldsFallsBackToNil() {
        // A gateway whose status block omits/changes lines must not fail:
        // every field is best-effort (spec §5.5).
        let status = SessionStatus.parse(output: "Hermes TUI Status\n")
        XCTAssertNil(status.sessionID)
        XCTAssertNil(status.model)
        XCTAssertNil(status.provider)
        XCTAssertNil(status.title)
        XCTAssertNil(status.agentRunning)
        XCTAssertEqual(status.rawOutput, "Hermes TUI Status\n")
    }

    func testStatusParseModelWithoutProvider() {
        let status = SessionStatus.parse(output: "Model: my-custom-model\n")
        XCTAssertEqual(status.model, "my-custom-model")
        XCTAssertNil(status.provider)
    }

    // MARK: SessionHistoryError — read-path error vocabulary

    func testSessionHistoryErrorLocalizedAndEquatable() {
        XCTAssertEqual(SessionHistoryError.notConnected, .notConnected)
        XCTAssertNotEqual(SessionHistoryError.notConnected, .sessionNotFound("s"))
        XCTAssertEqual(SessionHistoryError.notConnected.errorDescription, "gateway not connected")
        XCTAssertTrue((SessionHistoryError.sessionNotFound("s1").errorDescription ?? "").contains("s1"))
        XCTAssertTrue((SessionHistoryError.rpcFailed("boom").errorDescription ?? "").contains("boom"))
    }
}
