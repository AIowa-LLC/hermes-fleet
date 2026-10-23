import XCTest
import FleetCore
@testable import FleetUI

/// Phase B approvals inbox: the presenter rules behind the Inbox screen.
/// Synthetic fixtures only: no gateway, device, or live session is involved.
final class InboxPresentationTests: XCTestCase {

    private let workstation = GatewayID(rawValue: "workstation")

    private func makeItem(
        kind: InboxItemKind = .approval,
        status: InboxStatus = .pending,
        request: String = "r1",
        session: String = "s1",
        command: String? = "ls ~/Projects",
        detail: String? = nil,
        choices: [String] = ["once", "deny"],
        envVar: String? = nil,
        batch: Bool = false,
        profile: String? = "default",
        sessionTitle: String? = nil,
        created: TimeInterval = 0,
        updated: TimeInterval? = nil,
        failure: String? = nil
    ) -> InboxItem {
        let agent = InboxAgentIdentity(
            gatewayID: workstation,
            gatewayLabel: "Workstation",
            profileName: profile,
            sessionID: session,
            sessionTitle: sessionTitle)
        let context = InboxContext(
            command: command,
            detail: detail,
            choices: choices,
            envVarName: envVar,
            isBatchQuestion: batch)
        return InboxItem(
            id: InboxItemID(gatewayID: workstation, sessionID: session, requestID: request),
            kind: kind,
            requestID: request,
            status: status,
            agent: agent,
            context: context,
            serverRequestID: nil,
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: updated.map { Date(timeIntervalSince1970: $0) },
            failureMessage: failure)
    }

    // MARK: Sections

    func testPendingComesFirstNewestFirstThenHistoryMostRecentlyResolvedFirst() {
        let oldPending = makeItem(request: "p-old", created: 100)
        let newPending = makeItem(request: "p-new", created: 300)
        let olderResolved = makeItem(status: .approved, request: "h-a", created: 10, updated: 150)
        let newerResolved = makeItem(status: .denied, request: "h-b", created: 20, updated: 400)

        let sections = FleetInboxPresentation.sections([oldPending, olderResolved, newerResolved, newPending])

        XCTAssertEqual(sections.pending.map(\.requestID), ["p-new", "p-old"])
        XCTAssertEqual(sections.history.map(\.requestID), ["h-b", "h-a"])
        XCTAssertEqual(FleetInboxPresentation.pendingCount([oldPending, olderResolved, newPending]), 2)
    }

    // MARK: Row copy

    func testApprovalSummaryIsTheFirstLineOfTheCommand() {
        let item = makeItem(command: "rm -rf build\necho done")
        XCTAssertEqual(FleetInboxPresentation.actionSummary(item), "rm -rf build")
        XCTAssertTrue(FleetInboxPresentation.summaryIsCommand(item))
    }

    func testSecretSummaryNamesTheVariableAndNeverCarriesAValue() {
        let named = makeItem(kind: .secret, command: nil, envVar: "GITHUB_TOKEN")
        XCTAssertEqual(FleetInboxPresentation.actionSummary(named), "Secret requested: GITHUB_TOKEN")
        XCTAssertFalse(FleetInboxPresentation.summaryIsCommand(named))

        let unnamed = makeItem(kind: .secret, command: nil, envVar: "   ")
        XCTAssertEqual(FleetInboxPresentation.actionSummary(unnamed), "Secret requested")
    }

    func testQuestionSummaryIsTheQuestionText() {
        let item = makeItem(kind: .question, command: nil, detail: "Which branch?\nAnd why?", choices: ["main"])
        XCTAssertEqual(FleetInboxPresentation.actionSummary(item), "Which branch?")
    }

    func testSudoSummaryFallsBackToAPlainPromptWithoutCommand() {
        let item = makeItem(kind: .sudo, command: nil)
        XCTAssertEqual(FleetInboxPresentation.actionSummary(item), "Sudo password requested")
    }

