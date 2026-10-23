import XCTest
@testable import FleetCore

/// B3: pure policy for inbox notifications. Synthetic fixtures only.
final class InboxNotificationPolicyTests: XCTestCase {

    private let gateway = GatewayID(rawValue: "gw-test")
    private let now = Date(timeIntervalSince1970: 1_000)

    private func item(
        request: String = "req-1",
        session: String = "sess-1",
        kind: InboxItemKind = .approval,
        status: InboxStatus = .pending,
        label: String = "Test Agent",
        profile: String? = nil,
        command: String? = "deploy --env staging",
        envVar: String? = nil,
        batch: Bool = false
    ) -> InboxItem {
        InboxItem(
            id: InboxItemID(gatewayID: gateway, sessionID: session, requestID: request),
            kind: kind,
            requestID: request,
            status: status,
            agent: InboxAgentIdentity(gatewayID: gateway, gatewayLabel: label, profileName: profile, sessionID: session),
            context: InboxContext(command: command, detail: "Recursive delete", choices: ["once", "deny"], envVarName: envVar, isBatchQuestion: batch),
            serverRequestID: "srq-\(request)",
            createdAt: now)
    }

    private func conditions(
        enabled: Bool = true,
        auth: FleetNotificationAuthorization = .authorized,
        active: Bool = false,
        inboxVisible: Bool = false,
        viewed: String? = nil,
        appLock: Bool = false,
        details: Bool = false
    ) -> InboxNotificationConditions {
        InboxNotificationConditions(
            isEnabled: enabled,
            authorization: auth,
            isAppActive: active,
            isInboxVisible: inboxVisible,
            viewedSessionID: viewed,
            appLockEnabled: appLock,
            showsRequestDetails: details)
    }

    // MARK: Dedupe and baseline

