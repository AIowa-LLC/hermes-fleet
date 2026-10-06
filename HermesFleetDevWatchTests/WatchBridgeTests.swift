import XCTest
import FleetCore
import FleetUI
import FleetWatchKit
@testable import HermesFleetDev

@MainActor
private final class FakeBackend: WatchBridgeBackend {
    var isContentVisible = true
    var isAppActive = true
    var reachable: Set<String> = ["mac", "nas"]
    var pending: [String: WatchPendingApproval] = [:]   // key gateway|session|request
    var calls: [String] = []
    var denyError: String?
    var approveResult: WatchApproveResult = .done
    var messageOutcome: WatchMessageOutcome = .acknowledged
    var removeOnDeny = true
    var vanishOnDenyError = false
    func snapshot(generation: Int, now: Date) -> WatchSnapshot { .hidden(flavor: .dev, generation: generation, builtAt: now) }
    func isGatewayReachable(_ g: String) -> Bool { reachable.contains(g) }
    func refreshObservation() async { calls.append("refresh") }
    func pendingApproval(gatewayID: String, sessionID: String, requestID: String) -> WatchPendingApproval? {
        pending["\(gatewayID)|\(sessionID)|\(requestID)"]
    }
    func deny(gatewayID: String, sessionID: String, requestID: String) async -> String? {
        calls.append("deny:\(gatewayID)|\(sessionID)|\(requestID)")
        if (denyError == nil && removeOnDeny) || (denyError != nil && vanishOnDenyError) { pending["\(gatewayID)|\(sessionID)|\(requestID)"] = nil }
        return denyError
    }
    func approveOnce(gatewayID: String, sessionID: String, requestID: String) async -> WatchApproveResult {
        calls.append("approve:\(gatewayID)|\(sessionID)|\(requestID)")
        if approveResult == .done { pending["\(gatewayID)|\(sessionID)|\(requestID)"] = nil }
        return approveResult
    }
    func sendMessage(_ request: WatchMessageRequest) async -> WatchMessageOutcome {
        calls.append("send:\(request.gatewayID)#\(request.profileSlug)#\(request.conversationID ?? "main")")
        return messageOutcome
    }
}

