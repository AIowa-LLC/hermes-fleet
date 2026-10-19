import XCTest
@testable import FleetWatchKit

final class SourceFreshnessTests: XCTestCase {
    private let now = Fx.t0.addingTimeInterval(1000)

    func testNeverObservedCurrentStaleAndUnavailableAreDistinct() {
        XCTAssertEqual(WatchSourcePolicy.state(observedAt: nil, gatewayStatus: .online, now: now), .neverObserved)
        XCTAssertEqual(WatchSourcePolicy.state(observedAt: now.addingTimeInterval(-10), gatewayStatus: .online, now: now), .current)
        XCTAssertEqual(WatchSourcePolicy.state(observedAt: now.addingTimeInterval(-300), gatewayStatus: .online, now: now), .stale)
        XCTAssertEqual(WatchSourcePolicy.state(observedAt: now.addingTimeInterval(-10), gatewayStatus: .offline, now: now), .unavailable,
                       "an old read of an unreachable machine is cached, however recent")
        XCTAssertEqual(WatchSourcePolicy.state(observedAt: now.addingTimeInterval(-10), gatewayStatus: .notConnected, now: now), .unavailable)
    }

    func testApprovalActionabilityUsesTheApprovalsOwnObservationTime() {
        XCTAssertFalse(WatchFreshnessPolicy.approvalActionable(observedAt: nil, now: now))
        XCTAssertTrue(WatchFreshnessPolicy.approvalActionable(observedAt: now.addingTimeInterval(-30), now: now))
        XCTAssertFalse(WatchFreshnessPolicy.approvalActionable(observedAt: now.addingTimeInterval(-600), now: now))
    }

    func testFreshlyBuiltSnapshotDoesNotRefreshOldApproval() {
        // Snapshot built "now", but the phone last saw this approval 10 minutes earlier.
        let old = Fx.approval()  // observedAt = t0
        XCTAssertEqual(WatchApprovalPolicy.affordance(for: old, now: Fx.t0.addingTimeInterval(600)).isNone, true)
    }

    func testNeverObservedApprovalIsNotActionable() {
        let a = WatchApproval(gatewayID: "g", gatewayName: "G", profileSlug: "s", botName: "S", sessionID: "x", sessionLabel: "l",
                              requestID: "r", commandPreview: "ls", commandDigest: WatchCodec.digest("ls"),
                              requiresFullReview: false, choices: ["once"], observedAt: nil)
        XCTAssertTrue(WatchApprovalPolicy.affordance(for: a, now: Fx.t0).isNone)
    }
}

extension WatchApprovalAffordance {
    var isNone: Bool { if case .none = self { return true }; return false }
}

final class ApprovalScopeTests: XCTestCase {
    private func snapshot(approvals: [WatchApproval], status: WatchGatewayStatus = .online,
                          coverage: WatchCoverage = .reporting, observedAt: Date? = Fx.t0) -> WatchSnapshot {
        let chats = [WatchConversation(id: "main", title: "Main chat", isMain: true), WatchConversation(id: "c2", title: "Docs")]
        let gw = WatchGateway(id: "mac-mini", displayName: "Mac mini", status: status, coverage: coverage, observedAt: observedAt,
                              bots: [Fx.bot("mac-mini", "scout", name: "Scout", chats: chats)], running: [])
        return Fx.snapshot(gateways: [gw], approvals: approvals)
    }

    func testThisContextRespectsSelectedConversation() {
        let inDocs = Fx.approval(session: "c2", request: "r1")
        let inMain = Fx.approval(session: "main", request: "r2")
        let s = snapshot(approvals: [inDocs, inMain])
        let docs = WatchContextResolver.resolve(.init(gatewayID: "mac-mini", profileSlug: "scout", conversationID: "c2"), in: s)
        XCTAssertTrue(WatchApprovalScope.isInContext(inDocs, docs))
        XCTAssertFalse(WatchApprovalScope.isInContext(inMain, docs), "same bot, different chat is not this context")
        let overview = WatchContextResolver.resolve(.init(gatewayID: "mac-mini", profileSlug: "scout"), in: s)
        XCTAssertTrue(WatchApprovalScope.isInContext(inMain, overview))
        let other = WatchContextResolver.resolve(.init(gatewayID: "mac-mini", profileSlug: "atlas"), in: s)
        XCTAssertFalse(WatchApprovalScope.isInContext(inMain, other))
    }

