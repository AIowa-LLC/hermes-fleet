import XCTest
import FleetCore
import FleetUI
@testable import HermesFleetApp

/// Stub notification center: records every call, grants on request when
/// `status == .notDetermined`. Shared with the conversation integration tests.
final class RecordingNotifier: FleetLocalNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: FleetNotificationAuthorization
    private var _posted: [FleetLocalNotification] = []
    private var _withdrawn: [String] = []
    private var _requestCount = 0
    /// What `requestAuthorization` resolves to when the status is undetermined.
    var grants = true

    init(status: FleetNotificationAuthorization = .authorized) {
        _status = status
    }

    var posted: [FleetLocalNotification] { lock.withLock { _posted } }
    var withdrawn: [String] { lock.withLock { _withdrawn } }
    var requestCount: Int { lock.withLock { _requestCount } }

    func authorizationStatus() async -> FleetNotificationAuthorization { lock.withLock { _status } }

    func requestAuthorization() async -> Bool {
        lock.withLock {
            _requestCount += 1
            if _status == .notDetermined { _status = grants ? .authorized : .denied }
            return _status == .authorized
        }
    }

    func post(_ notification: FleetLocalNotification) async {
        lock.withLock { _posted.append(notification) }
    }

    func withdraw(ids: [String]) async { lock.withLock { _withdrawn.append(contentsOf: ids) } }
    func withdraw(threadID: String) async {}
}

/// R8 (#95): notification decisions end to end through the coordinator — when
/// to post, what the text says, App Lock redaction, replay suppression,
/// coalescing and withdrawal — against a stub notification center.
@MainActor
final class LocalNotificationCoordinatorTests: XCTestCase {

    private var defaults: UserDefaults!
    private let route = Route(
        gatewayID: GatewayID(rawValue: "workstation"),
        profileSlug: ProfileSlug(rawValue: "default"))
    private let tokenA = UUID()
    private let tokenB = UUID()

    override func setUp() async throws {
        let suite = "fleet.tests.local-notifications.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Fixtures

    private func makeCoordinator(
        _ notifier: RecordingNotifier = RecordingNotifier(),
        enabled: Bool = true,
        appLock: Bool = false
    ) async -> LocalNotificationCoordinator {
        defaults.set(enabled, forKey: LocalNotificationCoordinator.enabledKey)
        let coordinator = LocalNotificationCoordinator(notifier: notifier, defaults: defaults)
        coordinator.appLockEnabled = { appLock }
        await coordinator.refreshAuthorization()
        return coordinator
    }

    private func context(_ token: UUID? = nil, sessionID: String? = "stored-1", bot: String? = "Atlas")
        -> ConversationNotificationContext
    {
        ConversationNotificationContext(
            token: token ?? tokenA, route: route, sessionID: sessionID, canonical: false, botName: bot)
    }

    private func approvalEvent(seq: Int? = nil, requestID: String = "req-1") -> ConversationEvent {
        .approvalRequested(
            sessionID: "s-1", requestID: requestID, command: "rm -rf /very/secret/path",
            detail: "hunter2", choices: ["once", "deny"], seq: seq)
    }

    private func serverApproval(replayed: Bool = false) -> ConversationEvent {
        .serverRequest(ServerRequest(
            id: "srq-1", sessionID: "s-1",
            kind: .approval(ApprovalRequest(
                requestID: "req-1", sessionID: "s-1", command: "printf 'fixture'",
                choices: ["once", "deny"], serverRequestID: "srq-1")),
            replayed: replayed))
    }

    private func observe(
        _ coordinator: LocalNotificationCoordinator, _ event: ConversationEvent,
        context: ConversationNotificationContext? = nil,
        startedHere: Bool = false, replay: Bool = false
    ) {
        coordinator.observe(event, context: context ?? self.context(), turnStartedHere: startedHere, isReplay: replay)
    }

    // MARK: Inactive vs active

    func testApprovalPostsWhileInactiveWithGenericTextAndDeepLinkTarget() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.setAppActive(false)

        observe(coordinator, approvalEvent(seq: 5))
        await coordinator.waitForIdle()

        XCTAssertEqual(notifier.posted.count, 1)
        let note = notifier.posted[0]
        XCTAssertEqual(note.title, "Atlas needs approval")
        XCTAssertEqual(note.threadID, "fleet.thread.workstation.default", "one thread per gateway/bot")
        XCTAssertEqual(note.target, FleetNotificationTarget(route: route, sessionID: "stored-1", canonical: false))
        let text = note.title + note.body
        XCTAssertFalse(text.contains("rm -rf"), "never the command")
        XCTAssertFalse(text.contains("hunter2"), "never the detail")
        XCTAssertFalse(text.contains("secret"))
    }

