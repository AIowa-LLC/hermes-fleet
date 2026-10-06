import Foundation
@testable import FleetWatchKit

enum Fx {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func approval(
        gateway: String = "mac-mini", session: String = "s1", request: String = "r1",
        command: String = "ls -la", full: Bool = false, choices: [String] = ["once", "session", "deny"]
    ) -> WatchApproval {
        WatchApproval(
            gatewayID: gateway, gatewayName: "Mac mini", profileSlug: "scout", botName: "Scout",
            sessionID: session, sessionLabel: "Build", requestID: request,
            commandPreview: command, commandDigest: WatchCodec.digest(command),
            requiresFullReview: full, choices: choices, observedAt: t0)
    }

    static func gateway(_ id: String, name: String, bots: [WatchBot] = []) -> WatchGateway {
        WatchGateway(id: id, displayName: name, status: .online, coverage: .reporting,
                     observedAt: t0, bots: bots, running: [])
    }

    static func bot(_ gw: String, _ slug: String, name: String, chats: [WatchConversation] = []) -> WatchBot {
        WatchBot(ref: WatchBotRef(gatewayID: gw, profileSlug: slug), displayName: name,
                 activity: "idle", conversations: chats)
    }

    static func snapshot(gateways: [WatchGateway], approvals: [WatchApproval] = [], flavor: WatchAppFlavor = .dev) -> WatchSnapshot {
        WatchSnapshot(flavor: flavor, generation: 1, builtAt: t0, contentVisible: true,
                      gateways: gateways, attention: [], approvals: approvals)
    }

    static func approvalRequest(_ a: WatchApproval, _ d: WatchApprovalDecision = .deny, uuid: String = UUID().uuidString) -> WatchApprovalRequest {
        WatchApprovalRequest(requestUUID: uuid, gatewayID: a.gatewayID, sessionID: a.sessionID,
                             requestID: a.requestID, commandDigest: a.commandDigest, decision: d,
                             snapshotGeneration: 1, sentAt: t0)
    }

    static func message(_ id: String = UUID().uuidString, text: String = "hello") -> WatchMessageRequest {
        WatchMessageRequest(clientMessageID: id, gatewayID: "mac-mini", profileSlug: "scout",
                            conversationID: nil, text: text, composedAt: t0)
    }
}