    func testGoneFromReportingMachineIsResolved() {
        let a = Fx.approval(gateway: "mac-mini")
        let s = snapshot(approvals: [])
        XCTAssertEqual(WatchApprovalScope.presence(of: a, in: s, now: Fx.t0.addingTimeInterval(5)), .resolved)
    }

    func testGoneFromNonReportingOrStaleMachineIsUnverifiableNotResolved() {
        let a = Fx.approval(gateway: "mac-mini")
        // Failed refresh / machine not reporting must not read as "resolved".
        for s in [snapshot(approvals: [], status: .offline),
                  snapshot(approvals: [], coverage: .heldOver),
                  snapshot(approvals: [], observedAt: nil)] {
            guard case .unverifiable = WatchApprovalScope.presence(of: a, in: s, now: Fx.t0.addingTimeInterval(5)) else {
                return XCTFail("expected unverifiable")
            }
        }
        guard case .unverifiable = WatchApprovalScope.presence(of: a, in: snapshot(approvals: [], observedAt: Fx.t0), now: Fx.t0.addingTimeInterval(900)) else {
            return XCTFail("old observation cannot prove resolution")
        }
        guard case .unverifiable = WatchApprovalScope.presence(of: Fx.approval(gateway: "removed"), in: snapshot(approvals: []), now: Fx.t0) else {
            return XCTFail("removed machine")
        }
    }

    func testPresentApprovalIsPending() {
        let a = Fx.approval(gateway: "mac-mini")
        XCTAssertEqual(WatchApprovalScope.presence(of: a, in: snapshot(approvals: [a]), now: Fx.t0), .pending)
    }
}

final class LedgerPersistenceTests: XCTestCase {
    private func message(_ id: String = "m1", text: String = "hi", gateway: String = "mac", session: String = "s1") -> WatchMessageRequest {
        WatchMessageRequest(clientMessageID: id, gatewayID: gateway, profileSlug: "scout",
                            target: .conversation(sessionID: session), text: text, composedAt: Fx.t0)
    }

    func testSameIDDifferentPayloadOrDestinationIsAConflict() {
        var ledger = WatchMessageLedger()
        XCTAssertEqual(ledger.admit(message()), .admit)
        ledger.finish("m1", outcome: .acknowledged)
        XCTAssertEqual(ledger.admit(message(text: "different")), .conflict)
        XCTAssertEqual(ledger.admit(message(gateway: "nas")), .conflict)
        XCTAssertEqual(ledger.admit(message(session: "s2")), .conflict)
        XCTAssertEqual(ledger.admit(message()), .finished(.alreadyAcknowledged))
    }

    func testMainChatAndConversationWithSameSessionIDAreDifferentDestinations() {
        let a = WatchMessageRequest(clientMessageID: "m", gatewayID: "g", profileSlug: "s", target: .mainChat(sessionID: "x"), text: "t", composedAt: Fx.t0)
        let b = WatchMessageRequest(clientMessageID: "m", gatewayID: "g", profileSlug: "s", target: .conversation(sessionID: "x"), text: "t", composedAt: Fx.t0)
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
    }

    func testRestartAfterAdmissionBeforeOutcomeIsUncertainAndNeverReadmitted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("l.json")
        let store = FileWatchMessageLedgerStore(url: url)
        var ledger = try store.load()
        XCTAssertEqual(ledger.admit(message()), .admit)
        try store.save(ledger)          // persisted BEFORE dispatch; process dies before finish()
        var reloaded = try FileWatchMessageLedgerStore(url: url).load()
        reloaded.recoverAfterRestart()
        guard case .finished(.uncertain) = reloaded.admit(message()) else { return XCTFail("must not re-dispatch") }
    }

    func testFinishedAckSurvivesRestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("l.json")
        var ledger = WatchMessageLedger()
        _ = ledger.admit(message())
        ledger.finish("m1", outcome: .acknowledged)
        try FileWatchMessageLedgerStore(url: url).save(ledger)
        var reloaded = try FileWatchMessageLedgerStore(url: url).load()
        reloaded.recoverAfterRestart()
        XCTAssertEqual(reloaded.admit(message()), .finished(.alreadyAcknowledged))
    }

    func testPersistedLedgerContainsNoMessageText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("l.json")
        var ledger = WatchMessageLedger()
        _ = ledger.admit(message(text: "super secret plan"))
        try FileWatchMessageLedgerStore(url: url).save(ledger)
        let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(raw.contains("super secret plan"))
    }

    func testCorruptLedgerThrowsInsteadOfBecomingEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("l.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try FileWatchMessageLedgerStore(url: url).load())
    }

    func testRevokedAdmissionCanBeAdmittedAgain() {
        var ledger = WatchMessageLedger()
        XCTAssertEqual(ledger.admit(message()), .admit)
        ledger.revokeAdmission(message())
        XCTAssertEqual(ledger.admit(message()), .admit)
    }
}

