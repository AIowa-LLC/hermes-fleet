import XCTest
import FleetCore
import FleetUI
@testable import HermesFleetApp

/// B3: the app-level coordinator, driven by a real `InboxStore` over a
/// synthetic feed. No system notifications, no network, no permission prompt.
@MainActor
final class InboxNotificationCoordinatorTests: XCTestCase {

    // MARK: Fakes

    private final class FakeApprovals: ApprovalsProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(requestID: String, choice: ApprovalChoice)] = []

        var responses: [(requestID: String, choice: ApprovalChoice)] {
            lock.withLock { recorded }
        }

        func respond(sessionID: String, requestID: String, choice: ApprovalChoice, all: Bool) async throws -> Int {
            lock.withLock { recorded.append((requestID, choice)) }
            return 1
        }

        func setSessionYolo(_ enabled: Bool, sessionID: String) async throws -> Bool { false }
        func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] { [] }
    }

    private final class FakePrompts: ServerPromptResponding, @unchecked Sendable {
        func answerClarify(requestID: String, answer: String) async throws {}
        func lockClarifyAnswer(requestID: String, questionID: String, answer: String) async throws -> ClarifyLockStatus {
            .locked(remaining: [])
        }
        func cancelClarify(requestID: String) async throws {}
        func answerValue(requestID: String, value: String) async throws {}
    }

    private final class FakeFeed: InboxGatewayFeed, @unchecked Sendable {
        let gatewayID: GatewayID
        let approvalsFake = FakeApprovals()
        let promptsFake = FakePrompts()
        var approvals: any ApprovalsProviding { approvalsFake }
        var prompts: any ServerPromptResponding { promptsFake }
        let continuation: AsyncStream<InboxFeedEvent>.Continuation
        private let stream: AsyncStream<InboxFeedEvent>

        init(gatewayID: GatewayID) {
            self.gatewayID = gatewayID
            let (stream, continuation) = AsyncStream<InboxFeedEvent>.makeStream()
            self.stream = stream
            self.continuation = continuation
        }

        func start() async throws {}
        func stop() async {}
        func events() -> AsyncStream<InboxFeedEvent> { stream }
        func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] { [] }
    }

    private struct NoBiometrics: AppLockBiometricAuth {
        func canEvaluateBiometrics() -> Bool { false }
        func evaluateBiometrics(reason: String) async -> AppLockAuthResult { .unavailable }
        func evaluateDevicePasscode(reason: String) async -> Bool { false }
    }

    private final class RecordingNotifier: FleetLocalNotifier, @unchecked Sendable {
        private let lock = NSLock()
        private var status: FleetNotificationAuthorization
        private var posted: [FleetLocalNotification] = []
        private var withdrawn: [String] = []
        private var categories: [FleetNotificationCategory] = []

        init(status: FleetNotificationAuthorization) { self.status = status }

        var postedNotifications: [FleetLocalNotification] { lock.withLock { posted } }
        var withdrawnIDs: [String] { lock.withLock { withdrawn } }
        var registeredCategories: [FleetNotificationCategory] { lock.withLock { categories } }

        func setStatus(_ new: FleetNotificationAuthorization) { lock.withLock { status = new } }

        func authorizationStatus() async -> FleetNotificationAuthorization { lock.withLock { status } }

        func requestAuthorization() async -> Bool {
            lock.withLock {
                if status == .notDetermined { status = .authorized }
                return status == .authorized
            }
        }

        func registerCategories(_ categories: [FleetNotificationCategory]) async {
            lock.withLock { self.categories = categories }
        }

        func post(_ notification: FleetLocalNotification) async {
            lock.withLock { posted.append(notification) }
        }

        func withdraw(ids: [String]) async {
            lock.withLock {
                withdrawn.append(contentsOf: ids)
                posted.removeAll { ids.contains($0.id) }
            }
        }
    }

    // MARK: Harness

    private struct Harness {
        let store: InboxStore
        let feed: FakeFeed
        let notifier: RecordingNotifier
        let coordinator: InboxNotificationCoordinator
    }

    private let gatewayID = GatewayID(rawValue: "gw-test")

    private func makeHarness(
        history: InboxPersistedState = .empty,
        notifierStatus: FleetNotificationAuthorization = .authorized
    ) -> Harness {
        let store = InboxStore(
            history: InMemoryInboxHistoryStore(state: history),
            biometrics: NoBiometrics(),
            feedFactory: { _ in nil })
        let feed = FakeFeed(gatewayID: gatewayID)
        let notifier = RecordingNotifier(status: notifierStatus)
        let suite = UserDefaults(suiteName: "fleet.test.inbox-notifications.\(UUID().uuidString)")!
        let coordinator = InboxNotificationCoordinator(
            inbox: store,
            notifier: notifier,
            settings: InboxNotificationSettingsStore(defaults: suite),
            urlScheme: "hermes-fleet",
            appLockEnabled: { false })
        return Harness(store: store, feed: feed, notifier: notifier, coordinator: coordinator)
    }

    private func approval(_ id: String, command: String = "deploy --env staging") -> ApprovalRequest {
        ApprovalRequest(requestID: id, sessionID: "sess-1", command: command, detail: nil, choices: ["once", "deny"])
    }

    private func pendingItem(_ id: String) -> InboxItem {
        InboxItem(
            id: InboxItemID(gatewayID: gatewayID, sessionID: "sess-1", requestID: id),
            kind: .approval,
            requestID: id,
            agent: InboxAgentIdentity(gatewayID: gatewayID, gatewayLabel: "Workstation", sessionID: "sess-1"),
            context: InboxContext(command: "deploy", choices: ["once", "deny"]),
            serverRequestID: nil,
            // Recent: the store expires restored items older than an hour
            // when no gateway is attached.
            createdAt: Date())
    }

    /// Poll the main actor until the condition holds, failing after ~3 s.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met in time", file: file, line: line)
    }

    /// Settle: give the coordinator time to observe a change that should NOT
    /// produce a post.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    // MARK: Posting

    func testNewPendingRequestPostsOneNotificationWithGenericText() async throws {
        let h = makeHarness()
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")

        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await waitUntil { h.notifier.postedNotifications.count == 1 }

        let post = try XCTUnwrap(h.notifier.postedNotifications.first)
        XCTAssertEqual(post.categoryID, InboxNotificationCatalog.approvalCategoryID)
        XCTAssertEqual(post.title, "Workstation needs your approval")
        XCTAssertEqual(post.body, "Open Hermes Fleet to review.")
        XCTAssertFalse(post.title.contains("deploy"))
        XCTAssertFalse(post.body.contains("deploy"))
    }

    func testRedeliveryOfSameItemDoesNotPostAgain() async throws {
        let h = makeHarness()
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")

        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await waitUntil { h.notifier.postedNotifications.count == 1 }
        h.feed.continuation.yield(.legacyApproval(approval("req-1", command: "changed")))
        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await settle()

        XCTAssertEqual(h.notifier.postedNotifications.count, 1)
    }

    func testRestoredPendingItemsDoNotNotifyOnLaunch() async throws {
        let restored = InboxPersistedState(items: [pendingItem("old-1")], audit: [])
        let h = makeHarness(history: restored)
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")
        try await settle()

        XCTAssertTrue(h.notifier.postedNotifications.isEmpty)
    }

    func testNothingPostsWhenNotificationsAreOff() async throws {
        let h = makeHarness()
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")

        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await settle()

        XCTAssertTrue(h.notifier.postedNotifications.isEmpty)
    }

    func testEnablingRequestsPermissionOnlyFromTheToggle() async throws {
        let h = makeHarness(notifierStatus: .notDetermined)
        let accepted = await h.coordinator.setEnabled(true)
        XCTAssertTrue(accepted)
        let status = await h.coordinator.authorizationStatus()
        XCTAssertEqual(status, .authorized)
    }

    func testRefusedPermissionLeavesNotificationsOff() async throws {
        let h = makeHarness(notifierStatus: .denied)
        let accepted = await h.coordinator.setEnabled(true)
        XCTAssertFalse(accepted)
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")
        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await settle()
        XCTAssertTrue(h.notifier.postedNotifications.isEmpty)
    }

    func testInboxOnScreenInActiveAppSuppresses() async throws {
        let h = makeHarness()
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")
        h.coordinator.setAppActive(true)
        await h.coordinator.setInboxVisible(true)

        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await settle()
        XCTAssertTrue(h.notifier.postedNotifications.isEmpty)
    }

    func testViewingTheSessionInTheActiveAppSuppresses() async throws {
        let h = makeHarness()
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")
        h.coordinator.setAppActive(true)
        h.coordinator.setViewedSession("sess-1")

        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await settle()
        XCTAssertTrue(h.notifier.postedNotifications.isEmpty)
    }

    func testInboxAppearingWithdrawsDeliveredNotifications() async throws {
        let h = makeHarness()
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")
        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await waitUntil { h.notifier.postedNotifications.count == 1 }

        await h.coordinator.setInboxVisible(true)
        let id = InboxNotificationCatalog.notificationID(
            for: InboxItemID(gatewayID: gatewayID, sessionID: "sess-1", requestID: "req-1"))
        XCTAssertTrue(h.notifier.withdrawnIDs.contains(id))
    }

    // MARK: Withdrawal

    func testResolutionWithdrawsTheDeliveredNotification() async throws {
        let h = makeHarness()
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")
        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await waitUntil { h.notifier.postedNotifications.count == 1 }

        let itemID = InboxItemID(gatewayID: gatewayID, sessionID: "sess-1", requestID: "req-1")
        _ = try await h.store.decide(itemID, .deny)

        let expected = InboxNotificationCatalog.notificationID(for: itemID)
        try await waitUntil { h.notifier.withdrawnIDs.contains(expected) }
    }

    func testWithdrawnRequestAlsoWithdrawsNotification() async throws {
        let h = makeHarness()
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")
        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await waitUntil { h.notifier.postedNotifications.count == 1 }

        h.feed.continuation.yield(.withdrawn(wireRequestID: "req-1"))
        let expected = InboxNotificationCatalog.notificationID(
            for: InboxItemID(gatewayID: gatewayID, sessionID: "sess-1", requestID: "req-1"))
        try await waitUntil { h.notifier.withdrawnIDs.contains(expected) }
    }

    func testTurningOffWithdrawsEverythingPosted() async throws {
        let h = makeHarness()
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")
        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await waitUntil { h.notifier.postedNotifications.count == 1 }

        _ = await h.coordinator.setEnabled(false)
        XCTAssertTrue(h.notifier.postedNotifications.isEmpty)
        XCTAssertEqual(h.notifier.withdrawnIDs.count, 1)
    }

    // MARK: Actions

    func testDenyActionCallsStoreDecideWithDeny() async throws {
        let h = makeHarness()
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")
        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await waitUntil { h.notifier.postedNotifications.count == 1 }

        let itemIDRaw = InboxItemID(gatewayID: gatewayID, sessionID: "sess-1", requestID: "req-1").rawValue
        await h.coordinator.handleResponse(actionID: InboxNotificationCatalog.denyActionID, itemIDRaw: itemIDRaw)

        XCTAssertEqual(h.feed.approvalsFake.responses.count, 1)
        XCTAssertEqual(h.feed.approvalsFake.responses.first?.requestID, "req-1")
        XCTAssertEqual(h.feed.approvalsFake.responses.first?.choice, .deny)
        XCTAssertEqual(h.store.items.first?.status, .denied)
    }

    func testDenyActionWithoutAttachedGatewayFailsClosedAndKeepsItemPending() async throws {
        let h = makeHarness(history: InboxPersistedState(items: [pendingItem("old-1")], audit: []))
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        // No feed attached: the store cannot send anything.
        await h.coordinator.handleResponse(
            actionID: InboxNotificationCatalog.denyActionID,
            itemIDRaw: InboxItemID(gatewayID: gatewayID, sessionID: "sess-1", requestID: "old-1").rawValue)
        XCTAssertEqual(h.store.items.first?.status, .pending)
        XCTAssertTrue(h.feed.approvalsFake.responses.isEmpty)
        // Not silent: the notification is replaced by one that says so and
        // opens the item when tapped.
        let replacement = try XCTUnwrap(h.notifier.postedNotifications.last)
        XCTAssertEqual(replacement.title, "Couldn't deny from here")
        XCTAssertEqual(replacement.categoryID, InboxNotificationCatalog.requestCategoryID)
        XCTAssertEqual(replacement.id, InboxNotificationCatalog.notificationID(
            for: InboxItemID(gatewayID: gatewayID, sessionID: "sess-1", requestID: "old-1")))
    }

    func testFailedDenyOfAnAlreadyAnsweredItemPostsNothing() async throws {
        let h = makeHarness(history: InboxPersistedState(items: [pendingItem("old-1")], audit: []))
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        h.store.noteConversationDecision(
            gatewayID: gatewayID, sessionID: "sess-1", requestID: "old-1", decision: .deny)
        await h.coordinator.handleResponse(
            actionID: InboxNotificationCatalog.denyActionID,
            itemIDRaw: InboxItemID(gatewayID: gatewayID, sessionID: "sess-1", requestID: "old-1").rawValue)
        XCTAssertTrue(h.notifier.postedNotifications.isEmpty)
    }

    func testReviewActionOpensTheInboxDeepLink() async throws {
        let h = makeHarness()
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        var opened: [URL] = []
        h.coordinator.openURL = { opened.append($0) }

        let itemID = InboxItemID(gatewayID: gatewayID, sessionID: "sess-1", requestID: "req-1")
        await h.coordinator.handleResponse(actionID: InboxNotificationCatalog.reviewActionID, itemIDRaw: itemID.rawValue)

        let expected = try XCTUnwrap(FleetInboxDeepLink.url(scheme: "hermes-fleet", itemID: itemID))
        XCTAssertEqual(opened, [expected])
        XCTAssertEqual(FleetInboxDeepLink.itemID(from: expected, scheme: "hermes-fleet"), itemID)
    }

    func testApproveIsNotAReachableNotificationAction() async throws {
        let h = makeHarness()
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")
        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await waitUntil { h.notifier.postedNotifications.count == 1 }

        let itemIDRaw = InboxItemID(gatewayID: gatewayID, sessionID: "sess-1", requestID: "req-1").rawValue
        await h.coordinator.handleResponse(actionID: "fleet.inbox.action.approve", itemIDRaw: itemIDRaw)
        XCTAssertTrue(h.feed.approvalsFake.responses.isEmpty)
        XCTAssertEqual(h.store.items.first?.status, .pending)
    }

    func testForegroundPresentationSuppressedWhenUserIsLookingAtItem() async throws {
        let h = makeHarness()
        _ = await h.coordinator.setEnabled(true)
        await h.coordinator.start()
        h.store.attach(h.feed, label: "Workstation")
        h.feed.continuation.yield(.legacyApproval(approval("req-1")))
        try await waitUntil { h.notifier.postedNotifications.count == 1 }

        let raw = InboxItemID(gatewayID: gatewayID, sessionID: "sess-1", requestID: "req-1").rawValue
        XCTAssertTrue(h.coordinator.presentsInForeground(itemIDRaw: raw))
        h.coordinator.setViewedSession("sess-1")
        XCTAssertFalse(h.coordinator.presentsInForeground(itemIDRaw: raw))
    }

    // MARK: Categories

    func testStartRegistersTheApprovalAndRequestCategories() async throws {
        let h = makeHarness()
        await h.coordinator.start()
        let ids = h.notifier.registeredCategories.map(\.id)
        XCTAssertEqual(ids, [InboxNotificationCatalog.approvalCategoryID, InboxNotificationCatalog.requestCategoryID])
    }
}
