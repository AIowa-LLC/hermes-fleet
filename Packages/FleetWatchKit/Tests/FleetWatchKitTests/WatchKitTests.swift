import XCTest
@testable import FleetWatchKit

final class FreshnessTests: XCTestCase {
    func testWindows() {
        let now = Fx.t0
        XCTAssertEqual(WatchFreshnessPolicy.freshness(observedAt: nil, now: now), .none)
        XCTAssertEqual(WatchFreshnessPolicy.freshness(observedAt: now.addingTimeInterval(-30), now: now), .fresh)
        XCTAssertEqual(WatchFreshnessPolicy.freshness(observedAt: now.addingTimeInterval(-200), now: now), .aging)
        XCTAssertEqual(WatchFreshnessPolicy.freshness(observedAt: now.addingTimeInterval(-3600), now: now), .stale)
    }

    func testAgeLabelNeverClaimsFreshWhenOld() {
        let now = Fx.t0
        XCTAssertEqual(WatchFreshnessPolicy.ageLabel(observedAt: nil, now: now), "never observed")
        XCTAssertEqual(WatchFreshnessPolicy.ageLabel(observedAt: now.addingTimeInterval(-5), now: now), "just now")
        XCTAssertEqual(WatchFreshnessPolicy.ageLabel(observedAt: now.addingTimeInterval(-180), now: now), "3m ago")
        XCTAssertEqual(WatchFreshnessPolicy.ageLabel(observedAt: now.addingTimeInterval(-7300), now: now), "2h ago")
    }
}

final class ApprovalPolicyTests: XCTestCase {
    func testShortCommandOffersDenyAndApproveOnce() {
        XCTAssertEqual(WatchApprovalPolicy.affordance(for: Fx.approval(), snapshotBuiltAt: Fx.t0, now: Fx.t0.addingTimeInterval(10)),
                       .denyOrApproveOnce)
    }

    func testLongCommandHandsOffToPhone() {
        guard case .denyOnly = WatchApprovalPolicy.affordance(for: Fx.approval(full: true), snapshotBuiltAt: Fx.t0, now: Fx.t0) else {
            return XCTFail("long command must not be approvable on the Watch")
        }
    }

    func testChoicesWithoutOnceHandOff() {
        guard case .denyOnly = WatchApprovalPolicy.affordance(for: Fx.approval(choices: ["always", "deny"]), snapshotBuiltAt: Fx.t0, now: Fx.t0) else {
            return XCTFail("approve-once absent => no Watch approve")
        }
    }

    func testStaleSnapshotOffersNothing() {
        guard case .none = WatchApprovalPolicy.affordance(for: Fx.approval(), snapshotBuiltAt: Fx.t0, now: Fx.t0.addingTimeInterval(600)) else {
            return XCTFail("stale snapshot must not be actionable")
        }
    }

    func testRevalidator() {
        let a = Fx.approval()
        let req = Fx.approvalRequest(a, .approveOnce)
        XCTAssertEqual(WatchApprovalRevalidator.validate(request: req, currentCommandDigest: a.commandDigest, stillPending: true), .proceed)
        XCTAssertEqual(WatchApprovalRevalidator.validate(request: req, currentCommandDigest: nil, stillPending: false), .alreadyResolved)
        XCTAssertEqual(WatchApprovalRevalidator.validate(request: req, currentCommandDigest: WatchCodec.digest("rm -rf /"), stillPending: true), .changed)
    }

    func testLedgerBlocksDuplicateUUIDAndConcurrentAndRepeatAfterApply() {
        var ledger = WatchApprovalLedger()
        let a = Fx.approval()
        let first = Fx.approvalRequest(a, .approveOnce, uuid: "u1")
        XCTAssertEqual(ledger.admit(first), .admit)
        XCTAssertEqual(ledger.admit(first), .duplicate(.inFlight))
        XCTAssertEqual(ledger.admit(Fx.approvalRequest(a, .approveOnce, uuid: "u2")), .busy)
        ledger.finish(first, outcome: .applied)
        XCTAssertEqual(ledger.admit(Fx.approvalRequest(a, .approveOnce, uuid: "u3")), .alreadyFinished(.applied))
        XCTAssertEqual(ledger.admit(first), .duplicate(.finished(.applied)))
    }

    func testLedgerAllowsRetryAfterHandOff() {
        var ledger = WatchApprovalLedger()
        let a = Fx.approval()
        let first = Fx.approvalRequest(a, .approveOnce, uuid: "u1")
        XCTAssertEqual(ledger.admit(first), .admit)
        ledger.finish(first, outcome: .handOffToPhone(reason: "presence"))
        XCTAssertEqual(ledger.admit(Fx.approvalRequest(a, .approveOnce, uuid: "u2")), .admit)
    }
}