@MainActor
final class StoreSafetyTests: XCTestCase {
    var transport: FakeTransport!
    var store: WatchStore!
    var clock = Fx.t0
    var dir: URL!

    override func setUp() async throws {
        transport = FakeTransport()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = WatchStore(transport: transport, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                           outboxURL: dir.appendingPathComponent("o.json"), clock: { [unowned self] in self.clock })
        store.start()
    }

    private func snapshot(mainChat: Bool, generation: Int = 1, status: WatchGatewayStatus = .online) -> WatchSnapshot {
        var chats = [WatchConversation(id: "c2", title: "Docs")]
        if mainChat { chats.insert(WatchConversation(id: "main", title: "Main chat", isMain: true), at: 0) }
        let gw = WatchGateway(id: "mini", displayName: "Mini Hermes", status: status, coverage: .reporting, observedAt: clock,
                              bots: [Fx.bot("mini", "apple", name: "Apple", chats: chats)], running: [])
        return WatchSnapshot(flavor: .dev, generation: generation, builtAt: clock, contentVisible: true, gateways: [gw], attention: [], approvals: [])
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    func testBotOverviewIsNotADestinationAndMissingMainChatIsReported() {
        transport.push(snapshot(mainChat: false))
        store.selection = .init(gatewayID: "mini", profileSlug: "apple")
        XCTAssertFalse(store.send(text: "hi"))
        XCTAssertNotNil(store.selectedMainChatGuidance)
        XCTAssertEqual(store.contextLabel, "Mini Hermes › Apple › Overview")
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertTrue(store.outbox.messages.isEmpty, "nothing queued, nothing created")
    }

    func testDestinationLabelsAreExplicit() {
        transport.push(snapshot(mainChat: true))
        store.selection = .init(gatewayID: "mini", profileSlug: "apple", conversationID: "main")
        XCTAssertEqual(store.contextLabel, "Mini Hermes › Apple › Main chat")
        store.selection = .init(gatewayID: "mini", profileSlug: "apple", conversationID: "c2")
        XCTAssertEqual(store.contextLabel, "Mini Hermes › Apple › Docs")
        XCTAssertNil(store.sendBlockReason)
    }

    func testFrozenLabelSurvivesLaterContextSwitchAndRemoval() async {
        transport.push(snapshot(mainChat: true))
        transport.handler = { _ in try await Task.sleep(for: .seconds(5)); return .rejected(reason: "late") }
        store.selection = .init(gatewayID: "mini", profileSlug: "apple", conversationID: "c2")
        XCTAssertTrue(store.send(text: "x"))
        store.selection = .init(gatewayID: "mini", profileSlug: "apple", conversationID: "main")
        transport.push(snapshot(mainChat: false, generation: 2))   // c2 still listed, main removed
        XCTAssertEqual(store.outbox.messages[0].targetLabel, "Mini Hermes › Apple › Docs")
        XCTAssertEqual(store.outbox.messages[0].request.target, .conversation(sessionID: "c2"))
        XCTAssertEqual(store.sendBlockReason, "That destination is no longer available. Choose another.")
    }

    func testLinkDownBeforeSendKeepsMessageQueuedNotUncertain() async {
        transport.push(snapshot(mainChat: true))
        store.selection = .init(gatewayID: "mini", profileSlug: "apple", conversationID: "main")
        transport.linkState = .reachable   // store thinks reachable, transport verifies down
        var calls = 0
        transport.handler = { _ in calls += 1; throw WatchTransportError.notReachable }
        XCTAssertTrue(store.send(text: "x"))
        await settle()
        XCTAssertEqual(store.outbox.messages[0].state, .queued, "verified-unsent must not read as uncertain")
    }

    func testReconnectFlushesQueuedOnceAndDiscardCancels() async {
        transport.push(snapshot(mainChat: true))
        store.selection = .init(gatewayID: "mini", profileSlug: "apple", conversationID: "main")
        transport.linkState = .phoneUnreachable
        store.onLinkForTest(.phoneUnreachable)
        XCTAssertTrue(store.send(text: "later"))
        XCTAssertTrue(store.send(text: "cancel me"))
        store.discard(store.outbox.messages[1].id)
        transport.handler = { req in
            guard case .message(let m, _) = req else { return .snapshot(self.snapshot(mainChat: true, generation: 3)) }
            return .message(.init(clientMessageID: m.clientMessageID, outcome: .acknowledged))
        }
        transport.linkState = .reachable
        store.onLinkForTest(.reachable)
        await settle()
        let sent = transport.sent.compactMap { r -> String? in if case .message(let m, _) = r { return m.text }; return nil }
        XCTAssertEqual(sent, ["later"])
        XCTAssertEqual(store.outbox.messages.map(\.state), [.acknowledged])
    }

    func testFailedRefreshIsReportedAndKeepsOldDataLabelled() async {
        transport.push(snapshot(mainChat: true))
        transport.handler = { _ in throw WatchTransportError.noReply }
        await store.refresh()
        XCTAssertTrue(store.lastRefreshFailed)
        XCTAssertNotNil(store.snapshot)
        transport.handler = { _ in .snapshot(self.snapshot(mainChat: true, generation: 4)) }
        await store.refresh()
        XCTAssertFalse(store.lastRefreshFailed)
    }

    func testApprovalVanishingFromNonReportingMachineStaysNonActionable() {
        let a = Fx.approval(gateway: "mini")
        store.selection = .init(gatewayID: "mini")
        transport.push(snapshot(mainChat: true, status: .offline))
        guard case .unverifiable = store.approvalPresence(a) else { return XCTFail("offline must not read as resolved") }
        guard case .none = store.affordance(for: a) else { return XCTFail("unverifiable approval must not be actionable") }
    }

    func testSourceStatesAreIndependentPerGateway() {
        let gw = WatchGateway(id: "mini", displayName: "Mini", status: .online, coverage: .reporting,
                              observedAt: clock, bots: [], running: [],
                              rosterObservedAt: clock.addingTimeInterval(-3000), conversationsObservedAt: nil)
        transport.push(WatchSnapshot(flavor: .dev, generation: 1, builtAt: clock, contentVisible: true,
                                     gateways: [gw], attention: [], approvals: []))
        let seen = store.snapshot!.gateways[0]
        XCTAssertEqual(store.liveState(seen), .current, "snapshot built now, live ops seen now")
        XCTAssertEqual(store.rosterState(seen), .stale, "a new snapshot does not freshen an old roster read")
        XCTAssertEqual(store.conversationsState(seen), .neverObserved)
    }
}

final class SnapshotCapTests: XCTestCase {
    private func bot(chatCount: Int) -> WatchBot {
        var chats = [WatchConversation(id: "main", title: "Main chat", isMain: true)]
        chats += (1..<chatCount).map { WatchConversation(id: "c\($0)", title: "Chat \($0)") }
        return WatchBot(ref: WatchBotRef(gatewayID: "mini", profileSlug: "apple"), displayName: "Apple", activity: "idle", conversations: chats)
    }

