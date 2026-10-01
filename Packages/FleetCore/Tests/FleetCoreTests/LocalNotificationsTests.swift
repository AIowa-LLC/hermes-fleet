import XCTest
@testable import FleetCore

/// R8 (#95): the pure notification decision rules and the background grace
/// window state machine. Synthetic values only.
final class LocalNotificationPolicyTests: XCTestCase {

    private func serverApproval(replayed: Bool = false) -> ConversationEvent {
        .serverRequest(ServerRequest(
            id: "srq-1", sessionID: "s1",
            kind: .approval(ApprovalRequest(
                requestID: "req-1", sessionID: "s1", command: "rm -rf /secret-path",
                serverRequestID: "srq-1")),
            replayed: replayed))
    }

    // MARK: event -> attention

    func testApprovalEventsMapToApprovalAttention() {
        let legacy = ConversationEvent.approvalRequested(
            sessionID: "s1", requestID: "req-1", command: "rm -rf /", detail: nil, choices: [], seq: 4)
        XCTAssertEqual(
            LocalNotificationPolicy.attention(for: legacy, turnStartedHere: false),
            .approval(requestID: "req-1", aliases: []))

        // The server request for the SAME approval shares the primary id, so
        // the two delivery paths coalesce into one notification.
        XCTAssertEqual(
            LocalNotificationPolicy.attention(for: serverApproval(), turnStartedHere: false),
            .approval(requestID: "req-1", aliases: ["srq-1"]))
    }

    func testClarifySudoSecretMapToRequestKinds() {
        let clarify = ConversationEvent.serverRequest(ServerRequest(
            id: "srq-2", sessionID: "s1",
            kind: .clarify(ClarifyPrompt(sessionID: "s1", questions: [ClarifyQuestion(qid: "", question: "Which one?")], isBatch: false))))
        XCTAssertEqual(LocalNotificationPolicy.attention(for: clarify, turnStartedHere: false), .clarify(requestID: "srq-2"))

        let sudo = ConversationEvent.serverRequest(ServerRequest(
            id: "srq-3", sessionID: "s1", kind: .sudo(SudoPrompt(sessionID: "s1", command: "apt update"))))
        XCTAssertEqual(LocalNotificationPolicy.attention(for: sudo, turnStartedHere: false), .secretInput(requestID: "srq-3"))

        let secret = ConversationEvent.serverRequest(ServerRequest(
            id: "srq-4", sessionID: "s1", kind: .secret(SecretPrompt(sessionID: "s1", envVar: "TOKEN", prompt: "Paste it"))))
        XCTAssertEqual(LocalNotificationPolicy.attention(for: secret, turnStartedHere: false), .secretInput(requestID: "srq-4"))
    }

    func testRequestReplayedThroughOpenRequestsNeverNotifies() {
        XCTAssertNil(LocalNotificationPolicy.attention(for: serverApproval(replayed: true), turnStartedHere: false))
    }

    func testCompletionNotifiesOnlyForTurnsStartedHere() {
        let done = ConversationEvent.messageComplete(sessionID: "s1", text: "hello", status: nil, error: nil, seq: 9)
        XCTAssertEqual(LocalNotificationPolicy.attention(for: done, turnStartedHere: true), .turnFinished)
        XCTAssertNil(LocalNotificationPolicy.attention(for: done, turnStartedHere: false))

        let failed = ConversationEvent.messageComplete(sessionID: "s1", text: "", status: "error", error: "boom", seq: 10)
        XCTAssertEqual(LocalNotificationPolicy.attention(for: failed, turnStartedHere: true), .turnFailed)
    }

    func testTurnLevelErrorMapsToStopped() {
        let error = ConversationEvent.error(sessionID: "s1", message: "provider down", seq: 11)
        XCTAssertEqual(LocalNotificationPolicy.attention(for: error, turnStartedHere: true), .turnFailed)
    }

    func testChatterNeverNotifies() {
        let events: [ConversationEvent] = [
            .messageStart(sessionID: "s1", seq: 1),
            .messageDelta(sessionID: "s1", text: "x", rendered: nil, seq: 2),
            .toolStart(sessionID: "s1", toolID: "t", name: "shell", context: nil, argsText: nil, seq: 3),
            .sessionTitleUpdate(sessionID: "s1", title: "T", seq: 4),
            .requestCancelled(sessionID: "s1", requestID: "srq-1", method: "approval", reason: "timeout", seq: 5),
            .unknown(sessionID: "s1", rawType: "future.event", seq: 6),
        ]
        for event in events {
            XCTAssertNil(LocalNotificationPolicy.attention(for: event, turnStartedHere: true), "\(event)")
        }
    }

