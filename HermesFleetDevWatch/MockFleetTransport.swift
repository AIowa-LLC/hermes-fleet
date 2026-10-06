#if DEBUG
import Foundation
import FleetWatchKit

/// MOCK DATA. Scripted stand-in for the iPhone so the Watch UI and its failure
/// modes can be exercised with no phone and no gateway. Everything it shows is
/// labelled "MOCK" in the UI. Compiled out of Release.
@MainActor
final class MockFleetTransport: WatchTransport {
    enum Scenario: String { case normal, stale, offline, expired, uncertain, disconnect }

    let scenario: Scenario
    let isFixture = true
    var onSnapshot: ((WatchSnapshot) -> Void)?
    var onLinkChange: ((WatchLinkState) -> Void)?
    private(set) var linkState: WatchLinkState
    private var generation = 1
    private var approvals: [WatchApproval]
    private var sentMessageIDs: Set<String> = []

    static var launchScenario: Scenario? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-fleet-watch-mock") else { return nil }
        if let i = args.firstIndex(of: "-fleet-watch-scenario"), args.indices.contains(i + 1),
           let s = Scenario(rawValue: args[i + 1]) { return s }
        return .normal
    }

    init(scenario: Scenario) {
        self.scenario = scenario
        self.linkState = scenario == .stale ? .phoneUnreachable : .reachable
        let t = Date()
        func approval(_ gw: String, _ gwName: String, _ slug: String, _ bot: String, _ req: String, _ cmd: String, full: Bool = false) -> WatchApproval {
            WatchApproval(gatewayID: gw, gatewayName: gwName, profileSlug: slug, botName: bot, sessionID: "sess-\(req)",
                          sessionLabel: "Build step", requestID: req, commandPreview: cmd,
                          commandDigest: WatchCodec.digest(cmd), requiresFullReview: full,
                          choices: ["once", "session", "deny"], observedAt: t)
        }
        approvals = [
            approval("mock-mac", "Mac mini (mock)", "scout", "Scout", "r1", "git push origin main"),
            approval("mock-mac", "Mac mini (mock)", "atlas", "Atlas", "r2", "rm -rf build && bash scripts/deploy.sh --production --region=all --force", full: true),
            approval("mock-nas", "NAS (mock)", "scout", "Scout", "r3", "docker compose restart")
        ]
    }

    func activate() {
        if scenario == .disconnect {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8)); self?.setLink(.phoneUnreachable)
                try? await Task.sleep(for: .seconds(10)); self?.setLink(.reachable)
            }
        }
    }

    private func setLink(_ s: WatchLinkState) { linkState = s; onLinkChange?(s) }

    private func snapshot() -> WatchSnapshot {
        let built = Date().addingTimeInterval(scenario == .stale ? -1200 : -4)
        func bot(_ gw: String, _ slug: String, _ name: String, _ activity: String) -> WatchBot {
            WatchBot(ref: WatchBotRef(gatewayID: gw, profileSlug: slug), displayName: name, activity: activity,
                     conversations: [WatchConversation(id: "main-\(gw)-\(slug)", title: "Main", isMain: true),
                                     WatchConversation(id: "c-\(gw)-\(slug)-1", title: "Release notes")])
        }
        let mac = WatchGateway(id: "mock-mac", displayName: "Mac mini (mock)", status: .online, coverage: .reporting,
                               observedAt: built, bots: [bot("mock-mac", "scout", "Scout", "working"), bot("mock-mac", "atlas", "Atlas", "idle")],
                               running: [WatchRunningWork(id: "op1", gatewayID: "mock-mac", title: "Refactor router", status: "working")])
        let nas = WatchGateway(id: "mock-nas", displayName: "NAS (mock)",
                               status: scenario == .offline ? .offline : .online,
                               coverage: scenario == .offline ? .heldOver : .limited,
                               observedAt: scenario == .offline ? built.addingTimeInterval(-900) : built,
                               bots: [bot("mock-nas", "scout", "Scout", "idle")], running: [])
        let attention = approvals.map {
            WatchAttention(id: "approval|\($0.id)", gatewayID: $0.gatewayID, title: "Approval: \($0.botName ?? $0.gatewayName)", isApproval: true)
        }
        return WatchSnapshot(flavor: .dev, generation: generation, builtAt: built, contentVisible: true, isFixture: true,
                             gateways: [mac, nas], attention: attention, approvals: approvals)
    }

    func send(_ request: WatchRequest) async throws -> WatchReply {
        guard linkState == .reachable else { throw WatchTransportError.notReachable }
        try? await Task.sleep(for: .milliseconds(600))
        switch request {
        case .refresh:
            generation += 1
            return .snapshot(snapshot())
        case .approval(let r, _):
            if scenario == .uncertain { throw WatchTransportError.noReply }
            guard let current = approvals.first(where: { $0.id == r.approvalKey }) else {
                return .approval(.init(requestUUID: r.requestUUID, approvalKey: r.approvalKey, outcome: .alreadyResolved))
            }
            if scenario == .expired {
                approvals.removeAll { $0.id == r.approvalKey }
                return .approval(.init(requestUUID: r.requestUUID, approvalKey: r.approvalKey, outcome: .expired))
            }
            if r.decision == .approveOnce, current.requiresFullReview {
                return .approval(.init(requestUUID: r.requestUUID, approvalKey: r.approvalKey,
                                       outcome: .handOffToPhone(reason: "Long command. Review it in full on iPhone.")))
            }
            approvals.removeAll { $0.id == r.approvalKey }
            return .approval(.init(requestUUID: r.requestUUID, approvalKey: r.approvalKey, outcome: .applied))
        case .message(let m, _):
            if scenario == .uncertain { throw WatchTransportError.noReply }
            if sentMessageIDs.contains(m.clientMessageID) {
                return .message(.init(clientMessageID: m.clientMessageID, outcome: .alreadyAcknowledged))
            }
            sentMessageIDs.insert(m.clientMessageID)
            return .message(.init(clientMessageID: m.clientMessageID, outcome: .acknowledged))
        }
    }
}
#endif