@MainActor
final class WatchBridgeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func approvalRequest(_ d: WatchApprovalDecision, gw: String = "mac", digest: String = WatchCodec.digest("ls"),
                                 uuid: String = UUID().uuidString) -> WatchApprovalRequest {
        WatchApprovalRequest(requestUUID: uuid, gatewayID: gw, sessionID: "s1", requestID: "r1", commandDigest: digest,
                             decision: d, snapshotGeneration: 1, sentAt: t0)
    }
    private func make() -> (FakeBackend, WatchPhoneCoordinator) {
        let b = FakeBackend()
        b.pending["mac|s1|r1"] = WatchPendingApproval(commandDigest: WatchCodec.digest("ls"), requiresFullReview: false)
        return (b, WatchPhoneCoordinator(backend: b, flavor: .dev, now: { self.t0 }))
    }
    private func outcome(_ r: WatchApprovalReply) -> WatchApprovalOutcome { r.outcome }

    func testProductionFlavorRequestRejectedWithoutTouchingBackend() async {
        let (b, c) = make()
        let reply = await c.handle(.approval(approvalRequest(.deny), flavor: .production))
        guard case .rejected = reply else { return XCTFail() }
        XCTAssertTrue(b.calls.isEmpty)
    }

    func testDenyRevalidatesThenActsOnOriginalIdentityOnly() async {
        let (b, c) = make()
        let r = await c.handleApproval(approvalRequest(.deny))
        XCTAssertEqual(r.outcome, .applied)
        XCTAssertEqual(b.calls, ["refresh", "deny:mac|s1|r1"])
    }

    func testChangedCommandIsNotActedOn() async {
        let (b, c) = make()
        b.pending["mac|s1|r1"] = WatchPendingApproval(commandDigest: WatchCodec.digest("rm -rf /"), requiresFullReview: false)
        let r = await c.handleApproval(approvalRequest(.approveOnce))
        XCTAssertEqual(r.outcome, .changed)
        XCTAssertFalse(b.calls.contains { $0.hasPrefix("approve") || $0.hasPrefix("deny") })
    }

    func testExpiredOrResolvedElsewhere() async {
        let (b, c) = make()
        b.pending = [:]
        let r = await c.handleApproval(approvalRequest(.deny))
        XCTAssertEqual(r.outcome, .alreadyResolved)
        XCTAssertFalse(b.calls.contains { $0.hasPrefix("deny") })
    }

    func testDuplicateUUIDAndSecondDecisionDoNotActTwice() async {
        let (b, c) = make()
        let first = approvalRequest(.approveOnce, uuid: "u1")
        _ = await c.handleApproval(first)
        let again = await c.handleApproval(first)
        XCTAssertEqual(again.outcome, .duplicate)
        let other = await c.handleApproval(approvalRequest(.deny, uuid: "u2"))
        XCTAssertEqual(other.outcome, .applied, "a second decision for a finished approval returns the first result")
        XCTAssertEqual(b.calls.filter { $0.hasPrefix("approve") || $0.hasPrefix("deny") }.count, 1)
    }

    func testApproveNeedsActiveUnlockedPhoneAndFullReviewHandsOff() async {
        let (b, c) = make()
        b.isAppActive = false
        guard case .handOffToPhone = (await c.handleApproval(approvalRequest(.approveOnce, uuid: "a"))).outcome else { return XCTFail() }
        b.isAppActive = true
        b.pending["mac|s1|r1"] = WatchPendingApproval(commandDigest: WatchCodec.digest("ls"), requiresFullReview: true)
        guard case .handOffToPhone = (await c.handleApproval(approvalRequest(.approveOnce, uuid: "b"))).outcome else { return XCTFail() }
        b.isContentVisible = false
        guard case .handOffToPhone = (await c.handleApproval(approvalRequest(.deny, uuid: "c"))).outcome else { return XCTFail() }
        XCTAssertFalse(b.calls.contains { $0.hasPrefix("approve") })
    }

    func testPresenceFailureHandsOffAndNothingApplied() async {
        let (b, c) = make()
        b.approveResult = .needsPresence("Verification cancelled.")
        guard case .handOffToPhone = (await c.handleApproval(approvalRequest(.approveOnce))).outcome else { return XCTFail() }
    }

    func testUnreachableGatewayIsUnavailableNotSilentlyRedirected() async {
        let (b, c) = make()
        b.reachable = ["nas"]
        guard case .unavailable = (await c.handleApproval(approvalRequest(.deny))).outcome else { return XCTFail() }
        XCTAssertFalse(b.calls.contains { $0.hasPrefix("deny") })
    }

    func testDenyErrorWhileStillPendingIsFailed() async {
        let (b, c) = make()
        b.denyError = "network"
        guard case .failed = (await c.handleApproval(approvalRequest(.deny))).outcome else { return XCTFail() }
    }

    func testDenyErrorButRequestGoneIsUncertainNotFailed() async {
        let (b, c) = make()
        b.denyError = "response lost"
        b.removeOnDeny = false
        b.vanishOnDenyError = true
        guard case .uncertain = (await c.handleApproval(approvalRequest(.deny))).outcome else { return XCTFail() }
    }

    // MARK: messages

    func testMessageRoutedToExactTargetAndAcked() async {
        let (b, c) = make()
        let m = WatchMessageRequest(clientMessageID: "m1", gatewayID: "nas", profileSlug: "scout", conversationID: "c9", text: "hi", composedAt: t0)
        let r = await c.handleMessage(m)
        XCTAssertEqual(r.outcome, .acknowledged)
        XCTAssertEqual(b.calls, ["send:nas#scout#c9"])
    }

    func testMessageDedupedByClientID() async {
        let (b, c) = make()
        let m = WatchMessageRequest(clientMessageID: "m1", gatewayID: "mac", profileSlug: "scout", conversationID: nil, text: "hi", composedAt: t0)
        _ = await c.handleMessage(m)
        let again = await c.handleMessage(m)
        XCTAssertEqual(again.outcome, .alreadyAcknowledged)
        XCTAssertEqual(b.calls.filter { $0.hasPrefix("send") }.count, 1)
    }

    func testUncertainMessageIsNotRepeatedToGateway() async {
        let (b, c) = make()
        b.messageOutcome = .uncertain(reason: "timeout")
        let m = WatchMessageRequest(clientMessageID: "m1", gatewayID: "mac", profileSlug: "scout", conversationID: nil, text: "hi", composedAt: t0)
        _ = await c.handleMessage(m)
        let again = await c.handleMessage(m)
        XCTAssertEqual(again.outcome, .uncertain(reason: "timeout"))
        XCTAssertEqual(b.calls.filter { $0.hasPrefix("send") }.count, 1)
    }

    func testLockedPhoneOrOfflineGatewayRejectsMessage() async {
        let (b, c) = make()
        b.isContentVisible = false
        let m1 = WatchMessageRequest(clientMessageID: "a", gatewayID: "mac", profileSlug: "s", conversationID: nil, text: "hi", composedAt: t0)
        guard case .rejected = (await c.handleMessage(m1)).outcome else { return XCTFail() }
        b.isContentVisible = true
        b.reachable = []
        let m2 = WatchMessageRequest(clientMessageID: "b", gatewayID: "mac", profileSlug: "s", conversationID: nil, text: "hi", composedAt: t0)
        guard case .rejected = (await c.handleMessage(m2)).outcome else { return XCTFail() }
        XCTAssertTrue(b.calls.isEmpty)
    }

    // MARK: snapshot mapping

    private func observation() -> WatchFleetObservation {
        let mac = FleetGateway(id: GatewayID(rawValue: "mac"), displayName: "Mac mini")
        let nas = FleetGateway(id: GatewayID(rawValue: "nas"), displayName: "NAS")
        let macScout = FleetBot(route: Route(gatewayID: mac.id, profileSlug: ProfileSlug(rawValue: "scout")), displayName: "Scout",
                                canonicalSession: CanonicalSessionRef(id: "canon1"))
        let nasScout = FleetBot(route: Route(gatewayID: nas.id, profileSlug: ProfileSlug(rawValue: "scout")), displayName: "Scout")
        let op = LiveOperation(id: LiveOperationID(gatewayID: mac.id, runtimeSessionID: "rt1"), sessionKey: "key1", title: "Build",
                               preview: "", model: "m", startedAt: t0, lastActive: t0, messageCount: 1, status: .waiting)
        let working = LiveOperation(id: LiveOperationID(gatewayID: mac.id, runtimeSessionID: "rt2"), sessionKey: "key2", title: "Refactor",
                                    preview: "", model: "m", startedAt: t0, lastActive: t0, messageCount: 1, status: .working)
        let live = LiveOpsSnapshot(gateways: [
            LiveOpsGatewaySnapshot(gatewayID: mac.id, coverage: .reporting, operations: [op, working], observedAt: t0),
            LiveOpsGatewaySnapshot(gatewayID: nas.id, coverage: .unsupported, operations: [], observedAt: t0)])
        let approval = ApprovalRequest(requestID: "r1", sessionID: "rt1", command: "git push", choices: ["once", "deny"])
        return WatchFleetObservation(
            gateways: [mac, nas],
            connectionStates: [mac.id: .connected, nas.id: .failed(.offline)],
            botsByGateway: [mac.id: [macScout], nas.id: [nasScout]],
            sessionsByRoute: [macScout.route: [SessionSummary(id: "s-a", title: "Docs")]],
            liveOps: live, liveOpsAttention: [LiveOpsAttentionItem(operation: op, pendingApproval: approval)],
            fleetAttention: [], rosterObservedAt: t0,
            routeForSessionKey: { key, gw in key == "key1" ? macScout.route : nil })
    }

    func testSnapshotMapsObservedStateWithCoverageAndOrigin() {
        let s = WatchSnapshotBuilder.build(observation(), flavor: .dev, generation: 4, now: t0.addingTimeInterval(5), contentVisible: true)
        XCTAssertEqual(s.gateways.map(\.id), ["mac", "nas"])
        XCTAssertEqual(s.gateways[0].status, .online)
        XCTAssertEqual(s.gateways[0].coverage, .reporting)
        XCTAssertEqual(s.gateways[0].running.map(\.status), ["waiting", "working"], "active work incl. sessions waiting on input")
        XCTAssertEqual(s.gateways[1].status, .offline)
        XCTAssertEqual(s.gateways[1].coverage, .limited)
        XCTAssertEqual(s.gateways[0].bots[0].conversations.map(\.title), ["Main", "Docs"])
        XCTAssertEqual(s.approvals.count, 1)
        let a = s.approvals[0]
        XCTAssertEqual(a.gatewayID, "mac")
        XCTAssertEqual(a.profileSlug, "scout")
        XCTAssertEqual(a.sessionID, "rt1")
        XCTAssertEqual(a.commandDigest, WatchCodec.digest("git push"))
        XCTAssertFalse(a.requiresFullReview)
    }

    func testLockedSnapshotLeaksNoNames() throws {
        let s = WatchSnapshotBuilder.build(observation(), flavor: .dev, generation: 1, now: t0, contentVisible: false)
        let json = String(data: try JSONEncoder().encode(s), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("Mac mini"))
        XCTAssertFalse(json.contains("git push"))
        XCTAssertFalse(s.contentVisible)
    }

    func testFleetAttentionAndUnmappedRouteStayHonest() {
        var o = observation()
        o.routeForSessionKey = { _, _ in nil }
        let s = WatchSnapshotBuilder.build(o, flavor: .dev, generation: 1, now: t0, contentVisible: true)
        XCTAssertNil(s.approvals[0].profileSlug, "unknown route renders unknown, never guessed")
        XCTAssertNil(s.approvals[0].botName)
    }

    func testDevHostAndWatchEmbeddingIdentity() throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.aiowa.hermesfleet.dev")
        let watch = Bundle.main.bundleURL.appendingPathComponent("Watch/HermesFleetDevWatch.app/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: watch) as? [String: Any])
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.aiowa.hermesfleet.dev.watchkitapp")
        XCTAssertEqual(info["WKCompanionAppBundleIdentifier"] as? String, "com.aiowa.hermesfleet.dev")
        XCTAssertNotEqual(info["WKRunsIndependentlyOfCompanionApp"] as? Bool, true)
    }
}