    private func snapshot(_ bot: WatchBot, removedPin: WatchConversationPin? = nil) -> WatchSnapshot {
        let gw = WatchGateway(id: "mini", displayName: "Mini", status: .online, coverage: .reporting, observedAt: Fx.t0,
                              bots: [bot], running: [], rosterObservedAt: Fx.t0, conversationsObservedAt: Fx.t0)
        return WatchSnapshot(flavor: .dev, generation: 1, builtAt: Fx.t0, contentVisible: true, gateways: [gw],
                             attention: [], approvals: [], removedPin: removedPin)
    }

    private func pin(_ id: String) -> WatchConversationPin { .init(gatewayID: "mini", profileSlug: "apple", conversationID: id) }

    func testPinnedChatBeyondTheCapIsKept() {
        let trimmed = WatchSnapshotBudget.trimmed(snapshot(bot(chatCount: 12)), pinned: pin("c9"))
        let b = trimmed.gateways[0].bots[0]
        XCTAssertEqual(b.conversations.count, 6)
        XCTAssertTrue(b.conversations.contains { $0.id == "c9" })
        XCTAssertEqual(b.conversations.first?.id, "main", "Main chat stays first")
        XCTAssertEqual(b.totalConversations, 12)
        XCTAssertEqual(b.omittedConversationCount, 6)
    }

