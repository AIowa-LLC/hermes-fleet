import XCTest
@testable import FleetCore

/// M5 conversation streaming domain: `ConversationEvent`, `ConversationSession`,
/// `PromptSubmission`, `InterruptResult`, `ConversationProviding` seam and
/// `ConversationError` — spec §31 Conversation + §5.5 tolerant decoding.
///
/// The wire→domain JSON extraction lives in the FleetNetworking client (it needs
/// `JSONValue`); FleetCore owns the pure vocabulary and the seam. This file tests
/// the domain values, their hashability/equality, and the error vocabulary only.
final class ConversationDomainTests: XCTestCase {

    // MARK: ConversationEvent — vocabulary + equality

    func testEventVocabularyEqualityAndHashable() {
        let a = ConversationEvent.messageStart(sessionID: "s1")
        let b = ConversationEvent.messageStart(sessionID: "s1")
        let c = ConversationEvent.messageStart(sessionID: "s2")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testMessageDeltaCarriesTextAndRendered() {
        let e = ConversationEvent.messageDelta(sessionID: "s1", text: "Hello", rendered: "<p>Hello</p>")
        guard case .messageDelta(let sid, let text, let rendered) = e else {
            return XCTFail("expected messageDelta")
        }
        XCTAssertEqual(sid, "s1")
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(rendered, "<p>Hello</p>")
    }

    func testMessageCompleteCarriesStatusAndError() {
        // Success path: text only. Failure path: text + status "error" + error.
        let ok = ConversationEvent.messageComplete(sessionID: "s1", text: "done", status: nil, error: nil)
        let failed = ConversationEvent.messageComplete(
            sessionID: "s1", text: "Error: boom", status: "error", error: "boom")
        guard case .messageComplete(_, let okText, let okStatus, let okError) = ok else {
            return XCTFail("expected messageComplete")
        }
        XCTAssertEqual(okText, "done")
        XCTAssertNil(okStatus)
        XCTAssertNil(okError)
        guard case .messageComplete(_, let fText, let fStatus, let fError) = failed else {
            return XCTFail("expected messageComplete")
        }
        XCTAssertEqual(fText, "Error: boom")
        XCTAssertEqual(fStatus, "error")
        XCTAssertEqual(fError, "boom")
    }

    func testThinkingReasoningAndStatusEvents() {
        let thinking = ConversationEvent.thinkingDelta(sessionID: "s1", text: "hmm")
        guard case .thinkingDelta(_, let t) = thinking else { return XCTFail() }
        XCTAssertEqual(t, "hmm")

        let reasoning = ConversationEvent.reasoningDelta(sessionID: "s1", text: "deep")
        guard case .reasoningDelta(_, let r) = reasoning else { return XCTFail() }
        XCTAssertEqual(r, "deep")

        let available = ConversationEvent.reasoningAvailable(sessionID: "s1", text: "ready")
        guard case .reasoningAvailable(_, let a) = available else { return XCTFail() }
        XCTAssertEqual(a, "ready")

        let status = ConversationEvent.statusUpdate(sessionID: "s1", kind: "process", text: "working…")
        guard case .statusUpdate(_, let kind, let text) = status else { return XCTFail() }
        XCTAssertEqual(kind, "process")
        XCTAssertEqual(text, "working…")
    }

    func testToolEventsCarryIdentityAndName() {
        let start = ConversationEvent.toolStart(sessionID: "s1", toolID: "t1", name: "web_search", context: "search(x)", argsText: nil)
        guard case .toolStart(_, let id, let name, let ctx, let args) = start else {
            return XCTFail("expected toolStart")
        }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(name, "web_search")
        XCTAssertEqual(ctx, "search(x)")
        XCTAssertNil(args)

        let generating = ConversationEvent.toolGenerating(sessionID: "s1", name: "read_file")
        guard case .toolGenerating(_, let gname) = generating else { return XCTFail() }
        XCTAssertEqual(gname, "read_file")

        let progress = ConversationEvent.toolProgress(sessionID: "s1", toolID: "t1", name: "web_search", text: "fetching…")
        guard case .toolProgress(_, let pid, let pname, let ptext) = progress else {
            return XCTFail("expected toolProgress")
        }
        XCTAssertEqual(pid, "t1")
        XCTAssertEqual(pname, "web_search")
        XCTAssertEqual(ptext, "fetching…")

        let complete = ConversationEvent.toolComplete(sessionID: "s1", toolID: "t1", name: "web_search", summary: "3 results")
        guard case .toolComplete(_, let cid, let cname, let summary) = complete else {
            return XCTFail("expected toolComplete")
        }
        XCTAssertEqual(cid, "t1")
        XCTAssertEqual(cname, "web_search")
        XCTAssertEqual(summary, "3 results")
    }

    func testBackgroundCompleteAndErrorEvents() {
        let bg = ConversationEvent.backgroundComplete(sessionID: "s1", taskID: "bg_1", text: "result")
        guard case .backgroundComplete(_, let taskID, let text) = bg else { return XCTFail() }
        XCTAssertEqual(taskID, "bg_1")
        XCTAssertEqual(text, "result")

        let err = ConversationEvent.error(sessionID: "s1", message: "turn failed")
        guard case .error(_, let message) = err else { return XCTFail() }
        XCTAssertEqual(message, "turn failed")
    }

    func testSessionInfoEventCarriesKeyFields() {
        let info = ConversationEvent.sessionInfo(
            sessionID: "s1", model: "deepseek-v4-flash", provider: "nous",
            title: "Research", cwd: "/Users/t", profileName: "default")
        guard case .sessionInfo(_, let model, let provider, let title, let cwd, let profile) = info else {
            return XCTFail("expected sessionInfo")
        }
        XCTAssertEqual(model, "deepseek-v4-flash")
        XCTAssertEqual(provider, "nous")
        XCTAssertEqual(title, "Research")
        XCTAssertEqual(cwd, "/Users/t")
        XCTAssertEqual(profile, "default")
    }

    func testUnknownEventIsPreserved() {
        // spec §5.5: an unknown event type must be preserved, never fatal.
        let unknown = ConversationEvent.unknown(sessionID: "s1", rawType: "moa.reference")
        guard case .unknown(_, let raw) = unknown else { return XCTFail("expected unknown") }
        XCTAssertEqual(raw, "moa.reference")
    }

    // MARK: ConversationSession

    func testConversationSessionValue() {
        let messages = [
            SessionMessage(role: .user, text: "hi"),
            SessionMessage(role: .assistant, text: "hello!"),
        ]
        let session = ConversationSession(
            sessionID: "abc12345",
            storedSessionID: "k-1",
            messageCount: 2,
            messages: messages,
            model: "deepseek-v4-flash",
            provider: "nous",
            profileName: nil
        )
        XCTAssertEqual(session.sessionID, "abc12345")
        XCTAssertEqual(session.storedSessionID, "k-1")
        XCTAssertEqual(session.messageCount, 2)
        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(session.model, "deepseek-v4-flash")
        XCTAssertEqual(session.provider, "nous")
        XCTAssertNil(session.profileName)
    }

    func testConversationSessionHashable() {
        let a = ConversationSession(sessionID: "s", storedSessionID: nil, messageCount: 0, messages: [], model: nil, provider: nil, profileName: nil)
        let b = ConversationSession(sessionID: "s", storedSessionID: nil, messageCount: 0, messages: [], model: nil, provider: nil, profileName: nil)
        let c = ConversationSession(sessionID: "s2", storedSessionID: nil, messageCount: 0, messages: [], model: nil, provider: nil, profileName: nil)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: PromptSubmission

    func testPromptSubmissionStreaming() {
        let s = PromptSubmission(status: "streaming")
        XCTAssertEqual(s.status, "streaming")
        XCTAssertTrue(s.isStreaming)
    }

    // MARK: InterruptResult

    func testInterruptResult() {
        let plain = InterruptResult(status: "interrupted", turnIsolation: nil)
        XCTAssertEqual(plain.status, "interrupted")
        XCTAssertNil(plain.turnIsolation)

        let computeHost = InterruptResult(status: "interrupted", turnIsolation: true)
        XCTAssertEqual(computeHost.turnIsolation, true)
    }

    // MARK: ConversationError

    func testConversationErrorLocalizedAndEquatable() {
        XCTAssertEqual(ConversationError.notConnected, .notConnected)
        XCTAssertNotEqual(ConversationError.notConnected, .sessionNotFound("s"))
        XCTAssertEqual(ConversationError.notConnected.errorDescription, "gateway not connected")
        XCTAssertTrue((ConversationError.sessionNotFound("s1").errorDescription ?? "").contains("s1"))
        XCTAssertTrue((ConversationError.rpcFailed("boom").errorDescription ?? "").contains("boom"))
        XCTAssertTrue((ConversationError.invalidRequest("session_id required").errorDescription ?? "").contains("session_id"))
    }
}