final class ContextTests: XCTestCase {
    private func snapshot() -> WatchSnapshot {
        let scoutChats = [WatchConversation(id: "main1", title: "Main", isMain: true), WatchConversation(id: "c2", title: "Docs")]
        return Fx.snapshot(gateways: [
            Fx.gateway("mac-mini", name: "Mac mini", bots: [Fx.bot("mac-mini", "scout", name: "Scout", chats: scoutChats)]),
            Fx.gateway("nas", name: "NAS", bots: [Fx.bot("nas", "scout", name: "Scout (NAS)")])
        ])
    }

    func testResolvesFullPath() {
        let r = WatchContextResolver.resolve(.init(gatewayID: "mac-mini", profileSlug: "scout", conversationID: "c2"), in: snapshot())
        XCTAssertTrue(r.isFullyTargeted)
        XCTAssertEqual(WatchContextResolver.label(for: r), "Mac mini › Scout › Docs")
    }

    func testSameSlugOnTwoGatewaysIsNotConfused() {
        let r = WatchContextResolver.resolve(.init(gatewayID: "nas", profileSlug: "scout"), in: snapshot())
        XCTAssertEqual(WatchContextResolver.label(for: r), "NAS › Scout (NAS)")
    }

    func testRemovedTargetsNeverFallBack() {
        let s = snapshot()
        XCTAssertEqual(WatchContextResolver.resolve(.init(gatewayID: "gone"), in: s), .gatewayMissing(gatewayID: "gone"))
        guard case .botMissing = WatchContextResolver.resolve(.init(gatewayID: "nas", profileSlug: "nope"), in: s) else { return XCTFail() }
        guard case .conversationMissing = WatchContextResolver.resolve(.init(gatewayID: "mac-mini", profileSlug: "scout", conversationID: "deleted"), in: s) else { return XCTFail() }
        XCTAssertFalse(WatchContextResolver.resolve(.init(gatewayID: "gone"), in: s).isFullyTargeted)
    }
}

final class OutboxTests: XCTestCase {
    func testLifecycleAckOnlyOnReply() {
        var box = WatchMessageOutbox()
        let m = Fx.message("m1")
        XCTAssertTrue(box.enqueue(m, targetLabel: "Mac mini › Scout", now: Fx.t0))
        XCTAssertEqual(box.messages[0].state, .queued)
        box.markSent("m1", now: Fx.t0)
        XCTAssertEqual(box.messages[0].state, .sentToPhone)
        box.apply(.init(clientMessageID: "m1", outcome: .acknowledged), now: Fx.t0)
        XCTAssertEqual(box.messages[0].state, .acknowledged)
    }

    func testUncertainIsNeverAutoTransmittedAndNeedsExplicitRetry() {
        var box = WatchMessageOutbox()
        box.enqueue(Fx.message("m1"), targetLabel: "t", now: Fx.t0)
        box.markSent("m1", now: Fx.t0)
        box.markUncertain("m1", reason: "no reply", now: Fx.t0)
        XCTAssertTrue(box.autoTransmittable.isEmpty)
        XCTAssertTrue(box.userRetry("m1", now: Fx.t0))
        XCTAssertEqual(box.autoTransmittable.map(\.id), ["m1"])
        XCTAssertEqual(box.messages[0].request.clientMessageID, "m1", "retry keeps the idempotency key")
    }

    func testRelaunchTurnsInFlightIntoUncertain() {
        var box = WatchMessageOutbox()
        box.enqueue(Fx.message("m1"), targetLabel: "t", now: Fx.t0)
        box.enqueue(Fx.message("m2"), targetLabel: "t", now: Fx.t0)
        box.markSent("m1", now: Fx.t0)
        box.recoverAfterRelaunch(now: Fx.t0)
        guard case .uncertain = box.messages[0].state else { return XCTFail() }
        XCTAssertEqual(box.messages[1].state, .queued, "never-transmitted messages stay queued")
        XCTAssertEqual(box.autoTransmittable.map(\.id), ["m2"])
    }

    func testRejectsEmptyAndOverlongAndDuplicateID() {
        var box = WatchMessageOutbox()
        XCTAssertFalse(box.enqueue(Fx.message("a", text: "   "), targetLabel: "t", now: Fx.t0))
        XCTAssertFalse(box.enqueue(Fx.message("b", text: String(repeating: "x", count: 1001)), targetLabel: "t", now: Fx.t0))
        XCTAssertTrue(box.enqueue(Fx.message("c"), targetLabel: "t", now: Fx.t0))
        XCTAssertFalse(box.enqueue(Fx.message("c"), targetLabel: "t", now: Fx.t0))
    }