    func testUnpinnedChatBeyondTheCapIsOmittedAndCounted() {
        let b = WatchSnapshotBudget.trimmed(snapshot(bot(chatCount: 12))).gateways[0].bots[0]
        XCTAssertFalse(b.conversations.contains { $0.id == "c9" })
        XCTAssertEqual(b.omittedConversationCount, 6)
    }

    func testPinForAnotherBotOrUnknownChatChangesNothing() {
        let other = WatchConversationPin(gatewayID: "mini", profileSlug: "other", conversationID: "c9")
        XCTAssertFalse(WatchSnapshotBudget.trimmed(snapshot(bot(chatCount: 12)), pinned: other)
            .gateways[0].bots[0].conversations.contains { $0.id == "c9" })
        XCTAssertEqual(WatchSnapshotBudget.trimmed(snapshot(bot(chatCount: 12)), pinned: pin("nope"))
            .gateways[0].bots[0].conversations.count, 6)
    }

    func testTruncationIsNotRemoval() {
        let s = WatchSnapshotBudget.trimmed(snapshot(bot(chatCount: 12)))
        let r = WatchContextResolver.resolve(.init(gatewayID: "mini", profileSlug: "apple", conversationID: "c9"), in: s)
        guard case .conversationNotShown(_, "c9", 6) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(WatchContextResolver.label(for: r), "Apple › chat not in list")
        XCTAssertFalse(r.isFullyTargeted)
    }

    func testPhoneConfirmedRemovalStaysRemovedEvenWhenCapped() {
        let s = WatchSnapshotBudget.trimmed(snapshot(bot(chatCount: 12), removedPin: pin("gone")))
        let r = WatchContextResolver.resolve(.init(gatewayID: "mini", profileSlug: "apple", conversationID: "gone"), in: s)
        guard case .conversationMissing = r else { return XCTFail("\(r)") }
    }

    func testMissingChatOnABotUnderTheCapIsRemoved() {
        let s = WatchSnapshotBudget.trimmed(snapshot(bot(chatCount: 3)))
        guard case .conversationMissing = WatchContextResolver.resolve(
            .init(gatewayID: "mini", profileSlug: "apple", conversationID: "deleted"), in: s) else { return XCTFail() }
    }

    func testSnapshotWithTruncationFieldsRoundTrips() throws {
        let s = WatchSnapshotBudget.trimmed(snapshot(bot(chatCount: 12), removedPin: pin("gone")))
        XCTAssertEqual(try WatchCodec.unpack(WatchSnapshot.self, from: WatchCodec.pack(s)), s)
    }

