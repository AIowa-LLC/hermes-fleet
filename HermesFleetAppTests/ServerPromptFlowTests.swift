import XCTest
import FleetCore
import FleetUI
@testable import HermesFleetApp

/// P0.1 — clarify / sudo / secret prompts and server-request approvals:
/// Face ID gating, friction-free skip, `request.cancel` = dismiss-only (never a
/// denial or an answer), dedupe/replay merging, and the "typed value is never
/// retained" guarantee. Scripted seams only: no network, no simulator server.
@MainActor
final class ServerPromptFlowTests: XCTestCase {

    // MARK: - Scripted seams

    private final class ScriptedPrompts: ServerPromptResponding, @unchecked Sendable {
        enum Call: Equatable {
            case answerClarify(requestID: String, answer: String)
            case lock(requestID: String, questionID: String, answer: String)
            case cancelClarify(requestID: String)
            case value(requestID: String, value: String)
        }
        private let lock = NSLock()
        private var _calls: [Call] = []
        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        var failure: Error?
        var lockStatuses: [ClarifyLockStatus] = []

        private func record(_ call: Call) {
            lock.lock(); defer { lock.unlock() }
            _calls.append(call)
        }
        private func nextLockStatus() -> ClarifyLockStatus {
            lock.lock(); defer { lock.unlock() }
            return lockStatuses.isEmpty ? .locked(remaining: []) : lockStatuses.removeFirst()
        }

        func answerClarify(requestID: String, answer: String) async throws {
            record(.answerClarify(requestID: requestID, answer: answer))
            if let failure { throw failure }
        }
        func lockClarifyAnswer(requestID: String, questionID: String, answer: String) async throws -> ClarifyLockStatus {
            record(.lock(requestID: requestID, questionID: questionID, answer: answer))
            if let failure { throw failure }
            return nextLockStatus()
        }
        func cancelClarify(requestID: String) async throws {
            record(.cancelClarify(requestID: requestID))
            if let failure { throw failure }
        }
        func answerValue(requestID: String, value: String) async throws {
            record(.value(requestID: requestID, value: value))
            if let failure { throw failure }
        }
    }

    private struct ScriptedBiometrics: AppLockBiometricAuth {
        let result: AppLockAuthResult
        func canEvaluateBiometrics() -> Bool { result != .unavailable }
        func evaluateBiometrics(reason: String) async -> AppLockAuthResult { result }
        func evaluateDevicePasscode(reason: String) async -> Bool { false }
    }

