import XCTest
@testable import FleetCore

/// P0.1: the server→client request vocabulary in FleetCore — method support
/// set, event accessors, the approval legacy/server-request routing default,
/// and the fail-closed seam.
final class ServerRequestsDomainTests: XCTestCase {

    func testSupportedMethodsAreExactlyTheFourFleetCanAnswer() {
        XCTAssertEqual(ServerRequestMethod.supported, ["approval", "clarify", "sudo", "secret"])
        // Everything else must be refused with -32601 by the transport.
        for unsupported in ["preview.act", "preview.read", "terminal.read", "window.read",
                            "tour", "vault.code", "vault.save_login", "vault.unlock_prompt", "connection"] {
            XCTAssertFalse(ServerRequestMethod.supported.contains(unsupported), unsupported)
        }
    }

    func testKindMethodNamesMatchTheWire() {
        let approval = ApprovalRequest(requestID: "r", sessionID: "s", command: "c")
        XCTAssertEqual(ServerRequestKind.approval(approval).method, "approval")
        XCTAssertEqual(ServerRequestKind.clarify(ClarifyPrompt(sessionID: "s", questions: [], isBatch: false)).method, "clarify")
        XCTAssertEqual(ServerRequestKind.sudo(SudoPrompt(sessionID: "s", command: "c")).method, "sudo")
        XCTAssertEqual(ServerRequestKind.secret(SecretPrompt(sessionID: "s", envVar: "E", prompt: "p")).method, "secret")
    }

    func testMultiSelectRequiresChoices() {
        XCTAssertFalse(ClarifyQuestion(qid: "q", question: "?", choices: [], multiSelect: true).multiSelect)
        XCTAssertTrue(ClarifyQuestion(qid: "q", question: "?", choices: ["a"], multiSelect: true).multiSelect)
    }

    func testMultiSelectAnswerEncodesAsJSONArray() throws {
        XCTAssertEqual(ClarifyAnswerEncoding.multiSelect(["a", "b"]), #"["a","b"]"#)
        XCTAssertEqual(ClarifyAnswerEncoding.multiSelect([]), "[]")
        let tricky = ClarifyAnswerEncoding.multiSelect([#"say "hi""#, "x,y"])
        let decoded = try JSONSerialization.jsonObject(with: Data(tricky.utf8)) as? [String]
        XCTAssertEqual(decoded, [#"say "hi""#, "x,y"], "labels containing quotes or commas survive the round trip")
    }

    func testApprovalRequestServerRequestIDDefaultsToNilAndParticipatesInEquality() {
        let legacy = ApprovalRequest(requestID: "r", sessionID: "s", command: "c")
        XCTAssertNil(legacy.serverRequestID)
        let served = ApprovalRequest(requestID: "r", sessionID: "s", command: "c", serverRequestID: "srq-1")
        XCTAssertEqual(served.serverRequestID, "srq-1")
        XCTAssertNotEqual(legacy, served)
    }

    func testEventAccessorsForServerRequestAndCancel() {
        let request = ServerRequest(
            id: "srq-1", sessionID: "s1",
            kind: .sudo(SudoPrompt(sessionID: "s1", command: "true")))
        let asked = ConversationEvent.serverRequest(request)
        XCTAssertEqual(asked.sessionID, "s1")
        XCTAssertNil(asked.seq, "a request frame is not a replay-ring event")
        XCTAssertFalse(asked.isTurnTerminal)

        let cancelled = ConversationEvent.requestCancelled(
            sessionID: "s1", requestID: "srq-1", method: "sudo", reason: "timeout", seq: 12)
        XCTAssertEqual(cancelled.sessionID, "s1")
        XCTAssertEqual(cancelled.seq, 12)
        XCTAssertFalse(cancelled.isTurnTerminal, "a withdrawal never ends the turn")
    }

    func testRequestCancelParticipatesInEventContinuity() {
        let cursor = ConversationEventCursor(sessionID: "s1", lastEventID: 4)
        let next = ConversationEvent.requestCancelled(
            sessionID: "s1", requestID: "srq-1", method: "approval", reason: "timeout", seq: 5)
        XCTAssertEqual(cursor.classify(next), .contiguous)
        let request = ConversationEvent.serverRequest(ServerRequest(
            id: "srq-1", sessionID: "s1", kind: .sudo(SudoPrompt(sessionID: "s1", command: "true"))))
        XCTAssertEqual(cursor.classify(request), .unknown)
    }

    // MARK: approval routing default

    private final class RecordingApprovals: ApprovalsProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _legacy: [String] = []
        var legacyRequestIDs: [String] { lock.lock(); defer { lock.unlock() }; return _legacy }
        private func record(_ requestID: String) {
            lock.lock(); defer { lock.unlock() }
            _legacy.append(requestID)
        }
        func respond(sessionID: String, requestID: String, choice: ApprovalChoice, all: Bool) async throws -> Int {
            record(requestID)
            return 1
        }
        func setSessionYolo(_ enabled: Bool, sessionID: String) async throws -> Bool { enabled }
        func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] { [] }
    }

    func testDefaultRespondToUsesTheLegacyApprovalRespondPath() async throws {
        let approvals = RecordingApprovals()
        let request = ApprovalRequest(requestID: "req-1", sessionID: "s", command: "c", serverRequestID: "srq-1")
        let resolved = try await approvals.respond(to: request, choice: .once, all: false)
        XCTAssertEqual(resolved, 1)
        XCTAssertEqual(approvals.legacyRequestIDs, ["req-1"])
    }

    // MARK: fail-closed seams

    func testUnsupportedServerPromptsFailClosed() async {
        let seam = UnsupportedServerPrompts()
        do { try await seam.answerClarify(requestID: "r", answer: "a"); XCTFail() } catch {
            XCTAssertEqual(error as? ConversationError, .notConnected)
        }
        do { _ = try await seam.lockClarifyAnswer(requestID: "r", questionID: "q", answer: "a"); XCTFail() } catch {
            XCTAssertEqual(error as? ConversationError, .notConnected)
        }
        do { try await seam.cancelClarify(requestID: "r"); XCTFail() } catch {
            XCTAssertEqual(error as? ConversationError, .notConnected)
        }
        do { try await seam.answerValue(requestID: "r", value: ""); XCTFail() } catch {
            XCTAssertEqual(error as? ConversationError, .notConnected)
        }
    }
}