    func testAgentLineIsProfileThenGatewayAndFallsBackToBot() {
        XCTAssertEqual(FleetInboxPresentation.agentLine(makeItem(profile: "research")), "research · Workstation")
        XCTAssertEqual(FleetInboxPresentation.agentLine(makeItem(profile: nil)), "Bot · Workstation")
    }

    func testSessionLineUsesTheTitleOrAShortId() {
        XCTAssertEqual(FleetInboxPresentation.sessionLine(makeItem(sessionTitle: "Nightly sync")), "Nightly sync")
        XCTAssertEqual(
            FleetInboxPresentation.sessionLine(makeItem(session: "abcdef123456", sessionTitle: nil)),
            "abcdef12")
    }

    // MARK: Status and dimming

    func testExpiredAndCancelledRowsCarryTheirReason() {
        let bare = makeItem(status: .expired, updated: 5)
        XCTAssertEqual(FleetInboxPresentation.chip(for: bare).text, "Expired")
        XCTAssertEqual(FleetInboxPresentation.dimmedReason(bare), "Expired")
        XCTAssertTrue(FleetInboxPresentation.isDimmed(bare))

        let elsewhere = makeItem(status: .expired, updated: 5, failure: "already answered elsewhere")
        XCTAssertEqual(FleetInboxPresentation.chip(for: elsewhere).text, "Answered elsewhere")
        XCTAssertEqual(FleetInboxPresentation.dimmedReason(elsewhere), "Answered elsewhere")

        let withdrawn = makeItem(status: .cancelled, updated: 5)
        XCTAssertEqual(FleetInboxPresentation.dimmedReason(withdrawn), "Withdrawn by agent")
        XCTAssertTrue(FleetInboxPresentation.isDimmed(withdrawn))
    }

    func testResolvedAndPendingRowsAreNotDimmed() {
        for status in [InboxStatus.pending, .approved, .denied, .answered, .failed] {
            let item = makeItem(status: status)
            XCTAssertFalse(FleetInboxPresentation.isDimmed(item), "\(status)")
            XCTAssertNil(FleetInboxPresentation.dimmedReason(item), "\(status)")
        }
    }

    func testFailedRowShowsTheSafeFailureNote() {
        let item = makeItem(status: .failed, failure: "  Gateway rejected the request.  ")
        XCTAssertEqual(FleetInboxPresentation.chip(for: item).tone, .destructive)
        XCTAssertEqual(FleetInboxPresentation.failureNote(item), "Gateway rejected the request.")
        XCTAssertNil(FleetInboxPresentation.failureNote(makeItem(status: .failed)))
    }

    // MARK: Availability

    func testReachablePendingApprovalOffersApproveAndDeny() {
        let availability = FleetInboxPresentation.availability(for: makeItem(), reachable: true)
        XCTAssertTrue(availability.canApprove)
        XCTAssertTrue(availability.canDeny)
        XCTAssertFalse(availability.canAnswer)
    }

    func testOfflineDisablesEveryDecision() {
        XCTAssertEqual(
            FleetInboxPresentation.availability(for: makeItem(), reachable: false),
            .none)
        XCTAssertEqual(
            FleetInboxPresentation.availability(for: makeItem(kind: .question, command: nil, detail: "Q?"), reachable: false),
            .none)
    }

    func testResolvedItemsOfferNothing() {
        XCTAssertEqual(
            FleetInboxPresentation.availability(for: makeItem(status: .approved), reachable: true),
            .none)
    }

    func testBatchQuestionIsAnsweredOnlyInItsSession() {
        let batch = makeItem(kind: .question, command: nil, detail: "Q1\nQ2", choices: [], batch: true)
        let availability = FleetInboxPresentation.availability(for: batch, reachable: true)
        XCTAssertTrue(availability.answersInSessionOnly)
        XCTAssertFalse(availability.canAnswer)
        XCTAssertFalse(availability.canApprove)
    }