    /// Approvals double that records which wire path a decision took.
    private final class ScriptedApprovals: ApprovalsProviding, @unchecked Sendable {
        enum Path: Equatable {
            case legacy(requestID: String, choice: ApprovalChoice)
            case serverRequest(id: String, choice: ApprovalChoice)
        }
        private let lock = NSLock()
        private var _paths: [Path] = []
        var paths: [Path] {
            lock.lock(); defer { lock.unlock() }
            return _paths
        }
        private func record(_ path: Path) {
            lock.lock(); defer { lock.unlock() }
            _paths.append(path)
        }
        func respond(sessionID: String, requestID: String, choice: ApprovalChoice, all: Bool) async throws -> Int {
            record(.legacy(requestID: requestID, choice: choice))
            return 1
        }
        func respond(to request: ApprovalRequest, choice: ApprovalChoice, all: Bool) async throws -> Int {
            if let id = request.serverRequestID {
                record(.serverRequest(id: id, choice: choice))
                return 1
            }
            return try await respond(
                sessionID: request.sessionID, requestID: request.requestID, choice: choice, all: all)
        }
        func setSessionYolo(_ enabled: Bool, sessionID: String) async throws -> Bool { enabled }
        func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] { [] }
    }

    // MARK: - Fixtures

    private func makePrompts(
        biometrics: AppLockAuthResult = .success
    ) -> (ScriptedPrompts, ServerPromptViewModel) {
        let prompts = ScriptedPrompts()
        let model = ServerPromptViewModel(prompts: prompts, biometrics: ScriptedBiometrics(result: biometrics))
        model.bind(sessionID: "s-1")
        return (prompts, model)
    }

    private func single(id: String = "srq-c1", choices: [String] = ["main", "dev"]) -> ServerRequest {
        ServerRequest(
            id: id, sessionID: "s-1",
            kind: .clarify(ClarifyPrompt(
                sessionID: "s-1",
                questions: [ClarifyQuestion(qid: "", question: "Which branch?", choices: choices)],
                isBatch: false)))
    }

    private func batch(id: String = "srq-b1", locked: [String: String] = [:]) -> ServerRequest {
        ServerRequest(
            id: id, sessionID: "s-1",
            kind: .clarify(ClarifyPrompt(
                sessionID: "s-1",
                questions: [
                    ClarifyQuestion(qid: "q1", question: "First?", choices: ["a", "b"]),
                    ClarifyQuestion(qid: "q2", question: "Second?"),
                ],
                isBatch: true,
                lockedAnswers: locked)),
            replayed: !locked.isEmpty)
    }

    private func secret(id: String = "srq-s1") -> ServerRequest {
        ServerRequest(
            id: id, sessionID: "s-1",
            kind: .secret(SecretPrompt(sessionID: "s-1", envVar: "FIXTURE_TOKEN", prompt: "Token?")))
    }

    private func sudo(id: String = "srq-u1", command: String = "sudo true") -> ServerRequest {
        ServerRequest(
            id: id, sessionID: "s-1", kind: .sudo(SudoPrompt(sessionID: "s-1", command: command)))
    }

    // MARK: - Intake

    func testIgnoresOtherSessionsAndApprovalRequests() {
        let (_, model) = makePrompts()
        model.handle(ServerRequest(
            id: "srq-x", sessionID: "s-other",
            kind: .sudo(SudoPrompt(sessionID: "s-other", command: "true"))))
        XCTAssertNil(model.pending)
        model.handle(ServerRequest(
            id: "srq-a", sessionID: "s-1",
            kind: .approval(ApprovalRequest(requestID: "r", sessionID: "s-1", command: "c", serverRequestID: "srq-a"))))
        XCTAssertNil(model.pending, "approvals belong to ApprovalViewModel")
    }

    func testSecondRequestQueuesAndIsPromotedWithFreshLock() async {
        let (_, model) = makePrompts()
        model.handle(secret())
        model.handle(sudo())
        XCTAssertEqual(model.pending?.id, "srq-s1")
        XCTAssertEqual(model.queued.map(\.id), ["srq-u1"])
        await model.unlockInput()
        XCTAssertTrue(model.isInputUnlocked)

        await model.skipValue()

        XCTAssertEqual(model.pending?.id, "srq-u1")
        XCTAssertFalse(model.isInputUnlocked, "an unlock never carries over to the next request")
    }

    func testRedeliveryOfTheSameRequestNeverRendersASecondCard() {
        let (_, model) = makePrompts()
        model.handle(single())
        model.handle(single())
        XCTAssertEqual(model.pending?.id, "srq-c1")
        XCTAssertTrue(model.queued.isEmpty)
    }

    func testSudoCommandIsRedactedClientSide() {
        let (_, model) = makePrompts()
        let bearer = ["fixture", "bearer", "abc123"].joined(separator: "-")
        model.handle(sudo(command: "curl -H 'Authorization: Bearer \(bearer)' https://api.example.invalid"))
        guard case .sudo(let prompt)? = model.pending?.kind else { return XCTFail("expected sudo") }
        XCTAssertFalse(prompt.command.contains(bearer))
        XCTAssertTrue(prompt.command.contains("[REDACTED]"))
    }

    // MARK: - Clarify

    func testSingleClarifyAnswerIsSentAndDismisses() async {
        let (prompts, model) = makePrompts()
        model.handle(single())

        await model.answerClarify("dev")

        XCTAssertEqual(prompts.calls, [.answerClarify(requestID: "srq-c1", answer: "dev")])
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.state, .idle)
    }

    func testFailedAnswerKeepsThePromptAndSurfacesANonSecretError() async {
        let (prompts, model) = makePrompts()
        prompts.failure = ConversationError.notConnected
        model.handle(single())

        await model.answerClarify("dev")

        XCTAssertEqual(model.pending?.id, "srq-c1", "a failed answer must not look like success")
        guard case .failed(let message) = model.state else { return XCTFail("expected failed state") }
        XCTAssertFalse(message.isEmpty)
    }

    func testSkippingClarifyIsOneTap() async {
        let (prompts, model) = makePrompts(biometrics: .failure)
        model.handle(single())
        await model.skipClarify()
        XCTAssertEqual(prompts.calls, [.answerClarify(requestID: "srq-c1", answer: "")])
        XCTAssertNil(model.pending)

        model.handle(batch())
        await model.skipClarify()
        XCTAssertEqual(prompts.calls.last, .cancelClarify(requestID: "srq-b1"), "batch skip is cancel-all")
        XCTAssertNil(model.pending)
    }

    func testBatchLocksAccumulateAndTheLastLockDismisses() async {
        let (prompts, model) = makePrompts()
        prompts.lockStatuses = [.locked(remaining: ["q2"]), .locked(remaining: [])]
        model.handle(batch())

        await model.lockClarify(questionID: "q1", answer: "b")
        XCTAssertEqual(model.pending?.id, "srq-b1")
        XCTAssertEqual(model.lockedAnswers, ["q1": "b"])
        XCTAssertEqual(model.state, .pending)

        await model.lockClarify(questionID: "q2", answer: "free text")
        XCTAssertNil(model.pending, "the last lock resolves the request")
        XCTAssertEqual(prompts.calls, [
            .lock(requestID: "srq-b1", questionID: "q1", answer: "b"),
            .lock(requestID: "srq-b1", questionID: "q2", answer: "free text"),
        ])
    }

    func testLockOfAnUnknownQuestionIsRefused() async {
        let (prompts, model) = makePrompts()
        model.handle(batch())
        await model.lockClarify(questionID: "nope", answer: "x")
        XCTAssertTrue(prompts.calls.isEmpty)
    }

    func testExpiredLockDismissesWithoutAnError() async {
        let (prompts, model) = makePrompts()
        prompts.lockStatuses = [.expired]
        model.handle(batch())
        await model.lockClarify(questionID: "q1", answer: "a")
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.state, .idle)
    }

    func testReplayedBatchRestoresLockedAnswers() {
        let (_, model) = makePrompts()
        model.handle(batch(locked: ["q1": "a"]))
        XCTAssertEqual(model.lockedAnswers, ["q1": "a"])
        // A later re-delivery with more locks merges into the open card.
        model.handle(batch(locked: ["q1": "a", "q2": "z"]))
        XCTAssertEqual(model.lockedAnswers, ["q1": "a", "q2": "z"])
        XCTAssertEqual(model.pending?.id, "srq-b1")
    }

    // MARK: - sudo / secret: Face ID gate

    func testEntryIsRefusedUntilFaceIDSucceeds() async {
        let (prompts, model) = makePrompts()
        model.handle(secret())
        XCTAssertFalse(model.isInputUnlocked)

        await model.submitValue("typed-before-unlock")

        XCTAssertTrue(prompts.calls.isEmpty, "nothing is sent before the Face ID gate")
        XCTAssertNotNil(model.pending)
    }

    func testFailedOrUnavailableFaceIDSendsNothingAndKeepsInputHidden() async {
        for result in [AppLockAuthResult.failure, .unavailable] {
            let (prompts, model) = makePrompts(biometrics: result)
            model.handle(sudo())
            await model.unlockInput()
            XCTAssertFalse(model.isInputUnlocked)
            // P0.2b: unavailable biometrics fall back to the passcode, which
            // the scripted provider fails: still blocked, never silent.
            XCTAssertEqual(model.state, .biometricFailed)
            await model.submitValue("typed-anyway")
            XCTAssertTrue(prompts.calls.isEmpty)
            XCTAssertNotNil(model.pending, "the request stays open")
        }
    }

    func testUnlockedEntryIsSentAsTheValueAndDismisses() async {
        let (prompts, model) = makePrompts()
        model.handle(secret())
        await model.unlockInput()
        XCTAssertTrue(model.isInputUnlocked)

        let fixtureValue = ["fixture", "entry", "value"].joined(separator: "-")
        await model.submitValue(fixtureValue)

        XCTAssertEqual(prompts.calls, [.value(requestID: "srq-s1", value: fixtureValue)])
        XCTAssertNil(model.pending)
        XCTAssertFalse(model.isInputUnlocked)
    }

    func testEmptyEntryIsNotSentAsASubmission() async {
        let (prompts, model) = makePrompts()
        model.handle(secret())
        await model.unlockInput()
        await model.submitValue("")
        XCTAssertTrue(prompts.calls.isEmpty, "declining is the explicit Decline action")
    }

    func testDecliningIsFrictionFreeEvenWhenFaceIDWouldFail() async {
        let (prompts, model) = makePrompts(biometrics: .failure)
        model.handle(secret())
        await model.skipValue()
        XCTAssertEqual(prompts.calls, [.value(requestID: "srq-s1", value: "")])
        XCTAssertNil(model.pending)
    }

    /// A seam that keeps nothing, so a reflection of the view model can only
    /// find the value if the MODEL retained it.
    private struct DiscardingPrompts: ServerPromptResponding {
        var fail = false
        func answerClarify(requestID: String, answer: String) async throws {}
        func lockClarifyAnswer(requestID: String, questionID: String, answer: String) async throws -> ClarifyLockStatus {
            .locked(remaining: [])
        }
        func cancelClarify(requestID: String) async throws {}
        func answerValue(requestID: String, value: String) async throws {
            if fail { throw ConversationError.notConnected }
        }
    }

    /// "Never cached / persisted": after a submit — successful or failed — the
    /// typed value is not reachable from any stored property or state of the
    /// view model.
    func testTypedValueIsNeverRetainedByTheViewModel() async {
        let fixtureValue = ["fixture", "retention", "probe"].joined(separator: "-")

        for fail in [false, true] {
            let model = ServerPromptViewModel(
                prompts: DiscardingPrompts(fail: fail), biometrics: ScriptedBiometrics(result: .success))
            model.bind(sessionID: "s-1")
            model.handle(secret())
            await model.unlockInput()
            await model.submitValue(fixtureValue)

            XCTAssertFalse(String(reflecting: model).contains(fixtureValue))
            XCTAssertFalse(dumped(model).contains(fixtureValue), "fail=\(fail)")
            if fail {
                guard case .failed(let message) = model.state else { return XCTFail("expected failed state") }
                XCTAssertFalse(message.contains(fixtureValue), "an error never echoes the value")
            }
        }
    }

    private func dumped(_ subject: Any) -> String {
        var text = ""
        dump(subject, to: &text)
        return text
    }

    // MARK: - request.cancel

    func testCancelDismissesEveryKindWithoutSendingAnything() async {
        let (prompts, model) = makePrompts()
        for request in [single(id: "srq-1"), batch(id: "srq-2"), secret(id: "srq-3"), sudo(id: "srq-4")] {
            model.handle(request)
            model.cancel(requestID: request.id)
            XCTAssertNil(model.pending, "\(request.method) must be dismissed")
        }
        XCTAssertTrue(prompts.calls.isEmpty, "a withdrawal is not an answer, refusal, or skip")
    }

    func testCancelOfAQueuedRequestLeavesTheVisibleOneAlone() {
        let (prompts, model) = makePrompts()
        model.handle(single(id: "srq-1"))
        model.handle(secret(id: "srq-2"))
        model.cancel(requestID: "srq-2")
        XCTAssertEqual(model.pending?.id, "srq-1")
        XCTAssertTrue(model.queued.isEmpty)
        XCTAssertTrue(prompts.calls.isEmpty)
    }

    func testCancelOfTheVisibleRequestPromotesTheNextAndResetsTheLock() async {
        let (_, model) = makePrompts()
        model.handle(secret(id: "srq-1"))
        model.handle(sudo(id: "srq-2"))
        await model.unlockInput()
        XCTAssertTrue(model.isInputUnlocked)

        model.cancel(requestID: "srq-1")

        XCTAssertEqual(model.pending?.id, "srq-2")
        XCTAssertFalse(model.isInputUnlocked)
    }

    func testCancelForAnUnknownIDIsANoOp() {
        let (_, model) = makePrompts()
        model.handle(single())
        model.cancel(requestID: "srq-unknown")
        XCTAssertEqual(model.pending?.id, "srq-c1")
    }

    // MARK: - Approval as a server request

    private func makeApproval(
        biometrics: AppLockAuthResult = .success
    ) -> (ScriptedApprovals, ApprovalViewModel) {
        let approvals = ScriptedApprovals()
        let model = ApprovalViewModel(
            approvals: approvals, biometrics: ScriptedBiometrics(result: biometrics))
        model.bind(sessionID: "s-1")
        return (approvals, model)
    }

    private func approval(
        requestID: String = "req-1", serverRequestID: String? = "srq-a1"
    ) -> ApprovalRequest {
        ApprovalRequest(
            requestID: requestID, sessionID: "s-1", command: "printf 'fixture'",
            choices: ["once", "deny"], serverRequestID: serverRequestID)
    }

    func testDenyAndApproveTakeTheServerRequestPathWhenTheRequestCameThatWay() async {
        let (approvals, model) = makeApproval()
        model.handleApprovalRequest(approval())
        await model.deny()
        XCTAssertEqual(approvals.paths, [.serverRequest(id: "srq-a1", choice: .deny)])

        model.handleApprovalRequest(approval(requestID: "req-2", serverRequestID: "srq-a2"))
        await model.approve(scope: .once)
        XCTAssertEqual(approvals.paths.last, .serverRequest(id: "srq-a2", choice: .once))
    }

    func testLegacyApprovalKeepsTheApprovalRespondPath() async {
        let (approvals, model) = makeApproval()
        model.handleApprovalRequest(approval(requestID: "req-legacy", serverRequestID: nil))
        await model.deny()
        XCTAssertEqual(approvals.paths, [.legacy(requestID: "req-legacy", choice: .deny)])
    }

    func testCancelServerRequestDismissesTheBannerAndNeverDenies() {
        let (approvals, model) = makeApproval()
        model.handleApprovalRequest(approval())

        model.cancelServerRequest(id: "srq-a1")

        XCTAssertNil(model.pending)
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(approvals.paths.isEmpty, "a withdrawal must never record a denial")
    }

    func testCancelPromotesTheQueuedApproval() {
        let (approvals, model) = makeApproval()
        model.handleApprovalRequest(approval(requestID: "req-1", serverRequestID: "srq-a1"))
        model.handleApprovalRequest(approval(requestID: "req-2", serverRequestID: "srq-a2"))
        XCTAssertEqual(model.queued.map(\.requestID), ["req-2"])

        model.cancelServerRequest(id: "srq-a1")

        XCTAssertEqual(model.pending?.requestID, "req-2")
        XCTAssertEqual(model.state, .pending)
        XCTAssertTrue(approvals.paths.isEmpty)
    }

    func testCancelOfAQueuedApprovalKeepsTheVisibleBanner() {
        let (_, model) = makeApproval()
        model.handleApprovalRequest(approval(requestID: "req-1", serverRequestID: "srq-a1"))
        model.handleApprovalRequest(approval(requestID: "req-2", serverRequestID: "srq-a2"))

        model.cancelServerRequest(id: "srq-a2")

        XCTAssertEqual(model.pending?.requestID, "req-1")
        XCTAssertTrue(model.queued.isEmpty)
    }

    func testCancelDoesNotTouchALegacyApprovalOrAnUnknownID() {
        let (_, model) = makeApproval()
        model.handleApprovalRequest(approval(requestID: "req-legacy", serverRequestID: nil))
        model.cancelServerRequest(id: "srq-unknown")
        XCTAssertEqual(model.pending?.requestID, "req-legacy")
    }

    func testRedeliveredApprovalNeverDoubleQueuesAndAdoptsTheServerRequestID() async {
        let (approvals, model) = makeApproval()
        // The banner first arrived through a legacy path (no srq id)...
        model.handleApprovalRequest(approval(requestID: "req-1", serverRequestID: nil))
        // ...then the same approval is re-delivered as a server request.
        model.handleApprovalRequest(approval(requestID: "req-1", serverRequestID: "srq-a1"))
        XCTAssertTrue(model.queued.isEmpty, "the same approval never renders twice")
        XCTAssertEqual(model.pending?.serverRequestID, "srq-a1")

        // Queued duplicates upgrade in place too.
        model.handleApprovalRequest(approval(requestID: "req-2", serverRequestID: nil))
        model.handleApprovalRequest(approval(requestID: "req-2", serverRequestID: "srq-a2"))
        XCTAssertEqual(model.queued.count, 1)
        XCTAssertEqual(model.queued.first?.serverRequestID, "srq-a2")

        await model.deny()
        XCTAssertEqual(approvals.paths, [.serverRequest(id: "srq-a1", choice: .deny)])
    }
}
