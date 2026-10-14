#if DEBUG
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
        func bot(_ gw: String, _ slug: String, _ name: String, _ activity: String, _ avatar: WatchBotAvatar) -> WatchBot {
            WatchBot(ref: WatchBotRef(gatewayID: gw, profileSlug: slug), displayName: name, activity: activity,
                     conversations: [WatchConversation(id: "main-\(gw)-\(slug)", title: "Main chat", isMain: true),
                                     WatchConversation(id: "c-\(gw)-\(slug)-1", title: "Release notes")],
                     avatar: avatar)
        }
        let scout = WatchBotAvatar(shape: "hexagon", seed: "scout", colorHex: "#30B561")
        let atlas = WatchBotAvatar(shape: "blob", seed: "atlas", colorHex: "#BF7AF6", imageDigest: Self.mockPhoto?.digest)
        let mac = WatchGateway(id: "mock-mac", displayName: "Mac mini (mock)", status: .online, coverage: .reporting,
                               observedAt: built, bots: [bot("mock-mac", "scout", "Scout", "working", scout),
                                                         bot("mock-mac", "atlas", "Atlas", "waiting", atlas)],
                               running: [WatchRunningWork(id: "op1", gatewayID: "mock-mac", title: "Refactor router", status: "working")],
                               rosterObservedAt: built, conversationsObservedAt: built)
        let nas = WatchGateway(id: "mock-nas", displayName: "NAS (mock)",
                               status: scenario == .offline ? .offline : .online,
                               coverage: scenario == .offline ? .heldOver : .limited,
                               observedAt: scenario == .offline ? built.addingTimeInterval(-900) : built,
                               bots: [bot("mock-nas", "scout", "Scout", "idle",
                                          WatchBotAvatar(shape: "cloud", seed: "scout", colorHex: "#FF9F0A"))], running: [],
                               rosterObservedAt: scenario == .offline ? built.addingTimeInterval(-900) : built,
                               conversationsObservedAt: scenario == .offline ? built.addingTimeInterval(-900) : built)
        // Each approval carries its own observation time (the mock's gateways report at `built`).
        let seen = approvals.map { a in
            WatchApproval(gatewayID: a.gatewayID, gatewayName: a.gatewayName, profileSlug: a.profileSlug, botName: a.botName,
                          sessionID: a.sessionID, sessionLabel: a.sessionLabel, requestID: a.requestID,
                          commandPreview: a.commandPreview, commandDigest: a.commandDigest,
                          requiresFullReview: a.requiresFullReview, choices: a.choices, observedAt: built)
        }
        let attention = approvals.map {
            WatchAttention(id: "approval|\($0.id)", gatewayID: $0.gatewayID, title: "Approval: \($0.botName ?? $0.gatewayName)", isApproval: true)
        }
        return WatchSnapshot(flavor: .dev, generation: generation, builtAt: built, contentVisible: true, isFixture: true,
                             gateways: [mac, nas], attention: attention, approvals: seen)
    }

    /// A generated stand-in for an uploaded bot photo (gradient + ring), so the
    /// thumbnail path is visible without a phone.
    static let mockPhoto: WatchAvatarImage? = {
        let edge = 96
        guard let ctx = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [CGColor(red: 0.98, green: 0.4, blue: 0.5, alpha: 1),
                                                 CGColor(red: 0.43, green: 0.48, blue: 1, alpha: 1)] as CFArray,
                                        locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: edge, y: edge), options: [])
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.setLineWidth(8)
        ctx.strokeEllipse(in: CGRect(x: 24, y: 24, width: 48, height: 48))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let data = out as Data
        return WatchAvatarImage(digest: WatchCodec.digest(data: data), data: data)
    }()

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
        case .avatar(let r, _):
            let photo = Self.mockPhoto
            return .avatar(WatchAvatarImage(digest: r.digest, data: photo?.digest == r.digest ? photo?.data : nil))
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
