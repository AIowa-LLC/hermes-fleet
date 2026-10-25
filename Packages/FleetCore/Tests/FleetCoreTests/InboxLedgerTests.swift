import XCTest
@testable import FleetCore

final class InboxLedgerTests: XCTestCase {
    private let gateway = GatewayID(rawValue: "gw-a")
    private let otherGateway = GatewayID(rawValue: "gw-b")
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func agent(_ gw: GatewayID = GatewayID(rawValue: "gw-a"), session: String = "s1") -> InboxAgentIdentity {
        InboxAgentIdentity(gatewayID: gw, gatewayLabel: "Synthetic Gateway", sessionID: session)
    }

    private func approval(
        _ requestID: String,
        session: String = "s1",
        gw: GatewayID? = nil,
        at: Date
    ) -> InboxItem {
        let request = ApprovalRequest(
            requestID: requestID,
            sessionID: session,
            command: "echo synthetic",
            detail: "synthetic danger",
            choices: ["once", "deny"],
            serverRequestID: "srq-\(requestID)")
        return InboxItem.approval(from: request, agent: agent(gw ?? gateway, session: session), at: at)
    }

    // MARK: Identity

    func testItemIDIsDerivedFromGatewaySessionAndRequest() {
        let a = InboxItemID(gatewayID: gateway, sessionID: "s1", requestID: "r1")
        let b = InboxItemID(gatewayID: gateway, sessionID: "s1", requestID: "r1")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, InboxItemID(gatewayID: otherGateway, sessionID: "s1", requestID: "r1"))
        XCTAssertNotEqual(a, InboxItemID(gatewayID: gateway, sessionID: "s2", requestID: "r1"))
        XCTAssertNotEqual(a, InboxItemID(gatewayID: gateway, sessionID: "s1", requestID: "r2"))
    }

    func testRedeliveryOfSameRequestCollapsesToOneItem() {
        var ledger = InboxLedger()
        XCTAssertEqual(ledger.ingest(approval("r1", at: t0)), .inserted)
        // Legacy event and server request for the same approval: same item.
        let later = t0.addingTimeInterval(5)
        XCTAssertEqual(ledger.ingest(approval("r1", at: later)), .refreshed)
        XCTAssertEqual(ledger.pending.count, 1)
        // createdAt is kept so FIFO order survives re-delivery.
        XCTAssertEqual(ledger.item(approval("r1", at: t0).id)?.createdAt, t0)
    }

    func testSameRequestIDOnTwoGatewaysIsTwoItems() {
        var ledger = InboxLedger()
        ledger.ingest(approval("r1", at: t0))
        ledger.ingest(approval("r1", gw: otherGateway, at: t0))
        XCTAssertEqual(ledger.pending.count, 2)
    }

    // MARK: Transitions

    func testResolveOnlyMovesPendingItems() {
        var ledger = InboxLedger()
        let item = approval("r1", at: t0)
        ledger.ingest(item)
        XCTAssertTrue(ledger.resolve(item.id, as: .approved, at: t0.addingTimeInterval(1)))
        XCTAssertEqual(ledger.item(item.id)?.status, .approved)
        // A late second answer or a late cancel cannot change a settled item.
        XCTAssertFalse(ledger.resolve(item.id, as: .denied, at: t0.addingTimeInterval(2)))
        XCTAssertNil(ledger.cancel(gatewayID: gateway, sessionID: "s1", wireRequestID: "srq-r1", at: t0.addingTimeInterval(3)))
        XCTAssertEqual(ledger.item(item.id)?.status, .approved)
    }

    func testIngestNeverResurrectsTerminalItem() {
        var ledger = InboxLedger()
        let item = approval("r1", at: t0)
        ledger.ingest(item)
        ledger.resolve(item.id, as: .denied, at: t0.addingTimeInterval(1))
        XCTAssertEqual(ledger.ingest(approval("r1", at: t0.addingTimeInterval(2))), .ignoredTerminal)
        XCTAssertEqual(ledger.item(item.id)?.status, .denied)
        XCTAssertTrue(ledger.pending.isEmpty)
    }

    func testIngestRejectsNonPendingIncoming() {
        var ledger = InboxLedger()
        var item = approval("r1", at: t0)
        item.status = .expired
        XCTAssertEqual(ledger.ingest(item), .ignoredTerminal)
        XCTAssertNil(ledger.item(item.id))
    }

    func testCancelUsesWireIDAndIsNotDenial() {
        var ledger = InboxLedger()
        let item = approval("r1", at: t0)
        ledger.ingest(item)
        XCTAssertEqual(ledger.cancel(gatewayID: gateway, sessionID: "s1", wireRequestID: "srq-r1", at: t0.addingTimeInterval(1)), item.id)
        XCTAssertEqual(ledger.item(item.id)?.status, .cancelled)
        XCTAssertNotEqual(ledger.item(item.id)?.status, .denied)
    }

    func testCancelMatchesGatewayRequestIDForLegacyApproval() {
        var ledger = InboxLedger()
        let legacy = InboxItem.approval(
            from: ApprovalRequest(requestID: "r9", sessionID: "s1", command: "x"),
            agent: agent(), at: t0)
        ledger.ingest(legacy)
        XCTAssertEqual(ledger.cancel(gatewayID: gateway, sessionID: "s1", wireRequestID: "r9", at: t0.addingTimeInterval(1)), legacy.id)
    }

    func testWithdrawalWithReusedWireIDIsScopedToGatewayAndSession() {
        var ledger = InboxLedger()
        let first = approval("r1", at: t0)
        let secondSession = approval("r1", session: "s2", at: t0)
        let secondGateway = approval("r1", gw: otherGateway, at: t0)
        for item in [first, secondSession, secondGateway] { ledger.ingest(item) }

        XCTAssertEqual(ledger.cancel(gatewayID: otherGateway, sessionID: "s1", wireRequestID: "srq-r1", at: t0), secondGateway.id)
        XCTAssertEqual(ledger.item(first.id)?.status, .pending)
        XCTAssertEqual(ledger.item(secondSession.id)?.status, .pending)
        XCTAssertEqual(ledger.cancel(gatewayID: gateway, sessionID: "s2", wireRequestID: "srq-r1", at: t0), secondSession.id)
        XCTAssertEqual(ledger.item(first.id)?.status, .pending)
    }

    func testSessionlessWithdrawalRequiresUniqueMatchWithinGateway() {
        var ledger = InboxLedger()
        let first = approval("r1", at: t0)
        let secondSession = approval("r1", session: "s2", at: t0)
        let secondGateway = approval("r1", gw: otherGateway, at: t0)
        for item in [first, secondSession, secondGateway] { ledger.ingest(item) }

        XCTAssertNil(ledger.cancel(gatewayID: gateway, sessionID: nil, wireRequestID: "srq-r1", at: t0))
        XCTAssertEqual(ledger.pendingCount, 3, "Missing session scope must not select an arbitrary request")
        XCTAssertEqual(ledger.cancel(gatewayID: otherGateway, sessionID: nil, wireRequestID: "srq-r1", at: t0), secondGateway.id)
        XCTAssertEqual(ledger.item(first.id)?.status, .pending)
        XCTAssertEqual(ledger.item(secondSession.id)?.status, .pending)
    }

    func testReconcileExpiresOnlyPendingItemsMissingFromGateway() {
        var ledger = InboxLedger()
        ledger.ingest(approval("r1", at: t0))
        ledger.ingest(approval("r2", at: t0))
        ledger.ingest(approval("r3", session: "s2", at: t0))
        let expired = ledger.reconcile(
            gatewayID: gateway, sessionID: "s1", livePendingRequestIDs: ["r2"], at: t0.addingTimeInterval(9))
        XCTAssertEqual(expired, [InboxItemID(gatewayID: gateway, sessionID: "s1", requestID: "r1")])
        XCTAssertEqual(ledger.item(expired[0])?.status, .expired)
        // Other session untouched.
        XCTAssertEqual(ledger.pending.map(\.requestID).sorted(), ["r2", "r3"])
    }

    func testRemoveGatewayFailsItsPendingItems() {
        var ledger = InboxLedger()
        ledger.ingest(approval("r1", at: t0))
        ledger.ingest(approval("r2", gw: otherGateway, at: t0))
        ledger.removeGateway(gateway, at: t0.addingTimeInterval(1))
        XCTAssertEqual(ledger.pending.map(\.requestID), ["r2"])
        let failed = ledger.items.values.first { $0.requestID == "r1" }
        XCTAssertEqual(failed?.status, .failed)
        XCTAssertEqual(failed?.failureMessage, "gateway removed")
    }

    func testExpireDueUsesGatewayIndicatedExpiryOnly() {
        var ledger = InboxLedger()
        var due = approval("r1", at: t0)
        due.expiresAt = t0.addingTimeInterval(10)
        ledger.ingest(due)
        ledger.ingest(approval("r2", at: t0))
        let expired = ledger.expireDue(at: t0.addingTimeInterval(11))
        XCTAssertEqual(expired, [due.id])
        XCTAssertEqual(ledger.pending.map(\.requestID), ["r2"])
    }

    func testExpireUnattendedOnlyAfterMaxAgeAndOnlyForDetachedGateways() {
        var ledger = InboxLedger()
        ledger.ingest(approval("r1", at: t0))
        ledger.ingest(approval("r2", gw: otherGateway, at: t0))
        // Within the window nothing expires.
        XCTAssertTrue(ledger.expireUnattended(attachedGateways: [], at: t0.addingTimeInterval(60), maxAge: 3600).isEmpty)
        // Past the window: only the detached gateway's item goes.
        let expired = ledger.expireUnattended(attachedGateways: [otherGateway], at: t0.addingTimeInterval(7200), maxAge: 3600)
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(ledger.pending.map(\.requestID), ["r2"])
    }

    func testRecordFailureKeepsItemPending() {
        var ledger = InboxLedger()
        let item = approval("r1", at: t0)
        ledger.ingest(item)
        ledger.recordFailure(item.id, message: "connection closed", at: t0.addingTimeInterval(1))
        XCTAssertEqual(ledger.item(item.id)?.status, .pending)
        XCTAssertEqual(ledger.item(item.id)?.failureMessage, "connection closed")
    }

    // MARK: Ordering

    func testOrderingPendingFIFOThenHistoryNewestFirst() {
        var ledger = InboxLedger()
        let a = approval("a", at: t0)
        let b = approval("b", at: t0.addingTimeInterval(1))
        let c = approval("c", at: t0.addingTimeInterval(2))
        [a, b, c].forEach { ledger.ingest($0) }
        ledger.resolve(a.id, as: .approved, at: t0.addingTimeInterval(10))
        ledger.resolve(c.id, as: .denied, at: t0.addingTimeInterval(20))
        XCTAssertEqual(ledger.ordered.map(\.requestID), ["b", "c", "a"])
    }

    // MARK: Caps

    func testTerminalHistoryIsCapped() {
        var ledger = InboxLedger()
        let total = InboxLedger.maxTerminalItems + 50
        for index in 0..<total {
            let item = approval("r\(index)", at: t0.addingTimeInterval(Double(index)))
            ledger.ingest(item)
            ledger.resolve(item.id, as: .approved, at: t0.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(ledger.items.count, InboxLedger.maxTerminalItems)
        // The most recently updated history survives.
        XCTAssertNotNil(ledger.items[InboxItemID(gatewayID: gateway, sessionID: "s1", requestID: "r\(total - 1)")])
        XCTAssertNil(ledger.items[InboxItemID(gatewayID: gateway, sessionID: "s1", requestID: "r0")])
    }

    func testPendingOverflowExpiresOldestVisibly() {
        var ledger = InboxLedger()
        for index in 0...InboxLedger.maxPendingItems {
            ledger.ingest(approval("p\(index)", at: t0.addingTimeInterval(Double(index))))
        }
        XCTAssertEqual(ledger.pending.count, InboxLedger.maxPendingItems)
        let oldest = ledger.items[InboxItemID(gatewayID: gateway, sessionID: "s1", requestID: "p0")]
        XCTAssertEqual(oldest?.status, .expired)
        XCTAssertEqual(oldest?.failureMessage, "inbox full")
    }

    func testAuditRetentionDropsOldAndCapsCount() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        func record(_ age: TimeInterval, _ n: Int) -> InboxDecisionRecord {
            InboxDecisionRecord(
                itemID: InboxItemID(rawValue: "i\(n)"), kind: .approval, action: .deny,
                gatewayID: gateway, sessionID: "s1", agentLabel: "G",
                decider: .thisDevice(ownerName: nil), decidedAt: now.addingTimeInterval(-age),
                outcome: .succeeded)
        }
        let old = record(InboxLedger.auditRetention + 1, 0)
        var many: [InboxDecisionRecord] = [old]
        for n in 1...(InboxLedger.maxAuditRecords + 20) { many.append(record(TimeInterval(n), n)) }
        let kept = InboxLedger.retainedAudit(many, now: now)
        XCTAssertEqual(kept.count, InboxLedger.maxAuditRecords)
        XCTAssertFalse(kept.contains(old))
        XCTAssertEqual(kept.first?.decidedAt, now.addingTimeInterval(-1))
    }

    // MARK: Wire mapping

    func testFeedEventMapsConversationEvents() {
        let request = ServerRequest(id: "srq-1", sessionID: "s1",
                                    kind: .approval(ApprovalRequest(requestID: "r1", sessionID: "s1", command: "c", serverRequestID: "srq-1")))
        XCTAssertEqual(InboxFeedEvent(conversationEvent: .serverRequest(request)), .serverRequest(request))
        XCTAssertEqual(
            InboxFeedEvent(conversationEvent: .approvalRequested(sessionID: "s1", requestID: "r2", command: "c", detail: nil, choices: ["once"])),
            .legacyApproval(ApprovalRequest(requestID: "r2", sessionID: "s1", command: "c", choices: ["once"])))
        XCTAssertEqual(
            InboxFeedEvent(conversationEvent: .requestCancelled(sessionID: "s1", requestID: "srq-1", method: "approval", reason: "timeout")),
            .withdrawn(sessionID: "s1", wireRequestID: "srq-1"))
        XCTAssertEqual(
            InboxFeedEvent(conversationEvent: .requestCancelled(sessionID: nil, requestID: "srq-1", method: "approval", reason: "timeout")),
            .withdrawn(sessionID: nil, wireRequestID: "srq-1"))
        XCTAssertNil(InboxFeedEvent(conversationEvent: .error(sessionID: "s1", message: "x")))
    }

    func testMakeItemForEachRequestKindNeverCarriesSecretValue() {
        let secret = ServerRequest(id: "srq-s", sessionID: "s1",
                                   kind: .secret(SecretPrompt(sessionID: "s1", envVar: "SYNTHETIC_TOKEN", prompt: "Enter it")))
        let item = InboxItem.make(from: secret, agent: agent(), at: t0)
        XCTAssertEqual(item.kind, .secret)
        XCTAssertEqual(item.context.envVarName, "SYNTHETIC_TOKEN")
        XCTAssertNil(item.context.command)
        XCTAssertEqual(item.requestID, "srq-s")

        let batch = ServerRequest(id: "srq-c", sessionID: "s1", kind: .clarify(ClarifyPrompt(
            sessionID: "s1",
            questions: [ClarifyQuestion(qid: "q1", question: "Which?", choices: ["a", "b"])],
            isBatch: true)))
        let clarify = InboxItem.make(from: batch, agent: agent(), at: t0)
        XCTAssertEqual(clarify.kind, .question)
        XCTAssertTrue(clarify.context.isBatchQuestion)
        XCTAssertTrue(clarify.context.choices.isEmpty)
    }

    func testRestoreMergesWithoutOverwritingLiveState() {
        var ledger = InboxLedger()
        // A live event arrives before the persisted snapshot finishes loading.
        let live = approval("r1", at: t0.addingTimeInterval(5))
        ledger.ingest(live)
        ledger.resolve(live.id, as: .approved, at: t0.addingTimeInterval(6))

        // The older persisted copy of r1 (still pending) and a distinct r2.
        ledger.restore([approval("r1", at: t0), approval("r2", at: t0)])

        XCTAssertEqual(ledger.item(live.id)?.status, .approved, "live state wins over the restored copy")
        XCTAssertEqual(ledger.pending.map(\.requestID), ["r2"], "items missing live are restored")
    }

    func testDecisionActionNeverCarriesValues() {
        XCTAssertEqual(InboxDecisionAction(.approve(.always)), .approveAlways)
        XCTAssertEqual(InboxDecisionAction(.approve(.deny)), .deny)
        XCTAssertEqual(InboxDecisionAction(.answer("hunter2")), .answer)
        XCTAssertEqual(InboxDecisionAction(.skip), .skip)
    }
}