    func testRetryRefusedForAckedAndInFlight() {
        var box = WatchMessageOutbox()
        box.enqueue(Fx.message("m1"), targetLabel: "t", now: Fx.t0)
        XCTAssertFalse(box.userRetry("m1", now: Fx.t0))
        box.markSent("m1", now: Fx.t0)
        XCTAssertFalse(box.userRetry("m1", now: Fx.t0))
        box.apply(.init(clientMessageID: "m1", outcome: .acknowledged), now: Fx.t0)
        XCTAssertFalse(box.userRetry("m1", now: Fx.t0))
    }

    func testTargetLabelFrozenAtCompose() {
        var box = WatchMessageOutbox()
        box.enqueue(Fx.message("m1"), targetLabel: "Mac mini › Scout", now: Fx.t0)
        XCTAssertEqual(box.messages[0].targetLabel, "Mac mini › Scout")
        XCTAssertEqual(box.messages[0].request.gatewayID, "mac-mini")
    }

    func testPhoneLedgerDoesNotRepeatUncertainOrAcked() {
        var ledger = WatchMessageLedger()
        XCTAssertEqual(ledger.admit("m1"), .admit)
        XCTAssertEqual(ledger.admit("m1"), .inFlight)
        ledger.finish("m1", outcome: .uncertain(reason: "x"))
        XCTAssertEqual(ledger.admit("m1"), .finished(.uncertain(reason: "x")))
        XCTAssertEqual(ledger.admit("m2"), .admit)
        ledger.finish("m2", outcome: .acknowledged)
        XCTAssertEqual(ledger.admit("m2"), .finished(.alreadyAcknowledged))
        XCTAssertEqual(ledger.admit("m3"), .admit)
        ledger.finish("m3", outcome: .failed(reason: "offline"))
        XCTAssertEqual(ledger.admit("m3"), .admit, "definite failure may retry under the same ID")
    }
}

final class CodecTests: XCTestCase {
    func testRoundTrip() throws {
        let snap = Fx.snapshot(gateways: [Fx.gateway("g", name: "G")], approvals: [Fx.approval()])
        let packed = try WatchCodec.pack(snap)
        XCTAssertEqual(try WatchCodec.unpack(WatchSnapshot.self, from: packed), snap)
    }

    func testFlavorMismatchRejected() {
        let prod = Fx.snapshot(gateways: [], flavor: .production)
        XCTAssertThrowsError(try WatchCodec.validate(prod, expecting: .dev)) {
            XCTAssertEqual($0 as? WatchCodecError, .wrongFlavor)
        }
        XCTAssertNoThrow(try WatchCodec.validate(Fx.snapshot(gateways: []), expecting: .dev))
    }

    func testOversizeAndMalformedRejected() {
        let huge = String(repeating: "a", count: WatchCodec.maxPayloadBytes + 1)
        XCTAssertThrowsError(try WatchCodec.pack(WatchReply.rejected(reason: huge)))
        XCTAssertThrowsError(try WatchCodec.unpack(WatchSnapshot.self, from: [WatchCodec.key: Data("nope".utf8)]))
        XCTAssertThrowsError(try WatchCodec.unpack(WatchSnapshot.self, from: [:]))
    }

    func testHiddenSnapshotCarriesNoContent() throws {
        let hidden = WatchSnapshot.hidden(flavor: .dev, generation: 3, builtAt: Fx.t0)
        XCTAssertFalse(hidden.contentVisible)
        XCTAssertTrue(hidden.gateways.isEmpty && hidden.approvals.isEmpty && hidden.attention.isEmpty)
    }

    func testBudgetKeepsLargeFleetUnderLimit() throws {
        let chats = (0..<40).map { WatchConversation(id: "c\($0)", title: "Conversation number \($0) with a long title") }
        let gateways = (0..<6).map { g in
            Fx.gateway("g\(g)", name: "Machine \(g)", bots: (0..<8).map { Fx.bot("g\(g)", "p\($0)", name: "Bot \($0)", chats: chats) })
        }
        let approvals = (0..<30).map { Fx.approval(request: "r\($0)") }
        let trimmed = WatchSnapshotBudget.trimmed(Fx.snapshot(gateways: gateways, approvals: approvals))
        XCTAssertLessThanOrEqual(trimmed.approvals.count, WatchSnapshotBudget.maxApprovals)
        XCTAssertNoThrow(try WatchCodec.pack(trimmed))
    }

    func testApprovalRequestCarriesOriginalIdentityNotSelection() {
        let a = Fx.approval(gateway: "nas", session: "s9", request: "r9")
        let req = Fx.approvalRequest(a, .deny)
        XCTAssertEqual(req.approvalKey, "nas|s9|r9")
        XCTAssertEqual(req.gatewayID, "nas")
    }
}