    func testNothingPostsWhileTheUserWatchesThatConversationInTheActiveApp() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.setAppActive(true)
        coordinator.conversationDidAppear(token: tokenA)

        observe(coordinator, approvalEvent(seq: 1))
        await coordinator.waitForIdle()
        XCTAssertTrue(notifier.posted.isEmpty)

        // Same app, a DIFFERENT conversation on screen: post.
        coordinator.conversationDidAppear(token: tokenB)
        coordinator.conversationDidDisappear(token: tokenA)
        observe(coordinator, approvalEvent(seq: 2, requestID: "req-2"))
        await coordinator.waitForIdle()
        XCTAssertEqual(notifier.posted.count, 1)
    }

    func testBackgroundedAppNotifiesEvenForTheOnScreenConversation() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.conversationDidAppear(token: tokenA)
        coordinator.setAppActive(false)

        observe(coordinator, approvalEvent(seq: 1))
        await coordinator.waitForIdle()
        XCTAssertEqual(notifier.posted.count, 1)
    }

    // MARK: Opt-in and permission

    func testOptedOutOrUnauthorizedNeverPostsAndNeverAsksForPermission() async {
        for (enabled, status) in [(false, FleetNotificationAuthorization.authorized),
                                  (true, .denied), (true, .notDetermined), (true, .unavailable)] {
            let notifier = RecordingNotifier(status: status)
            let coordinator = await makeCoordinator(notifier, enabled: enabled)
            coordinator.setAppActive(false)
            observe(coordinator, approvalEvent(seq: 1))
            await coordinator.waitForIdle()
            XCTAssertTrue(notifier.posted.isEmpty, "\(enabled) \(status)")
            XCTAssertEqual(notifier.requestCount, 0, "an event never triggers the system prompt")
        }
    }

    func testCreatingTheCoordinatorNeverAsksForPermission() async {
        let notifier = RecordingNotifier(status: .notDetermined)
        let coordinator = LocalNotificationCoordinator(notifier: notifier, defaults: defaults)
        await coordinator.refreshAuthorization()
        XCTAssertEqual(notifier.requestCount, 0, "permission is never requested at launch")
        XCTAssertFalse(coordinator.isEnabled, "notifying is opt-in")
        XCTAssertEqual(coordinator.authorization, .notDetermined)
    }

    func testSettingsToggleRequestsPermissionOnceAndPersists() async {
        let notifier = RecordingNotifier(status: .notDetermined)
        let coordinator = await makeCoordinator(notifier, enabled: false)

        let on = await coordinator.setEnabled(true)
        XCTAssertTrue(on)
        XCTAssertEqual(notifier.requestCount, 1)
        XCTAssertTrue(coordinator.isDeliveryActive)
        XCTAssertTrue(defaults.bool(forKey: LocalNotificationCoordinator.enabledKey))

        _ = await coordinator.setEnabled(false)
        XCTAssertFalse(coordinator.isEnabled)
        _ = await coordinator.setEnabled(true)
        XCTAssertEqual(notifier.requestCount, 1, "already decided: the system is not asked again")
    }

    func testDeniedPermissionLeavesTheToggleOff() async {
        let notifier = RecordingNotifier(status: .notDetermined)
        notifier.grants = false
        let coordinator = await makeCoordinator(notifier, enabled: false)
        let on = await coordinator.setEnabled(true)
        XCTAssertFalse(on)
        XCTAssertFalse(coordinator.isDeliveryActive)
        XCTAssertEqual(coordinator.authorization, .denied)
    }

    func testDisablingWithdrawsWhatIsDelivered() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.setAppActive(false)
        observe(coordinator, approvalEvent(seq: 1))
        await coordinator.waitForIdle()

        _ = await coordinator.setEnabled(false)
        XCTAssertEqual(notifier.withdrawn.count, 1)
    }

    // MARK: Explain-first offer

    func testFirstApprovalOffersTheExplainerInsteadOfPrompting() async {
        let notifier = RecordingNotifier(status: .notDetermined)
        let coordinator = await makeCoordinator(notifier, enabled: false)
        coordinator.setAppActive(true)

        observe(coordinator, approvalEvent(seq: 1))
        XCTAssertTrue(coordinator.isOfferPending)
        XCTAssertEqual(notifier.requestCount, 0, "the offer explains first; the system is not asked yet")
        XCTAssertTrue(notifier.posted.isEmpty)

        await coordinator.acceptOffer()
        XCTAssertFalse(coordinator.isOfferPending)
        XCTAssertEqual(notifier.requestCount, 1)
        XCTAssertTrue(coordinator.isDeliveryActive)
    }

    func testDecliningTheOfferIsRememberedAndNeverRepeated() async {
        let notifier = RecordingNotifier(status: .notDetermined)
        let coordinator = await makeCoordinator(notifier, enabled: false)
        observe(coordinator, approvalEvent(seq: 1))
        XCTAssertTrue(coordinator.isOfferPending)

        coordinator.declineOffer()
        XCTAssertFalse(coordinator.isOfferPending)
        observe(coordinator, approvalEvent(seq: 2, requestID: "req-2"))
        XCTAssertFalse(coordinator.isOfferPending)
        XCTAssertEqual(notifier.requestCount, 0)

        // A fresh coordinator (next launch) honors the stored answer.
        let relaunched = LocalNotificationCoordinator(notifier: notifier, defaults: defaults)
        await relaunched.refreshAuthorization()
        relaunched.observe(approvalEvent(seq: 3, requestID: "req-3"), context: context(),
                           turnStartedHere: false, isReplay: false)
        XCTAssertFalse(relaunched.isOfferPending)
    }

    func testNoOfferForCompletionsOrWhenAlreadyDecided() async {
        let undecided = await makeCoordinator(RecordingNotifier(status: .notDetermined), enabled: false)
        observe(undecided, .messageComplete(sessionID: "s-1", text: "hi", status: nil, error: nil, seq: 1), startedHere: true)
        XCTAssertFalse(undecided.isOfferPending, "a finished turn is not worth an explainer")

        let denied = await makeCoordinator(RecordingNotifier(status: .denied), enabled: false)
        observe(denied, approvalEvent(seq: 1))
        XCTAssertFalse(denied.isOfferPending, "the system already said no")
    }

    func testOfferClearsWhenTheRequestIsWithdrawn() async {
        let coordinator = await makeCoordinator(RecordingNotifier(status: .notDetermined), enabled: false)
        observe(coordinator, serverApproval())
        XCTAssertTrue(coordinator.isOfferPending)
        coordinator.requestsResolved(ids: ["srq-1"])
        XCTAssertFalse(coordinator.isOfferPending)
    }

    // MARK: App Lock

    func testAppLockWithholdsBotNameAndDetail() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier, appLock: true)
        coordinator.setAppActive(false)

        observe(coordinator, approvalEvent(seq: 1))
        await coordinator.waitForIdle()

        XCTAssertEqual(notifier.posted.first?.title, "Approval needed")
        let text = (notifier.posted.first?.title ?? "") + (notifier.posted.first?.body ?? "")
        XCTAssertFalse(text.contains("Atlas"))
        XCTAssertFalse(text.contains("rm -rf"))
    }

    func testUnattachedAppLockFailsClosedToRedactedText() async {
        let notifier = RecordingNotifier()
        defaults.set(true, forKey: LocalNotificationCoordinator.enabledKey)
        let coordinator = LocalNotificationCoordinator(notifier: notifier, defaults: defaults)
        await coordinator.refreshAuthorization()
        coordinator.setAppActive(false)
        observe(coordinator, approvalEvent(seq: 1))
        await coordinator.waitForIdle()
        XCTAssertEqual(notifier.posted.first?.title, "Approval needed")
    }

    // MARK: Replay and duplicates

    func testReplayedEventsNeverNotify() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.setAppActive(false)

        // Flagged replay (gap recovery).
        observe(coordinator, approvalEvent(seq: 10), replay: true)
        // Request re-delivered through open_requests.
        observe(coordinator, serverApproval(replayed: true))
        await coordinator.waitForIdle()
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func testSeqAtOrBelowTheWatermarkNeverNotifies() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.setAppActive(false)

        observe(coordinator, .messageDelta(sessionID: "s-1", text: "x", rendered: nil, seq: 20))
        // An old approval (seq 7 < 20) surfacing again — e.g. a new view model
        // re-applying the ring tail — is a replay.
        observe(coordinator, approvalEvent(seq: 7))
        // Equal seq is a duplicate frame.
        observe(coordinator, approvalEvent(seq: 20, requestID: "req-eq"))
        await coordinator.waitForIdle()
        XCTAssertTrue(notifier.posted.isEmpty)

        // A genuinely newer event still notifies.
        observe(coordinator, approvalEvent(seq: 21, requestID: "req-new"))
        await coordinator.waitForIdle()
        XCTAssertEqual(notifier.posted.count, 1)
    }

    func testOneApprovalSeenTwoWaysPostsOnce() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.setAppActive(false)

        observe(coordinator, approvalEvent(seq: 3))          // legacy event
        observe(coordinator, serverApproval())               // same approval as a server request
        observe(coordinator, serverApproval())               // re-delivered again
        await coordinator.waitForIdle()
        XCTAssertEqual(notifier.posted.count, 1)
    }

    func testDistinctApprovalsEachNotify() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.setAppActive(false)
        observe(coordinator, approvalEvent(seq: 1, requestID: "req-1"))
        observe(coordinator, approvalEvent(seq: 2, requestID: "req-2"))
        await coordinator.waitForIdle()
        XCTAssertEqual(Set(notifier.posted.map(\.id)).count, 2)
    }

    // MARK: Turn outcomes

    func testCompletionNotifiesOnlyForTurnsStartedHereAndOncePerTurn() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.setAppActive(false)

        observe(coordinator, .messageComplete(sessionID: "s-1", text: "a", status: nil, error: nil, seq: 1), startedHere: false)
        await coordinator.waitForIdle()
        XCTAssertTrue(notifier.posted.isEmpty, "not started on this device")

        observe(coordinator, .messageComplete(sessionID: "s-1", text: "b", status: nil, error: nil, seq: 2), startedHere: true)
        // A terminal error for the same turn must not buzz a second time.
        observe(coordinator, .error(sessionID: "s-1", message: "late", seq: 3), startedHere: true)
        await coordinator.waitForIdle()
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertEqual(notifier.posted[0].title, "Atlas finished")

        // The next turn posts again, REPLACING the same delivery id.
        observe(coordinator, .messageStart(sessionID: "s-1", seq: 4))
        observe(coordinator, .messageComplete(sessionID: "s-1", text: "c", status: "error", error: "x", seq: 5), startedHere: true)
        await coordinator.waitForIdle()
        XCTAssertEqual(notifier.posted.count, 2)
        XCTAssertEqual(notifier.posted[1].title, "Atlas stopped")
        XCTAssertEqual(notifier.posted[0].id, notifier.posted[1].id, "coalesces per conversation")
    }

    func testClarifyAndSecretRequestsUseTheirOwnGenericText() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.setAppActive(false)
        observe(coordinator, .serverRequest(ServerRequest(
            id: "srq-c", sessionID: "s-1",
            kind: .clarify(ClarifyPrompt(sessionID: "s-1", questions: [
                ClarifyQuestion(qid: "", question: "Drop the production table?")], isBatch: false)))))
        observe(coordinator, .serverRequest(ServerRequest(
            id: "srq-s", sessionID: "s-1", kind: .sudo(SudoPrompt(sessionID: "s-1", command: "sudo rm -rf /")))))
        observe(coordinator, .serverRequest(ServerRequest(
            id: "srq-k", sessionID: "s-1",
            kind: .secret(SecretPrompt(sessionID: "s-1", envVar: "API_TOKEN", prompt: "Paste the token")))))
        await coordinator.waitForIdle()

        XCTAssertEqual(notifier.posted.map(\.title),
                       ["Question from Atlas", "Atlas needs your input", "Atlas needs your input"])
        let all = notifier.posted.map { $0.title + $0.body }.joined()
        for leaked in ["production table", "rm -rf", "API_TOKEN", "Paste the token"] {
            XCTAssertFalse(all.contains(leaked), leaked)
        }
    }

    func testNoPostWithoutADurableSessionToLinkTo() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.setAppActive(false)
        observe(coordinator, approvalEvent(seq: 1), context: context(sessionID: nil))
        await coordinator.waitForIdle()
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    // MARK: Withdrawal

    func testRequestCancelWithdrawsTheDeliveredNotification() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.setAppActive(false)
        observe(coordinator, serverApproval())
        await coordinator.waitForIdle()
        let deliveryID = notifier.posted[0].id

        observe(coordinator, .requestCancelled(
            sessionID: "s-1", requestID: "srq-1", method: "approval", reason: "timeout", seq: nil))
        await coordinator.waitForIdle()
        XCTAssertEqual(notifier.withdrawn, [deliveryID])
    }

    func testAnsweringByEitherIdWithdrawsAndNeverPostsTwice() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.setAppActive(false)
        observe(coordinator, serverApproval())
        await coordinator.waitForIdle()
        let deliveryID = notifier.posted[0].id

        // The approval view model reports the legacy and server ids together.
        coordinator.requestsResolved(ids: ["req-1", "srq-1"])
        await coordinator.waitForIdle()
        XCTAssertEqual(notifier.withdrawn, [deliveryID], "one withdrawal for one notification")
    }

    func testResolvingAnUnknownRequestIsANoOp() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.requestsResolved(ids: ["nope"])
        await coordinator.waitForIdle()
        XCTAssertTrue(notifier.withdrawn.isEmpty)
    }

    func testOpeningTheConversationClearsItsDeliveredNotifications() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.setAppActive(false)
        observe(coordinator, approvalEvent(seq: 1))
        await coordinator.waitForIdle()
        let deliveryID = notifier.posted[0].id

        coordinator.setAppActive(true)
        coordinator.conversationDidAppear(token: tokenA)
        await coordinator.waitForIdle()
        XCTAssertEqual(notifier.withdrawn, [deliveryID])
    }

    func testReturningToTheForegroundClearsTheVisibleConversation() async {
        let notifier = RecordingNotifier()
        let coordinator = await makeCoordinator(notifier)
        coordinator.conversationDidAppear(token: tokenA)
        coordinator.setAppActive(false)
        observe(coordinator, approvalEvent(seq: 1))
        await coordinator.waitForIdle()
        let deliveryID = notifier.posted[0].id

        coordinator.setAppActive(true)
        await coordinator.waitForIdle()
        XCTAssertEqual(notifier.withdrawn, [deliveryID])
    }
}