    func testSecretAndSudoAcceptAnAnswerWhenReachable() {
        for kind in [InboxItemKind.secret, .sudo, .question] {
            let availability = FleetInboxPresentation.availability(
                for: makeItem(kind: kind, command: nil, detail: "x"), reachable: true)
            XCTAssertTrue(availability.canAnswer, "\(kind)")
        }
    }

    func testApproveScopesFollowTheGatewayOffer() {
        XCTAssertEqual(FleetInboxPresentation.approveChoices(for: makeItem(choices: ["once", "deny"])), [.once])
        XCTAssertEqual(
            FleetInboxPresentation.approveChoices(for: makeItem(choices: ["once", "session", "always", "deny"])),
            [.once, .session, .always])
        XCTAssertEqual(FleetInboxPresentation.approveTitle(.session), "Approve for this session")
    }

    func testElidedCommandRequiresFullReview() {
        let short = makeItem(command: "ls")
        XCTAssertFalse(FleetInboxPresentation.requiresReview(short))

        let long = makeItem(command: Array(repeating: "echo filler line", count: 12).joined(separator: "\n"))
        XCTAssertTrue(FleetInboxPresentation.requiresReview(long))

        XCTAssertFalse(FleetInboxPresentation.requiresReview(makeItem(kind: .sudo, command: "sudo ls")))
    }

    func testOfflineIsTheAbsenceOfAConnectedGateway() {
        let connected = FleetInboxPresentation.connectedGatewayIDs(
            gatewayIDs: [workstation, GatewayID(rawValue: "render-box")],
            state: { $0 == workstation ? .connected : .idle })
        XCTAssertEqual(connected, [workstation])
        XCTAssertFalse(FleetInboxPresentation.isOffline(connected: connected))
        XCTAssertTrue(FleetInboxPresentation.isOffline(connected: []))
    }

    // MARK: Errors

    func testErrorsAreInPlainLanguageAndNeverEchoTheCommand() {
        XCTAssertEqual(
            FleetInboxPresentation.message(for: InboxError.reviewRequired),
            "Review the full command before approving.")
        XCTAssertEqual(
            FleetInboxPresentation.message(for: InboxError.presenceNotVerified(.cancelled)),
            "Approval was cancelled. Nothing was sent.")
        XCTAssertTrue(FleetInboxPresentation.message(for: InboxError.gatewayUnavailable).contains("Nothing was sent"))
        XCTAssertEqual(
            FleetInboxPresentation.message(for: InboxError.gatewayRejected("Gateway timed out.")),
            "Gateway timed out.")
        XCTAssertEqual(
            FleetInboxPresentation.message(for: InboxError.gatewayRejected("   ")),
            "The gateway didn't accept this. Try again.")
        XCTAssertFalse(FleetInboxPresentation.message(for: InboxError.notFound).contains("ls ~/Projects"))
    }

    func testUnavailableGatewayForLiveRequestAsksForTheOpenSession() {
        // A live server request is answered only from its open conversation.
        var live = makeItem()
        live = InboxItem(
            id: live.id, kind: .approval, requestID: live.requestID, status: .pending,
            agent: live.agent, context: live.context, serverRequestID: "srq-1",
            createdAt: live.createdAt)
        XCTAssertTrue(FleetInboxPresentation.needsOpenSession(InboxError.gatewayUnavailable, item: live))
        XCTAssertFalse(FleetInboxPresentation.needsOpenSession(InboxError.notFound, item: live))

        // A legacy approval (no server request id) keeps the generic copy.
        XCTAssertFalse(FleetInboxPresentation.needsOpenSession(InboxError.gatewayUnavailable, item: makeItem()))
        XCTAssertTrue(FleetInboxPresentation.openSessionToAnswerMessage.contains("Open the session"))
    }

    // MARK: Audit

    func testDeciderIsYouOnThisDeviceUnlessAnOwnerIsNamed() {
        let mine = InboxDecider.thisDevice(ownerName: nil)
        XCTAssertEqual(FleetInboxPresentation.deciderTitle(mine), "You on this device")
        let other = InboxDecider(deviceLabel: "iPad", ownerName: "Sam")
        XCTAssertEqual(FleetInboxPresentation.deciderTitle(other), "Sam")
        let anonymous = InboxDecider(deviceLabel: "iPad", ownerName: nil)
        XCTAssertEqual(FleetInboxPresentation.deciderTitle(anonymous), "iPad")
    }

