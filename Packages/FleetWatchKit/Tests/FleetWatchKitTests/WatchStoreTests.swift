import XCTest
@testable import FleetWatchKit

@MainActor
final class FakeTransport: WatchTransport {
    var linkState: WatchLinkState = .reachable
    var onSnapshot: ((WatchSnapshot) -> Void)?
    var onLinkChange: ((WatchLinkState) -> Void)?
    let isFixture = false
    var sent: [WatchRequest] = []
    var handler: (WatchRequest) async throws -> WatchReply = { _ in .rejected(reason: "unscripted") }
    func activate() {}
    func send(_ request: WatchRequest) async throws -> WatchReply {
        if case .refresh = request {} else { sent.append(request) }
        guard linkState == .reachable else { throw WatchTransportError.notReachable }
        return try await handler(request)
    }
    func push(_ s: WatchSnapshot) { onSnapshot?(s) }
}

@MainActor
final class WatchStoreTests: XCTestCase {
    var transport: FakeTransport!
    var store: WatchStore!
    var clock = Fx.t0
    var dir: URL!
    var suite: UserDefaults!

    override func setUp() async throws {
        transport = FakeTransport()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = UserDefaults(suiteName: UUID().uuidString)!
        makeStore()
    }

    func makeStore() {
        store = WatchStore(transport: transport, defaults: suite, outboxURL: dir.appendingPathComponent("o.json"),
                           clock: { [unowned self] in self.clock })
        store.start()
    }