    func testRefreshRequestRoundTripsWithPin() throws {
        let req = WatchRequest.refresh(flavor: .dev, pinned: pin("c9"))
        XCTAssertEqual(try WatchCodec.unpack(WatchRequest.self, from: WatchCodec.pack(req)), req)
        let plain = WatchRequest.refresh(flavor: .dev)
        XCTAssertEqual(try WatchCodec.unpack(WatchRequest.self, from: WatchCodec.pack(plain)), plain)
    }
}

@MainActor
final class CapSurvivesRefreshTests: XCTestCase {
    func testSelectedChatBeyondTheCapSurvivesRefreshAndStaysSendable() async {
        let transport = FakeTransport()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WatchStore(transport: transport, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                               outboxURL: dir.appendingPathComponent("o.json"), clock: { Fx.t0 })
        store.start()
        var chats = [WatchConversation(id: "main", title: "Main chat", isMain: true)]
        chats += (1..<12).map { WatchConversation(id: "c\($0)", title: "Chat \($0)") }
        let full = WatchBot(ref: WatchBotRef(gatewayID: "mini", profileSlug: "apple"), displayName: "Apple", activity: "idle", conversations: chats)
        let gw = WatchGateway(id: "mini", displayName: "Mini", status: .online, coverage: .reporting, observedAt: Fx.t0,
                              bots: [full], running: [], rosterObservedAt: Fx.t0, conversationsObservedAt: Fx.t0)
        var generation = 1
        var pinsSeen: [WatchConversationPin?] = []
        // A phone that honors the pin, like the real coordinator.
        transport.handler = { req in
            guard case .refresh(_, let pinned) = req else { return .rejected(reason: "x") }
            pinsSeen.append(pinned)
            generation += 1
            let snap = WatchSnapshot(flavor: .dev, generation: generation, builtAt: Fx.t0, contentVisible: true,
                                     gateways: [gw], attention: [], approvals: [])
            return .snapshot(WatchSnapshotBudget.trimmed(snap, pinned: pinned))
        }
        store.selection = .init(gatewayID: "mini", profileSlug: "apple", conversationID: "c9")
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(pinsSeen.compactMap { $0?.conversationID }, ["c9", "c9"])
        guard case .resolved(_, _, let conversation?) = store.resolution else { return XCTFail("\(store.resolution)") }
        XCTAssertEqual(conversation.id, "c9")
        XCTAssertNil(store.sendBlockReason)
        XCTAssertTrue(store.send(text: "hi"))
        XCTAssertEqual(store.contextLabel, "Mini › Apple › Chat 9")
    }

    func testBeyondCapWithoutPinSaysNotShownNeverRemoved() async {
        let transport = FakeTransport()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WatchStore(transport: transport, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                               outboxURL: dir.appendingPathComponent("o.json"), clock: { Fx.t0 })
        store.start()
        var chats = [WatchConversation(id: "main", title: "Main chat", isMain: true)]
        chats += (1..<12).map { WatchConversation(id: "c\($0)", title: "Chat \($0)") }
        let full = WatchBot(ref: WatchBotRef(gatewayID: "mini", profileSlug: "apple"), displayName: "Apple", activity: "idle", conversations: chats)
        let gw = WatchGateway(id: "mini", displayName: "Mini", status: .online, coverage: .reporting, observedAt: Fx.t0, bots: [full], running: [])
        transport.push(WatchSnapshotBudget.trimmed(WatchSnapshot(flavor: .dev, generation: 1, builtAt: Fx.t0, contentVisible: true,
                                                                  gateways: [gw], attention: [], approvals: [])))
        store.selection = .init(gatewayID: "mini", profileSlug: "apple", conversationID: "c9")
        XCTAssertTrue(store.sendBlockReason?.contains("not removed") == true)
        XCTAssertFalse(store.send(text: "hi"))
    }
}

@MainActor
final class OutboxPersistenceTests: XCTestCase {
    func testUnwritableOutboxFailsTheSendClosedAndSaysSo() throws {
        // The outbox's parent "directory" is a regular file, so every write fails.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: blocker)
        let transport = FakeTransport()
        let store = WatchStore(transport: transport, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                               outboxURL: blocker.appendingPathComponent("o.json"), clock: { Fx.t0 })
        store.start()
        let chats = [WatchConversation(id: "main", title: "Main chat", isMain: true)]
        let gw = Fx.gateway("mini", name: "Mini", bots: [Fx.bot("mini", "apple", name: "Apple", chats: chats)])
        transport.push(Fx.snapshot(gateways: [gw]))
        store.selection = .init(gatewayID: "mini", profileSlug: "apple", conversationID: "main")
        XCTAssertFalse(store.send(text: "hi"), "a message that can't be recorded must not be queued")
        XCTAssertTrue(store.outbox.messages.isEmpty)
        XCTAssertNotNil(store.outboxPersistenceError)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testWritableOutboxPersistsAndClearsError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transport = FakeTransport()
        transport.linkState = .phoneUnreachable
        let store = WatchStore(transport: transport, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                               outboxURL: dir.appendingPathComponent("o.json"), clock: { Fx.t0 })
        store.start()
        let chats = [WatchConversation(id: "main", title: "Main chat", isMain: true)]
        transport.push(Fx.snapshot(gateways: [Fx.gateway("mini", name: "Mini", bots: [Fx.bot("mini", "apple", name: "Apple", chats: chats)])]))
        store.selection = .init(gatewayID: "mini", profileSlug: "apple", conversationID: "main")
        XCTAssertTrue(store.send(text: "hi"))
        XCTAssertNil(store.outboxPersistenceError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("o.json").path))
    }
}

