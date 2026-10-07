import Foundation
import FleetCore
import FleetUI
import FleetWatchKit

/// Everything the Watch snapshot is derived from, as plain values so the
/// mapping is testable without a live `AppEnvironment`.
struct WatchFleetObservation {
    var gateways: [FleetGateway]
    var connectionStates: [GatewayID: GatewayConnectionState]
    var botsByGateway: [GatewayID: [FleetBot]]
    var sessionsByRoute: [Route: [SessionSummary]]
    var liveOps: LiveOpsSnapshot?
    var liveOpsAttention: [LiveOpsAttentionItem]
    var fleetAttention: [FleetAttentionItem]
    var rosterObservedAt: Date?
    /// Per-gateway time of the last SUCCESSFUL roster read.
    var rosterObservedAtByGateway: [GatewayID: Date] = [:]
    /// Per-route time of the last SUCCESSFUL conversation-list read.
    var sessionsObservedAtByRoute: [Route: Date] = [:]
    var routeForSessionKey: (String, GatewayID) -> Route?
}

/// Maps Fleet's observed state to the Watch wire model. Observed state only:
/// a value the phone has not seen is nil/unknown, never inferred.
enum WatchSnapshotBuilder {
    static func build(
        _ obs: WatchFleetObservation, flavor: WatchAppFlavor, generation: Int,
        now: Date, contentVisible: Bool, isFixture: Bool = false, pinned: WatchConversationPin? = nil
    ) -> WatchSnapshot {
        guard contentVisible else { return .hidden(flavor: flavor, generation: generation, builtAt: now) }
        let names = Dictionary(obs.gateways.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let gateways = obs.gateways.map { gateway -> WatchGateway in
            let live = obs.liveOps?.gateways.first { $0.gatewayID == gateway.id }
            let status = status(for: obs.connectionStates[gateway.id] ?? .idle)
            let bots = (obs.botsByGateway[gateway.id] ?? []).map { bot(from: $0, obs) }
            let running = (live?.operations ?? []).filter { $0.status.isActive }.map {
                WatchRunningWork(id: $0.id.description, gatewayID: gateway.id.rawValue,
                                 title: clip($0.title, 40), status: $0.status.wireValue)
            }
            return WatchGateway(
                id: gateway.id.rawValue, displayName: clip(gateway.displayName, 40), status: status,
                coverage: coverage(live), observedAt: liveObservedAt(live),
                bots: bots, running: running,
                rosterObservedAt: obs.rosterObservedAtByGateway[gateway.id],
                conversationsObservedAt: conversationsObservedAt(gateway.id, obs))
        }
        var attention: [WatchAttention] = obs.fleetAttention.map {
            WatchAttention(id: $0.id, gatewayID: $0.gatewayID.rawValue, title: clip($0.title, 60),
                           detail: $0.detail.map { clip($0, 60) })
        }
        var approvals: [WatchApproval] = []
        for item in obs.liveOpsAttention {
            let gatewayID = item.operation.id.gatewayID
            guard let request = item.pendingApproval else {
                attention.append(WatchAttention(
                    id: "wait|\(item.operation.id)", gatewayID: gatewayID.rawValue,
                    title: clip(item.operation.title, 60), detail: "Waiting for input"))
                continue
            }
            let route = obs.routeForSessionKey(item.operation.sessionKey, gatewayID)
            let bot = route.flatMap { r in obs.botsByGateway[gatewayID]?.first { $0.route == r } }
            let preview = ApprovalCommandPreview(command: request.command)
            let approval = WatchApproval(
                gatewayID: gatewayID.rawValue, gatewayName: clip(names[gatewayID] ?? gatewayID.rawValue, 40),
                profileSlug: route?.profileSlug.rawValue, botName: bot.map { clip($0.displayName, 40) },
                sessionID: request.sessionID,
                sessionLabel: clip(ApprovalOrigin.sessionLabel(title: item.operation.title, id: request.sessionID) ?? "unknown", 40),
                requestID: request.requestID, commandPreview: clip(preview.visibleText, 140),
                commandDigest: WatchCodec.digest(request.command),
                requiresFullReview: preview.requiresReview || request.command.count > 140,
                choices: request.choices,
                observedAt: liveObservedAt(obs.liveOps?.gateways.first { $0.gatewayID == gatewayID }))
            approvals.append(approval)
            attention.append(WatchAttention(
                id: "approval|\(approval.id)", gatewayID: gatewayID.rawValue,
                title: "Approval: \(approval.botName ?? approval.gatewayName)", detail: nil, isApproval: true))
        }
        return WatchSnapshotBudget.trimmed(WatchSnapshot(
            flavor: flavor, generation: generation, builtAt: now, contentVisible: true,
            isFixture: isFixture, gateways: gateways, attention: attention, approvals: approvals,
            removedPin: removedPin(pinned, in: gateways)), pinned: pinned)
    }

    /// The pin is "removed" only when its bot is on the phone and the bot's FULL
    /// (untrimmed) conversation list lacks it. A bot or machine that is itself
    /// missing is reported by the Watch's own resolver.
    private static func removedPin(_ pin: WatchConversationPin?, in gateways: [WatchGateway]) -> WatchConversationPin? {
        guard let pin,
              let bot = gateways.first(where: { $0.id == pin.gatewayID })?.bots
                  .first(where: { $0.ref.profileSlug == pin.profileSlug }) else { return nil }
        return bot.conversations.contains { $0.id == pin.conversationID } ? nil : pin
    }

    static func status(for state: GatewayConnectionState) -> WatchGatewayStatus {
        switch state {
        case .connected: return .online
        case .connecting: return .connecting
        case .idle: return .notConnected
        case .disconnected: return .offline
        case .failed(let s):
            switch s {
            case .online: return .online
            case .connecting: return .connecting
            case .degraded: return .degraded
            case .authenticationRequired: return .authenticationRequired
            case .offline: return .offline
            case .unsupported: return .unsupported
            }
        }
    }

    static func coverage(_ live: LiveOpsGatewaySnapshot?) -> WatchCoverage {
        guard let live else { return .unknown }
        switch live.coverage {
        case .reporting: return .reporting
        case .unsupported: return .limited
        case .disconnected, .authFailed, .failed: return live.hasEverReported ? .heldOver : .unknown
        }
    }

    /// A Live Ops observation counts only when the gateway actually answered.
    /// Failure snapshots are stamped with the time of the FAILED attempt, so
    /// using their `observedAt` would make unreachable data look freshly seen.
    private static func liveObservedAt(_ live: LiveOpsGatewaySnapshot?) -> Date? {
        guard let live else { return nil }
        switch live.coverage {
        case .reporting, .unsupported: return live.observedAt
        case .disconnected, .authFailed, .failed: return nil
        }
    }

    /// The OLDEST conversation-list read among the gateway's bots, so one
    /// stale bot cannot hide behind a fresh sibling. Nil when any bot has no
    /// successful read (or the gateway has no bots).
    private static func conversationsObservedAt(_ gateway: GatewayID, _ obs: WatchFleetObservation) -> Date? {
        let bots = obs.botsByGateway[gateway] ?? []
        guard !bots.isEmpty else { return nil }
        let times = bots.compactMap { obs.sessionsObservedAtByRoute[$0.route] }
        return times.count == bots.count ? times.min() : nil
    }

    private static func bot(from bot: FleetBot, _ obs: WatchFleetObservation) -> WatchBot {
        var chats: [WatchConversation] = []
        var seen = Set<String>()
        if let canonical = bot.canonicalSession {
            let id = canonical.resolvedID ?? canonical.id
            chats.append(WatchConversation(id: id, title: "Main chat", isMain: true))
            seen.insert(id)
            seen.insert(canonical.id)
        }
        for session in (obs.sessionsByRoute[bot.route] ?? []) where !seen.contains(session.id) {
            let title = session.title.isEmpty ? (session.preview.isEmpty ? "Untitled" : session.preview) : session.title
            chats.append(WatchConversation(id: session.id, title: clip(title, 40)))
            seen.insert(session.id)
        }
        return WatchBot(ref: WatchBotRef(gatewayID: bot.gatewayID.rawValue, profileSlug: bot.profileSlug.rawValue),
                        displayName: clip(bot.displayName, 40), activity: bot.activity.rawValue, conversations: chats)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}