    func testNewPendingItemPostsExactlyOnce() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        let first = tracker.plan([item()], conditions: conditions())
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.id, InboxNotificationCatalog.notificationID(for: item().id))
        XCTAssertTrue(tracker.plan([item()], conditions: conditions()).isEmpty, "same snapshot again must not repost")
    }

    func testRedeliveryOfSameItemIDNeverReposts() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        XCTAssertEqual(tracker.plan([item(command: "one")], conditions: conditions()).count, 1)
        // Same identity (gateway, session, request) re-delivered with a changed field.
        XCTAssertTrue(tracker.plan([item(command: "two")], conditions: conditions()).isEmpty)
    }

    func testRestoredPendingItemsAreBaselineAndDoNotNotify() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([item(request: "old-1"), item(request: "old-2", kind: .question)])
        XCTAssertTrue(tracker.plan([item(request: "old-1"), item(request: "old-2", kind: .question)], conditions: conditions()).isEmpty)
    }

    func testAlreadyDecidedItemNeverPosts() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        for status in [InboxStatus.approved, .denied, .answered, .expired, .cancelled, .failed] {
            XCTAssertTrue(tracker.plan([item(status: status)], conditions: conditions()).isEmpty, "\(status)")
        }
    }

    func testMultiplePendingItemsEachPostOnce() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        let posts = tracker.plan([item(request: "a"), item(request: "b", kind: .question)], conditions: conditions())
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(Set(posts.map(\.id)).count, 2)
    }

    // MARK: Opt-in, authorization, suppression

    func testDisabledOrUnauthorizedNeverPostsButMarksHandled() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        XCTAssertTrue(tracker.plan([item()], conditions: conditions(enabled: false)).isEmpty)
        // Enabling later must not replay a request that arrived while off.
        XCTAssertTrue(tracker.plan([item()], conditions: conditions()).isEmpty)

        for auth in [FleetNotificationAuthorization.notDetermined, .denied, .unavailable] {
            var other = InboxNotificationTracker()
            other.baseline([])
            XCTAssertTrue(other.plan([item()], conditions: conditions(auth: auth)).isEmpty, "\(auth)")
        }
    }

    func testInboxVisibleInActiveAppSuppresses() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        XCTAssertTrue(tracker.plan([item()], conditions: conditions(active: true, inboxVisible: true)).isEmpty)
    }

    func testViewingThatSessionInActiveAppSuppresses() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        XCTAssertTrue(tracker.plan([item(session: "sess-1")], conditions: conditions(active: true, viewed: "sess-1")).isEmpty)
    }

    func testViewingAnotherSessionStillPosts() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        XCTAssertEqual(tracker.plan([item(session: "sess-1")], conditions: conditions(active: true, viewed: "sess-2")).count, 1)
    }

    func testBackgroundAppPostsEvenIfInboxFlagIsStale() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        XCTAssertEqual(tracker.plan([item()], conditions: conditions(active: false, inboxVisible: true, viewed: "sess-1")).count, 1)
    }

    // MARK: Resolution and withdrawal

    func testResolutionReturnsDeliveryIDAndForgetsItem() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        XCTAssertEqual(tracker.plan([item()], conditions: conditions()).count, 1)
        let id = tracker.resolved(item().id)
        XCTAssertEqual(id, InboxNotificationCatalog.notificationID(for: item().id))
        XCTAssertFalse(tracker.posted.contains(item().id))
    }

    func testWithdrawAllReturnsEveryPostedIDAndClears() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        _ = tracker.plan([item(request: "a"), item(request: "b")], conditions: conditions())
        let ids = tracker.withdrawAll()
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(tracker.posted.isEmpty)
        XCTAssertTrue(tracker.withdrawAll().isEmpty)
    }

    func testAcknowledgeWithdrawsButKeepsItemsHandled() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        _ = tracker.plan([item()], conditions: conditions())
        XCTAssertEqual(tracker.acknowledge().count, 1)
        // Still pending and still seen: a later snapshot does not re-post it.
        XCTAssertTrue(tracker.plan([item()], conditions: conditions()).isEmpty)
    }

    func testPrunedHandledSetAllowsNoReplayAfterTerminal() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        _ = tracker.plan([item()], conditions: conditions())
        // Item resolves in a snapshot (terminal): handled is pruned.
        XCTAssertTrue(tracker.plan([item(status: .approved)], conditions: conditions()).isEmpty)
        XCTAssertFalse(tracker.handled.contains(item().id))
    }

    // MARK: Content and privacy

    func testDefaultApprovalTextNamesAgentButNeverTheCommand() {
        let text = InboxNotificationContent.make(for: item(profile: "ops-bot", command: "rm -rf /secret/path"), appLockEnabled: false, showsRequestDetails: false)
        XCTAssertEqual(text.title, "ops-bot needs your approval")
        XCTAssertEqual(text.body, "Open Hermes Fleet to review.")
        XCTAssertFalse(text.body.contains("rm -rf"))
        XCTAssertFalse(text.title.contains("rm -rf"))
    }

    func testDefaultTextUsesGatewayLabelWhenNoProfile() {
        let text = InboxNotificationContent.make(for: item(label: "Workstation"), appLockEnabled: false, showsRequestDetails: false)
        XCTAssertEqual(text.title, "Workstation needs your approval")
    }

    func testRequestDetailsOptInIncludesTruncatedCommand() {
        let long = String(repeating: "x", count: 300)
        let text = InboxNotificationContent.make(for: item(command: long), appLockEnabled: false, showsRequestDetails: true)
        XCTAssertTrue(text.body.hasPrefix("xxx"))
        XCTAssertLessThanOrEqual(text.body.count, InboxNotificationContent.maxDetailLength)
        XCTAssertTrue(text.body.hasSuffix("…"))
    }

    func testRequestDetailsWithoutOptInOmitsCommand() {
        let text = InboxNotificationContent.make(for: item(command: "deploy --env staging"), appLockEnabled: false, showsRequestDetails: false)
        XCTAssertFalse(text.body.contains("deploy"))
    }

    func testAppLockOnForcesGenericTextEvenWithDetailsOptIn() {
        let approval = InboxNotificationContent.make(for: item(profile: "ops-bot", command: "deploy"), appLockEnabled: true, showsRequestDetails: true)
        XCTAssertEqual(approval.title, "Approval needed")
        XCTAssertEqual(approval.body, "Open Hermes Fleet to continue.")
        XCTAssertFalse(approval.title.contains("ops-bot"))

        let question = InboxNotificationContent.make(for: item(kind: .question), appLockEnabled: true, showsRequestDetails: true)
        XCTAssertEqual(question.title, "Input needed")
    }

    func testSecretAndSudoNeverShowCommandEnvVarOrValue() {
        let sudo = InboxNotificationContent.make(for: item(kind: .sudo, command: "sudo rm -rf /"), appLockEnabled: false, showsRequestDetails: true)
        XCTAssertFalse(sudo.title.contains("sudo"))
        XCTAssertFalse(sudo.body.contains("rm -rf"))

        let secret = InboxNotificationContent.make(for: item(kind: .secret, envVar: "API_TOKEN_NAME"), appLockEnabled: false, showsRequestDetails: true)
        XCTAssertEqual(secret.body, "Open Hermes Fleet to respond.")
        XCTAssertFalse(secret.title.contains("API_TOKEN"))
    }

    func testQuestionTextIsGeneric() {
        let text = InboxNotificationContent.make(for: item(kind: .question, batch: true), appLockEnabled: false, showsRequestDetails: true)
        XCTAssertEqual(text.title, "Question from Test Agent")
        XCTAssertEqual(text.body, "Open Hermes Fleet to answer.")
    }

    func testAgentNameIsSanitizedAndCapped() {
        let messy = "  Bot\u{0007}\n\tname   with\u{001B} controls " + String(repeating: "y", count: 80)
        let name = InboxNotificationContent.agentName(
            InboxAgentIdentity(gatewayID: gateway, gatewayLabel: messy, sessionID: "s"))
        XCTAssertFalse(name.contains("\u{0007}"))
        XCTAssertFalse(name.contains("\n"))
        XCTAssertTrue(name.hasPrefix("Bot name with controls"))
        XCTAssertLessThanOrEqual(name.count, InboxNotificationContent.maxNameLength)
    }

    func testUnknownOrEmptyAgentNameFallsBack() {
        XCTAssertEqual(InboxNotificationContent.agentName(
            InboxAgentIdentity(gatewayID: gateway, gatewayLabel: "unknown", sessionID: "s")), "An agent")
        XCTAssertEqual(InboxNotificationContent.agentName(
            InboxAgentIdentity(gatewayID: gateway, gatewayLabel: " \n ", sessionID: "s")), "An agent")
    }

    func testPostedNotificationCarriesOnlyIdentifiersInUserInfo() {
        var tracker = InboxNotificationTracker()
        tracker.baseline([])
        let post = tracker.plan([item(command: "deploy")], conditions: conditions(details: true)).first
        XCTAssertEqual(post?.userInfo, [InboxNotificationCatalog.itemIDKey: item().id.rawValue])
        // The opt-in body carries the command; userInfo never does.
        XCTAssertTrue(post?.body.contains("deploy") ?? false)
        XCTAssertFalse(post?.userInfo.values.contains { $0.contains("deploy") } ?? true)
    }

    // MARK: Categories and actions

    func testApprovalCategoryHasDenyAndReviewButNoApprove() {
        let approval = InboxNotificationCatalog.categories.first { $0.id == InboxNotificationCatalog.approvalCategoryID }
        XCTAssertEqual(approval?.actions.map(\.id), [InboxNotificationCatalog.denyActionID, InboxNotificationCatalog.reviewActionID])
        XCTAssertTrue(approval?.actions.contains { $0.id.lowercased().contains("approve") } == false)
        let deny = approval?.actions.first { $0.id == InboxNotificationCatalog.denyActionID }
        XCTAssertEqual(deny?.isDestructive, true)
        XCTAssertEqual(deny?.opensApp, false, "Deny runs in the background")
        XCTAssertEqual(approval?.actions.first { $0.id == InboxNotificationCatalog.reviewActionID }?.opensApp, true)
    }

    func testRequestCategoriesHaveNoActions() {
        let request = InboxNotificationCatalog.categories.first { $0.id == InboxNotificationCatalog.requestCategoryID }
        XCTAssertEqual(request?.actions, [])
        XCTAssertFalse(request?.hiddenPreviewsBodyPlaceholder.isEmpty ?? true)
    }

    func testCategoryIDMapsByKind() {
        XCTAssertEqual(InboxNotificationCatalog.categoryID(for: .approval), InboxNotificationCatalog.approvalCategoryID)
        for kind in [InboxItemKind.question, .sudo, .secret] {
            XCTAssertEqual(InboxNotificationCatalog.categoryID(for: kind), InboxNotificationCatalog.requestCategoryID)
        }
    }

    // MARK: Deep link

    func testDeepLinkRoundTripsItemIDWithSeparators() throws {
        // Separators that must survive the query encoding (no '#' or whitespace
        // in parts: those are rejected by design).
        let itemID = InboxItemID(gatewayID: gateway, sessionID: "sess-x&y=z+1", requestID: "req/1")
        let url = try XCTUnwrap(FleetInboxDeepLink.url(scheme: "hermes-fleet", itemID: itemID))
        XCTAssertEqual(url.scheme, "hermes-fleet")
        XCTAssertEqual(url.host, "inbox")
        XCTAssertEqual(FleetInboxDeepLink.itemID(from: url, scheme: "hermes-fleet"), InboxItemID(rawValue: itemID.rawValue))
    }

    func testDeepLinkRejectsOtherSchemeHostAndShape() throws {
        let itemID = InboxItemID(gatewayID: gateway, sessionID: "s", requestID: "r")
        let good = try XCTUnwrap(FleetInboxDeepLink.url(scheme: "hermes-fleet", itemID: itemID))
        XCTAssertNil(FleetInboxDeepLink.itemID(from: good, scheme: "hermes-fleet-dev"))
        XCTAssertNil(FleetInboxDeepLink.itemID(from: URL(string: "hermes-fleet://conversation?item=gw%23s%23r")!, scheme: "hermes-fleet"))
        XCTAssertNil(FleetInboxDeepLink.itemID(from: URL(string: "hermes-fleet://inbox")!, scheme: "hermes-fleet"))
        XCTAssertNil(FleetInboxDeepLink.itemID(from: URL(string: "hermes-fleet://inbox?item=only-one-part")!, scheme: "hermes-fleet"))
        XCTAssertNil(FleetInboxDeepLink.itemID(from: URL(string: "hermes-fleet://inbox?item=a%23b%23c&item=a%23b%23c")!, scheme: "hermes-fleet"))
        XCTAssertNil(FleetInboxDeepLink.itemID(from: URL(string: "hermes-fleet://inbox?item=a%23b%23c&extra=1")!, scheme: "hermes-fleet"))
        XCTAssertNil(FleetInboxDeepLink.itemID(from: URL(string: "hermes-fleet://inbox?item=a%23%23c")!, scheme: "hermes-fleet"))
        XCTAssertNil(FleetInboxDeepLink.itemID(from: URL(string: "hermes-fleet://inbox?item=a%23b%20x%23c")!, scheme: "hermes-fleet"))
    }

    func testDenyFailedReplacementReusesIDAndOpensItemWithoutActions() {
        let pending = item()
        let replacement = InboxNotificationCatalog.denyFailedNotification(for: pending)
        XCTAssertEqual(replacement.id, InboxNotificationCatalog.notificationID(for: pending.id))
        XCTAssertEqual(replacement.categoryID, InboxNotificationCatalog.requestCategoryID)
        XCTAssertEqual(replacement.title, "Couldn't deny from here")
        XCTAssertEqual(replacement.body, "Open Hermes Fleet to answer.")
        XCTAssertEqual(replacement.userInfo, [InboxNotificationCatalog.itemIDKey: pending.id.rawValue])
        let request = InboxNotificationCatalog.categories.first { $0.id == InboxNotificationCatalog.requestCategoryID }
        XCTAssertEqual(request?.actions, [], "tap opens the item; no actions")
    }

    func testNotificationIDIsStablePerItem() {
        XCTAssertEqual(
            InboxNotificationCatalog.notificationID(for: item().id),
            InboxNotificationCatalog.notificationID(for: item(command: "changed").id))
    }

    // MARK: Seam defaults

    func testUnavailableNotifierFailsClosed() async {
        let notifier = UnavailableLocalNotifier()
        let status = await notifier.authorizationStatus()
        let granted = await notifier.requestAuthorization()
        XCTAssertEqual(status, .unavailable)
        XCTAssertFalse(granted)
    }
}