final class MainChatStateTests: XCTestCase {
    private func bot(_ status: WatchMainChatStatus?, main: Bool, diagnostic: String? = nil) -> WatchBot {
        let chats = main ? [WatchConversation(id: "m", title: "Main chat", isMain: true)] : []
        return WatchBot(ref: WatchBotRef(gatewayID: "g", profileSlug: "s"), displayName: "S", activity: "idle",
                        conversations: chats, mainChatStatus: status, mainChatDiagnostic: diagnostic)
    }

    func testEstablishedHasNoGuidance() {
        XCTAssertNil(bot(.established, main: true).mainChatGuidance(rosterState: .current))
    }

    func testNotSetUpIsOnlyClaimedFromACurrentBotList() {
        let b = bot(.notSetUp, main: false)
        XCTAssertTrue(b.mainChatGuidance(rosterState: .current)!.contains("isn't set up"))
        for state in [WatchSourceState.stale, .unavailable, .neverObserved] {
            let text = b.mainChatGuidance(rosterState: state)!
            XCTAssertFalse(text.contains("isn't set up"), "a stale list can't prove absence")
            XCTAssertTrue(text.contains("out of date"))
        }
    }

    func testUnknownIsNeverShownAsNotSetUpAndCarriesTheStage() {
        let text = bot(.unknown, main: false, diagnostic: "lookup: RosterError.notConnected").mainChatGuidance(rosterState: .current)!
        XCTAssertFalse(text.contains("isn't set up"))
        XCTAssertTrue(text.contains("lookup: RosterError.notConnected"))
        XCTAssertFalse(bot(nil, main: false).mainChatGuidance(rosterState: .current)!.contains("isn't set up"),
                       "a sender that doesn't report status is 'can't tell', not 'missing'")
    }

    func testPerBotConversationFreshnessIsIndependent() {
        let seen = WatchBot(ref: WatchBotRef(gatewayID: "g", profileSlug: "a"), displayName: "A", activity: "", conversations: [],
                            conversationsObservedAt: Fx.t0)
        let never = WatchBot(ref: WatchBotRef(gatewayID: "g", profileSlug: "b"), displayName: "B", activity: "", conversations: [])
        let gw = WatchGateway(id: "g", displayName: "G", status: .online, coverage: .reporting, observedAt: Fx.t0,
                              bots: [seen, never], running: [])
        XCTAssertEqual(WatchSourcePolicy.state(observedAt: seen.conversationsObservedAt, gatewayStatus: gw.status, now: Fx.t0.addingTimeInterval(5)), .current)
        XCTAssertEqual(WatchSourcePolicy.state(observedAt: never.conversationsObservedAt, gatewayStatus: gw.status, now: Fx.t0.addingTimeInterval(5)), .neverObserved)
    }

    func testMainChatFieldsRoundTripAndSurviveTheCap() throws {
        let b = bot(.unknown, main: false, diagnostic: "lookup: X")
        let gw = WatchGateway(id: "g", displayName: "G", status: .online, coverage: .reporting, observedAt: Fx.t0, bots: [b], running: [])
        let snap = WatchSnapshotBudget.trimmed(Fx.snapshot(gateways: [gw]))
        XCTAssertEqual(snap.gateways[0].bots[0].mainChatStatus, .unknown)
        XCTAssertEqual(snap.gateways[0].bots[0].mainChatDiagnostic, "lookup: X")
        XCTAssertEqual(try WatchCodec.unpack(WatchSnapshot.self, from: WatchCodec.pack(snap)), snap)
    }
}