    func testWithdrawalEventNamesItsRequest() {
        let cancelled = ConversationEvent.requestCancelled(
            sessionID: "s1", requestID: "srq-1", method: "approval", reason: "answered_elsewhere", seq: nil)
        XCTAssertEqual(LocalNotificationPolicy.withdrawnRequestID(for: cancelled), "srq-1")
        XCTAssertNil(LocalNotificationPolicy.withdrawnRequestID(for: .messageStart(sessionID: "s1", seq: 1)))
    }

    // MARK: when to post

    func testPostsOnlyWhenEnabledAuthorizedAndNotWatching() {
        func decide(_ enabled: Bool, _ auth: FleetNotificationAuthorization, active: Bool, visible: Bool) -> Bool {
            LocalNotificationPolicy.shouldPost(.init(
                isEnabled: enabled, authorization: auth, isAppActive: active, isConversationVisible: visible))
        }
        // Backgrounded: always post (when allowed).
        XCTAssertTrue(decide(true, .authorized, active: false, visible: true))
        XCTAssertTrue(decide(true, .authorized, active: false, visible: false))
        // Active app, other conversation: post.
        XCTAssertTrue(decide(true, .authorized, active: true, visible: false))
        // Active app watching this conversation: never.
        XCTAssertFalse(decide(true, .authorized, active: true, visible: true))
        // Opt-out or no permission: never.
        XCTAssertFalse(decide(false, .authorized, active: false, visible: false))
        for auth in [FleetNotificationAuthorization.notDetermined, .denied, .unavailable] {
            XCTAssertFalse(decide(true, auth, active: false, visible: false), "\(auth)")
        }
    }

    // MARK: content

    func testContentIsGenericAndNamesTheBot() {
        let approval = LocalNotificationPolicy.content(
            for: .approval(requestID: "r", aliases: []), botName: "Atlas", appLockEnabled: false)
        XCTAssertEqual(approval.title, "Atlas needs approval")
        XCTAssertEqual(LocalNotificationPolicy.content(for: .clarify(requestID: "r"), botName: "Atlas", appLockEnabled: false).title,
                       "Question from Atlas")
        XCTAssertEqual(LocalNotificationPolicy.content(for: .turnFinished, botName: "Atlas", appLockEnabled: false).title,
                       "Atlas finished")
        XCTAssertEqual(LocalNotificationPolicy.content(for: .turnFailed, botName: "Atlas", appLockEnabled: false).title,
                       "Atlas stopped")
        XCTAssertEqual(LocalNotificationPolicy.content(for: .secretInput(requestID: "r"), botName: "Atlas", appLockEnabled: false).title,
                       "Atlas needs your input")
    }

    func testAppLockWithholdsTheBotNameEverywhere() {
        let kinds: [ConversationAttentionKind] = [
            .approval(requestID: "r", aliases: []), .clarify(requestID: "r"),
            .secretInput(requestID: "r"), .turnFinished, .turnFailed,
        ]
        for kind in kinds {
            let content = LocalNotificationPolicy.content(for: kind, botName: "Atlas", appLockEnabled: true)
            XCTAssertFalse((content.title + content.body).contains("Atlas"), "\(kind)")
        }
        XCTAssertEqual(
            LocalNotificationPolicy.content(for: .approval(requestID: "r", aliases: []), botName: "Atlas", appLockEnabled: true).title,
            "Approval needed")
    }

    func testBodyNeverCarriesRequestContent() {
        // The policy never receives command/secret text, so the only way it
        // could leak is through the bot name. Hostile names are sanitized.
        let hostile = "Atlas\u{0007}\n   rm -rf /   " + String(repeating: "x", count: 200)
        let name = LocalNotificationPolicy.sanitizedBotName(hostile)
        XCTAssertLessThanOrEqual(name.count, 40)
        XCTAssertFalse(name.contains("\n"))
        XCTAssertFalse(name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertEqual(LocalNotificationPolicy.sanitizedBotName("   "), "Your bot")
        XCTAssertEqual(LocalNotificationPolicy.sanitizedBotName(nil), "Your bot")
    }

    func testRequestIDsListPrimaryThenAliases() {
        XCTAssertEqual(ConversationAttentionKind.approval(requestID: "a", aliases: ["b", "a"]).requestIDs, ["a", "b"])
        XCTAssertEqual(ConversationAttentionKind.turnFinished.requestIDs, [])
    }

    func testNotificationIDsAreStablePerRequestAndPerConversation() {
        XCTAssertEqual(
            LocalNotificationPolicy.requestNotificationID(conversationKey: "c", requestID: "r"),
            LocalNotificationPolicy.requestNotificationID(conversationKey: "c", requestID: "r"))
        XCTAssertNotEqual(
            LocalNotificationPolicy.requestNotificationID(conversationKey: "c", requestID: "r1"),
            LocalNotificationPolicy.requestNotificationID(conversationKey: "c", requestID: "r2"))
        XCTAssertEqual(LocalNotificationPolicy.turnNotificationID(conversationKey: "c"),
                       LocalNotificationPolicy.turnNotificationID(conversationKey: "c"))
    }
}

// MARK: - Grace window

@MainActor
private final class FakeBackgroundTasks: FleetBackgroundTaskProviding {
    private(set) var began: [Int] = []
    private(set) var ended: [Int] = []
    var refuse = false
    private var nextID = 100
    private var expirations: [Int: @MainActor () -> Void] = [:]

    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int? {
        guard !refuse else { return nil }
        nextID += 1
        began.append(nextID)
        expirations[nextID] = expiration
        return nextID
    }

