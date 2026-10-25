import XCTest
import FleetCore
@testable import FleetUI

/// Fleet Home "Needs you": the inbox's pending items count and list, deduped
/// against Live Ops approval rows for the same gateway + session + request.
/// Synthetic fixtures only.
final class FleetHomeAttentionTests: XCTestCase {

    private let gateway = GatewayID(rawValue: "workstation")
    private let otherGateway = GatewayID(rawValue: "lab")

    private func makeInboxItem(
        request: String,
        session: String = "s1",
        gateway: GatewayID? = nil,
        status: InboxStatus = .pending,
        created: TimeInterval = 0
    ) -> InboxItem {
        let owner = gateway ?? self.gateway
        return InboxItem(
            id: InboxItemID(gatewayID: owner, sessionID: session, requestID: request),
            kind: .approval,
            requestID: request,
            status: status,
            agent: InboxAgentIdentity(
                gatewayID: owner, gatewayLabel: owner.rawValue, profileName: "default", sessionID: session),
            context: InboxContext(command: "ls ~/Projects", choices: ["once", "deny"]),
            serverRequestID: nil,
            createdAt: Date(timeIntervalSince1970: created))
    }

    private func makeLiveOpsRow(
        request: String,
        session: String = "s1",
        gateway: GatewayID? = nil,
        withApproval: Bool = true
    ) -> LiveOpsAttentionItem {
        let owner = gateway ?? self.gateway
        let operation = LiveOperation(
            id: LiveOperationID(gatewayID: owner, runtimeSessionID: session),
            sessionKey: "key-\(session)", title: "Op", preview: "preview", model: "m",
            startedAt: Date(timeIntervalSince1970: 1), lastActive: Date(timeIntervalSince1970: 2),
            messageCount: 1, status: .waiting)
        let approval = withApproval
            ? ApprovalRequest(requestID: request, sessionID: session, command: "ls ~/Projects")
            : nil
        return LiveOpsAttentionItem(operation: operation, pendingApproval: approval)
    }

    // MARK: Identity

    func testLiveOpsApprovalMapsToTheInboxIdentity() {
        let row = makeLiveOpsRow(request: "r1", session: "s9")
        XCTAssertEqual(
            FleetHomeAttention.inboxID(for: row),
            InboxItemID(gatewayID: gateway, sessionID: "s9", requestID: "r1"))
    }

    func testWaitingRowWithoutApprovalHasNoInboxIdentity() {
        XCTAssertNil(FleetHomeAttention.inboxID(for: makeLiveOpsRow(request: "r1", withApproval: false)))
    }

    // MARK: Dedupe

    func testPendingInboxItemWithoutALiveOpsRowIsListed() {
        let pending = makeInboxItem(request: "r-inbox")
        let listed = FleetHomeAttention.pendingInboxItems(inbox: [pending], liveOpsAttention: [])
        XCTAssertEqual(listed.map(\.id), [pending.id])
    }

    func testInboxItemAlreadyShownByLiveOpsIsNotCountedTwice() {
        let shared = makeInboxItem(request: "r1")
        let liveOps = makeLiveOpsRow(request: "r1")
        let listed = FleetHomeAttention.pendingInboxItems(inbox: [shared], liveOpsAttention: [liveOps])
        XCTAssertTrue(listed.isEmpty)

        let total = FleetHomeAttention.needsYouCount(
            attentionCount: 0, liveOpsCount: 1, inboxPendingCount: listed.count)
        XCTAssertEqual(total, 1, "one approval shown by Live Ops is one Needs you item")
    }

    func testSameRequestIdOnAnotherGatewayOrSessionIsNotDeduped() {
        let inboxOther = makeInboxItem(request: "r1", gateway: otherGateway)
        let inboxOtherSession = makeInboxItem(request: "r1", session: "s2")
        let liveOps = makeLiveOpsRow(request: "r1", session: "s1")
        let listed = FleetHomeAttention.pendingInboxItems(
            inbox: [inboxOther, inboxOtherSession], liveOpsAttention: [liveOps])
        XCTAssertEqual(Set(listed.map(\.id)), [inboxOther.id, inboxOtherSession.id])
    }

    func testResolvedInboxItemsAreNotNeedsYou() {
        let approved = makeInboxItem(request: "r-done", status: .approved, created: 5)
        let denied = makeInboxItem(request: "r-no", status: .denied, created: 6)
        let pending = makeInboxItem(request: "r-open", created: 7)
        let listed = FleetHomeAttention.pendingInboxItems(
            inbox: [approved, denied, pending], liveOpsAttention: [])
        XCTAssertEqual(listed.map(\.id), [pending.id])
    }

    func testPendingItemsListNewestFirst() {
        let older = makeInboxItem(request: "old", created: 100)
        let newer = makeInboxItem(request: "new", created: 200)
        let listed = FleetHomeAttention.pendingInboxItems(inbox: [older, newer], liveOpsAttention: [])
        XCTAssertEqual(listed.map(\.id), [newer.id, older.id])
    }

    // MARK: Count

    func testNeedsYouSumsEachSourceOnce() {
        XCTAssertEqual(
            FleetHomeAttention.needsYouCount(attentionCount: 1, liveOpsCount: 2, inboxPendingCount: 3), 6)
        XCTAssertEqual(
            FleetHomeAttention.needsYouCount(attentionCount: 0, liveOpsCount: 0, inboxPendingCount: 0), 0)
    }

    // MARK: Row copy

    func testRowShowsTheKindTitleAndSummaryWithoutARawSessionId() {
        let item = makeInboxItem(request: "r1")
        XCTAssertEqual(FleetHomeAttention.rowTitle(item), "Command approval")
        XCTAssertEqual(FleetHomeAttention.rowDetail(item), "ls ~/Projects · default · workstation")
        XCTAssertFalse(FleetHomeAttention.rowDetail(item).contains("s1"))
    }
}