    func testOutcomeWordingMarksFailures() {
        XCTAssertEqual(FleetInboxPresentation.outcomeTitle(.succeeded), "Accepted by gateway")
        XCTAssertTrue(FleetInboxPresentation.outcomeFailed(.failed(message: "nope")))
        XCTAssertFalse(FleetInboxPresentation.outcomeFailed(.succeeded))
        XCTAssertEqual(FleetInboxPresentation.actionTitle(.approveAlways), "Approved always")
    }

    func testAuditRecordsFilterToTheItem() {
        let target = makeItem(request: "target")
        let other = makeItem(request: "other")
        let records = [
            InboxDecisionRecord(
                itemID: target.id, kind: .approval, action: .deny, gatewayID: workstation,
                sessionID: "s1", agentLabel: "Workstation",
                decider: .thisDevice(ownerName: nil), decidedAt: Date(timeIntervalSince1970: 9),
                outcome: .succeeded),
            InboxDecisionRecord(
                itemID: other.id, kind: .approval, action: .approveOnce, gatewayID: workstation,
                sessionID: "s1", agentLabel: "Workstation",
                decider: .thisDevice(ownerName: nil), decidedAt: Date(timeIntervalSince1970: 8),
                outcome: .succeeded),
        ]
        XCTAssertEqual(FleetInboxPresentation.audit(records, for: target.id).map(\.action), [.deny])
    }

    // MARK: Deep link

    // One parser (FleetCore `FleetInboxDeepLink`) serves onOpenURL and the
    // notification Review/tap path; these pin its behavior at the app level.
    private let linkScheme = "hermes-fleet"

    func testInboxLinkRoundTripsAnItemFocus() throws {
        let itemID = InboxItemID(gatewayID: workstation, sessionID: "s1", requestID: "r1")
        let url = try XCTUnwrap(FleetInboxDeepLink.url(scheme: linkScheme, itemID: itemID))
        XCTAssertEqual(FleetInboxDeepLink.target(from: url, scheme: linkScheme), FleetInboxDeepLink.Target(itemID: itemID))
    }

    func testBareInboxLinkOpensWithoutFocus() throws {
        let url = try XCTUnwrap(FleetInboxDeepLink.url(scheme: linkScheme))
        XCTAssertEqual(FleetInboxDeepLink.target(from: url, scheme: linkScheme), FleetInboxDeepLink.Target(itemID: nil))
    }

    func testMalformedItemIdOpensInboxWithoutFocus() throws {
        let malformed = try XCTUnwrap(URL(string: "\(linkScheme)://inbox?item=not-a-composite-id"))
        XCTAssertEqual(FleetInboxDeepLink.target(from: malformed, scheme: linkScheme), FleetInboxDeepLink.Target(itemID: nil))
        let spaced = try XCTUnwrap(URL(string: "\(linkScheme)://inbox?item=a%20b%23c%23d"))
        XCTAssertEqual(FleetInboxDeepLink.target(from: spaced, scheme: linkScheme), FleetInboxDeepLink.Target(itemID: nil))
    }

    func testOtherLinksAreNotInboxLinks() throws {
        XCTAssertNil(FleetInboxDeepLink.target(
            from: try XCTUnwrap(URL(string: "\(linkScheme)://conversation?gateway=x")), scheme: linkScheme))
        XCTAssertNil(FleetInboxDeepLink.target(
            from: try XCTUnwrap(URL(string: "https://example.invalid/inbox")), scheme: linkScheme))
        // A link for another build's scheme is not this app's inbox.
        XCTAssertNil(FleetInboxDeepLink.target(
            from: try XCTUnwrap(URL(string: "hermes-fleet-dev://inbox")), scheme: linkScheme))
    }
}