    func end(_ identifier: Int) { ended.append(identifier) }

    var leaked: [Int] { began.filter { !ended.contains($0) } }

    func expire(_ identifier: Int) { expirations[identifier]?() }
}

@MainActor
final class BackgroundGraceWindowTests: XCTestCase {

    private func makeWindow(
        tasks: FakeBackgroundTasks,
        live: Bool = true,
        budget: Duration = .milliseconds(50),
        suspend: @escaping @MainActor () async -> Void = {}
    ) -> BackgroundGraceWindow {
        BackgroundGraceWindow(
            provider: tasks, suspendBudget: budget,
            hasLiveConnections: { live }, suspend: suspend)
    }

    func testBeginsOnBackgroundAndEndsOnForegroundWithoutSuspending() {
        let tasks = FakeBackgroundTasks()
        var suspended = 0
        let window = makeWindow(tasks: tasks, suspend: { suspended += 1 })
        window.enterBackground()
        XCTAssertEqual(tasks.began.count, 1)
        XCTAssertEqual(window.state, .active)
        window.enterForeground()
        XCTAssertEqual(tasks.ended, tasks.began)
        XCTAssertNil(window.taskIdentifier)
        XCTAssertEqual(window.state, .idle)
        XCTAssertEqual(suspended, 0, "returning inside the window leaves the connections alone")
        XCTAssertTrue(tasks.leaked.isEmpty)
    }

    func testRepeatedBackgroundCallsNeverBeginASecondTask() {
        let tasks = FakeBackgroundTasks()
        let window = makeWindow(tasks: tasks)
        window.enterBackground()
        window.enterBackground()
        window.enterBackground()
        XCTAssertEqual(tasks.began.count, 1)
        window.enterForeground()
        window.enterForeground()
        XCTAssertEqual(tasks.ended.count, 1, "ended exactly once")
    }

    func testExpirySuspendsThenEndsTheTask() async {
        let tasks = FakeBackgroundTasks()
        var suspended = 0
        let window = makeWindow(tasks: tasks, suspend: { suspended += 1 })
        window.enterBackground()
        tasks.expire(tasks.began[0])
        XCTAssertEqual(window.state, .suspended)
        for _ in 0..<100 where !tasks.leaked.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(suspended, 1)
        XCTAssertTrue(tasks.leaked.isEmpty)
        XCTAssertEqual(tasks.ended.count, 1)
        XCTAssertNil(window.taskIdentifier)
    }

    func testHungSuspendHookCannotHoldTheTaskPastItsBudget() async {
        let tasks = FakeBackgroundTasks()
        let window = makeWindow(tasks: tasks, budget: .milliseconds(30), suspend: {
            try? await Task.sleep(for: .seconds(30))
        })
        window.enterBackground()
        tasks.expire(tasks.began[0])
        for _ in 0..<100 where !tasks.leaked.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(tasks.leaked.isEmpty, "the OS task ends at the budget even when the hook hangs")
    }

    func testStaleExpiryAfterForegroundIsIgnored() async {
        let tasks = FakeBackgroundTasks()
        var suspended = 0
        let window = makeWindow(tasks: tasks, suspend: { suspended += 1 })
        window.enterBackground()
        let first = tasks.began[0]
        window.enterForeground()
        tasks.expire(first)
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(suspended, 0)
        XCTAssertEqual(tasks.ended.count, 1, "no double end")
    }

    func testSecondBackgroundingAfterForegroundGetsAFreshTask() {
        let tasks = FakeBackgroundTasks()
        let window = makeWindow(tasks: tasks)
        window.enterBackground()
        window.enterForeground()
        window.enterBackground()
        XCTAssertEqual(tasks.began.count, 2)
        window.enterForeground()
        XCTAssertTrue(tasks.leaked.isEmpty)
    }

    func testNoTaskWhenNothingIsConnectedOrTheOSRefuses() {
        let none = FakeBackgroundTasks()
        makeWindow(tasks: none, live: false).enterBackground()
        XCTAssertTrue(none.began.isEmpty)

        let refused = FakeBackgroundTasks()
        refused.refuse = true
        let window = makeWindow(tasks: refused)
        window.enterBackground()
        XCTAssertNil(window.taskIdentifier)
        XCTAssertEqual(window.state, .idle)
    }
}