    private func twoMachineSnapshot(generation: Int = 1, approvals: [WatchApproval]? = nil) -> WatchSnapshot {
        let chats = [WatchConversation(id: "main", title: "Main", isMain: true), WatchConversation(id: "c2", title: "Docs")]
        let base = Fx.snapshot(gateways: [
            Fx.gateway("mac-mini", name: "Mac mini", bots: [Fx.bot("mac-mini", "scout", name: "Scout", chats: chats), Fx.bot("mac-mini", "atlas", name: "Atlas", chats: chats)]),
            Fx.gateway("nas", name: "NAS", bots: [Fx.bot("nas", "scout", name: "Scout NAS", chats: chats)])
        ], approvals: approvals ?? [Fx.approval()])
        return WatchSnapshot(flavor: .dev, generation: generation, builtAt: clock, contentVisible: true,
                             gateways: base.gateways, attention: [], approvals: base.approvals)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    // MARK: approvals

    func testApprovalStaysBoundToOriginalAfterContextSwitch() async {
        let a = Fx.approval(gateway: "mac-mini", session: "sA", request: "rA")
        transport.push(twoMachineSnapshot(approvals: [a]))
        store.selection = .init(gatewayID: "mac-mini", profileSlug: "scout")
        // user switches to a completely different machine/bot while approval is pending
        store.selection = .init(gatewayID: "nas", profileSlug: "scout")
        transport.handler = { req in
            guard case .approval(let r, _) = req else { return .rejected(reason: "x") }
            return .approval(.init(requestUUID: r.requestUUID, approvalKey: r.approvalKey, outcome: .applied))
        }
        await store.decide(a, .deny)
        guard case .approval(let sent, _)? = transport.sent.first else { return XCTFail("nothing sent") }
        XCTAssertEqual(sent.gatewayID, "mac-mini")
        XCTAssertEqual(sent.sessionID, "sA")
        XCTAssertEqual(sent.requestID, "rA")
        XCTAssertEqual(sent.commandDigest, a.commandDigest)
        XCTAssertEqual(store.approvalStates[a.id], .settled(.applied))
    }

    func testNotReachableSendsNothing() async {
        let a = Fx.approval()
        transport.push(twoMachineSnapshot(approvals: [a]))
        transport.linkState = .phoneUnreachable
        store.onLinkForTest(.phoneUnreachable)
        await store.decide(a, .deny)
        XCTAssertTrue(transport.sent.isEmpty)
        guard case .notSent? = store.approvalStates[a.id] else { return XCTFail() }
    }

    func testSecondTapWhileSendingIsIgnored() async {
        let a = Fx.approval()
        transport.push(twoMachineSnapshot(approvals: [a]))
        transport.handler = { req in
            try await Task.sleep(for: .milliseconds(150))
            guard case .approval(let r, _) = req else { return .rejected(reason: "x") }
            return .approval(.init(requestUUID: r.requestUUID, approvalKey: r.approvalKey, outcome: .applied))
        }
        let s = store!
        let first = Task { @MainActor in await s.decide(a, .deny) }
        await settle()
        await store.decide(a, .deny)
        await first.value
        XCTAssertEqual(transport.sent.count, 1)
    }

    func testNoReplyAfterSendIsUncertainNotApplied() async {
        let a = Fx.approval()
        transport.push(twoMachineSnapshot(approvals: [a]))
        transport.handler = { _ in throw WatchTransportError.noReply }
        await store.decide(a, .deny)
        guard case .settled(.uncertain)? = store.approvalStates[a.id] else { return XCTFail("\(String(describing: store.approvalStates[a.id]))") }
        // settled state blocks a blind second send until the user looks again
        await store.decide(a, .deny)
        XCTAssertEqual(transport.sent.count, 1)
    }

    func testExpiredAndAlreadyResolvedAreSurfaced() async {
        let a = Fx.approval()
        transport.push(twoMachineSnapshot(approvals: [a]))
        transport.handler = { req in
            if case .approval(let r, _) = req { return .approval(.init(requestUUID: r.requestUUID, approvalKey: r.approvalKey, outcome: .expired)) }
            return .snapshot(self.twoMachineSnapshot(generation: 2, approvals: []))
        }
        await store.decide(a, .deny)
        await settle()
        XCTAssertNil(store.approvalStates[a.id], "state dropped once the snapshot no longer lists it")
        XCTAssertTrue(store.snapshot!.approvals.isEmpty)
    }

    func testLongCommandCannotBeApprovedOnWatch() async {
        let a = Fx.approval(full: true)
        transport.push(twoMachineSnapshot(approvals: [a]))
        await store.decide(a, .approveOnce)
        XCTAssertTrue(transport.sent.isEmpty)
        await store.decide(a, .deny)
        XCTAssertEqual(transport.sent.count, 1)
    }

    func testStaleSnapshotBlocksActions() async {
        let a = Fx.approval()
        transport.push(twoMachineSnapshot(approvals: [a]))
        clock = clock.addingTimeInterval(900)
        await store.decide(a, .deny)
        XCTAssertTrue(transport.sent.isEmpty)
        guard case .notSent? = store.approvalStates[a.id] else { return XCTFail() }
        XCTAssertEqual(store.freshness, .aging)
    }

    func testOutOfOrderSnapshotIgnored() {
        transport.push(twoMachineSnapshot(generation: 5))
        transport.push(twoMachineSnapshot(generation: 3))
        XCTAssertEqual(store.snapshot?.generation, 5)
    }

    // MARK: messages / routing

    func testSwitchingBetweenTwoContextsRoutesEachMessageToItsBot() async {
        transport.push(twoMachineSnapshot())
        transport.handler = { req in
            guard case .message(let m, _) = req else { return .rejected(reason: "x") }
            return .message(.init(clientMessageID: m.clientMessageID, outcome: .acknowledged))
        }
        store.selection = .init(gatewayID: "mac-mini", profileSlug: "atlas", conversationID: "c2")
        XCTAssertTrue(store.send(text: "to atlas"))
        await settle()
        store.selection = .init(gatewayID: "nas", profileSlug: "scout", conversationID: "main")
        XCTAssertTrue(store.send(text: "to nas scout"))
        await settle()
        let msgs = transport.sent.compactMap { r -> WatchMessageRequest? in if case .message(let m, _) = r { return m }; return nil }
        XCTAssertEqual(msgs.map(\.gatewayID), ["mac-mini", "nas"])
        XCTAssertEqual(msgs.map(\.profileSlug), ["atlas", "scout"])
        XCTAssertEqual(msgs.map(\.conversationID), ["c2", nil], "Main chat is sent as nil = canonical")
        XCTAssertEqual(store.outbox.messages.map(\.state), [.acknowledged, .acknowledged])
        XCTAssertEqual(store.outbox.messages[0].targetLabel, "Mac mini › Atlas › Docs")
    }

    func testCannotSendWithoutFullTargetOrToRemovedBot() {
        transport.push(twoMachineSnapshot())
        XCTAssertFalse(store.send(text: "hi"), "no selection => no default destination")
        store.selection = .init(gatewayID: "mac-mini")
        XCTAssertFalse(store.send(text: "hi"), "machine only => no bot")
        store.selection = .init(gatewayID: "mac-mini", profileSlug: "removed")
        XCTAssertFalse(store.send(text: "hi"), "removed bot => refused, not redirected")
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testAcknowledgementOnlyFromReply() async {
        transport.push(twoMachineSnapshot())
        store.selection = .init(gatewayID: "nas", profileSlug: "scout")
        transport.linkState = .phoneUnreachable
        store.onLinkForTest(.phoneUnreachable)
        XCTAssertTrue(store.send(text: "later"))
        await settle()
        XCTAssertEqual(store.outbox.messages[0].state, .queued)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testUncertainDeliveryIsNotResentOnReconnect() async {
        transport.push(twoMachineSnapshot())
        store.selection = .init(gatewayID: "nas", profileSlug: "scout")
        transport.handler = { _ in throw WatchTransportError.noReply }
        XCTAssertTrue(store.send(text: "maybe"))
        await settle()
        guard case .uncertain = store.outbox.messages[0].state else { return XCTFail() }
        transport.sent.removeAll()
        transport.handler = { req in
            guard case .message(let m, _) = req else { return .rejected(reason: "x") }
            return .message(.init(clientMessageID: m.clientMessageID, outcome: .acknowledged))
        }
        await store.flushQueuedMessages()
        XCTAssertTrue(transport.sent.isEmpty, "never auto-resent")
        let id = store.outbox.messages[0].id
        store.retry(id)
        await settle()
        XCTAssertEqual(transport.sent.count, 1)
        guard case .message(let m, _) = transport.sent[0] else { return XCTFail() }
        XCTAssertEqual(m.clientMessageID, id)
        XCTAssertEqual(store.outbox.messages[0].state, .acknowledged)
    }

    func testLinkDropWhileAwaitingReplyMarksUncertain() async {
        transport.push(twoMachineSnapshot())
        store.selection = .init(gatewayID: "nas", profileSlug: "scout")
        transport.handler = { _ in try await Task.sleep(for: .seconds(5)); return .rejected(reason: "late") }
        XCTAssertTrue(store.send(text: "in flight"))
        await settle()
        XCTAssertEqual(store.outbox.messages[0].state, .sentToPhone)
        store.onLinkForTest(.phoneUnreachable)
        guard case .uncertain = store.outbox.messages[0].state else { return XCTFail() }
    }

    func testOutboxSurvivesRelaunchAndInFlightBecomesUncertain() async {
        transport.push(twoMachineSnapshot())
        store.selection = .init(gatewayID: "nas", profileSlug: "scout")
        transport.handler = { _ in try await Task.sleep(for: .seconds(5)); return .rejected(reason: "late") }
        XCTAssertTrue(store.send(text: "x"))
        await settle()
        makeStore() // simulated relaunch with same persisted file
        guard case .uncertain = store.outbox.messages[0].state else { return XCTFail("\(store.outbox.messages)") }
    }

    func testSelectionPersistsAndRemovedTargetNeverFallsBack() {
        transport.push(twoMachineSnapshot())
        store.selection = .init(gatewayID: "nas", profileSlug: "scout")
        makeStore()
        XCTAssertEqual(store.selection.gatewayID, "nas")
        transport.push(WatchSnapshot(flavor: .dev, generation: 9, builtAt: clock, contentVisible: true,
                                     gateways: [Fx.gateway("mac-mini", name: "Mac mini")], attention: [], approvals: []))
        XCTAssertEqual(store.resolution, .gatewayMissing(gatewayID: "nas"))
        XCTAssertEqual(store.contextLabel, "Machine removed")
    }
}

extension WatchStore {
    /// Test hook mirroring the transport's link callback.
    func onLinkForTest(_ state: WatchLinkState) { simulateLinkChange(state) }
}
