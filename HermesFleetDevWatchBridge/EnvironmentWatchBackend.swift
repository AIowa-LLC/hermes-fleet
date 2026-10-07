import Foundation
import UIKit
import os
import FleetCore
import FleetUI
import FleetWatchKit

/// Real backend: reads and acts through the app's existing seams
/// (`AppEnvironment`, `LiveOpsStore`, the conversation session). The phone
/// remains the only holder of gateway credentials.
@MainActor
final class EnvironmentWatchBackend: WatchBridgeBackend {
    private let environment: AppEnvironment
    private let lock: AppLockController
    private let flavor: WatchAppFlavor
    private let log = Logger(subsystem: "com.aiowa.hermesfleet.dev", category: "watch-bridge")
    private var lastGoodLive: [GatewayID: Date] = [:]

    init(environment: AppEnvironment, lock: AppLockController, flavor: WatchAppFlavor) {
        self.environment = environment
        self.lock = lock
        self.flavor = flavor
    }

    /// The simulator runs the scripted fleet (see `FleetServiceGraph`): mock data.
    static var isScriptedFleet: Bool {
        #if DEBUG && targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    var isContentVisible: Bool { !lock.isLocked && !lock.isPrivacyShieldVisible }
    var isAppActive: Bool { UIApplication.shared.applicationState == .active }

    func observation() -> WatchFleetObservation {
        var bots: [GatewayID: [FleetBot]] = [:]
        var sessions: [Route: [SessionSummary]] = [:]
        var sessionsObserved: [Route: Date] = [:]
        var mainChats: [Route: AppEnvironment.MainChatState] = [:]
        for gateway in environment.gateways {
            let list = environment.bots(on: gateway.id)
            bots[gateway.id] = list
            for bot in list {
                sessions[bot.route] = environment.sessions(for: bot.route)
                sessionsObserved[bot.route] = environment.sessionsLastObserved(bot.route)
                mainChats[bot.route] = environment.mainChatState(for: bot)
            }
        }
        for live in environment.liveOps.snapshot?.gateways ?? [] {
            switch live.coverage {
            case .reporting, .unsupported:
                lastGoodLive[live.gatewayID] = max(lastGoodLive[live.gatewayID] ?? .distantPast, live.observedAt)
            case .disconnected, .authFailed, .failed: break
            }
        }
        return WatchFleetObservation(
            gateways: environment.gateways, connectionStates: environment.connectionStates,
            botsByGateway: bots, sessionsByRoute: sessions,
            liveOps: environment.liveOps.snapshot, liveOpsAttention: environment.liveOps.attentionItems,
            fleetAttention: environment.attentionItems(), rosterObservedAt: environment.rosterObservedAt,
            rosterObservedAtByGateway: environment.rosterObservedAtByGateway,
            sessionsObservedAtByRoute: sessionsObserved,
            mainChatByRoute: mainChats, lastGoodLiveObservedAt: lastGoodLive,
            routeForSessionKey: { [environment] key, gateway in
                environment.route(forLiveOperationSessionKey: key, gatewayID: gateway)
            })
    }

    func snapshot(generation: Int, now: Date, pinned: WatchConversationPin?) -> WatchSnapshot {
        WatchSnapshotBuilder.build(observation(), flavor: flavor, generation: generation, now: now,
                                   contentVisible: isContentVisible, isFixture: Self.isScriptedFleet, pinned: pinned)
    }

    func isGatewayReachable(_ gatewayID: String) -> Bool {
        environment.connectionStates[GatewayID(rawValue: gatewayID)] == .connected
    }

    func refreshObservation() async { await environment.liveOps.checkReportingNow() }

    /// Refreshes every source the Watch shows (roster, conversation lists and
    /// Live Ops), not just Live Ops. Each updates its own observation time only
    /// when its read succeeds.
    func refreshFleetState(force: Bool) async {
        await environment.refreshRoster()
        let bots = environment.gateways.flatMap { environment.bots(on: $0.id) }
        await environment.refreshSessions(routes: bots.map(\.route), force: force)
        // Read-only Main chat lookup for bots whose roster reports none (the
        // same registry the iPhone's Bot Chat uses). Never creates a chat.
        await environment.refreshMainChatLookups(for: bots)
        await environment.liveOps.checkReportingNow()
        logRefreshSummary(bots)
    }

    /// Counts only: no hosts, names, ids or content.
    private func logRefreshSummary(_ bots: [FleetBot]) {
        let gateways = environment.gateways
        let connected = gateways.filter { environment.connectionStates[$0.id] == .connected }.count
        let rosterSeen = gateways.filter { environment.rosterObservedAtByGateway[$0.id] != nil }.count
        let chatsSeen = bots.filter { environment.sessionsLastObserved($0.route) != nil }.count
        var established = 0, absent = 0, unknown = 0
        for bot in bots {
            switch environment.mainChatState(for: bot) {
            case .established: established += 1
            case .notSetUp: absent += 1
            case .unknown: unknown += 1
            }
        }
        let live = environment.liveOps.snapshot?.gateways ?? []
        let reporting = live.filter { $0.coverage.isReporting }.count
        log.info("""
            watch refresh: gateways=\(gateways.count, privacy: .public) connected=\(connected, privacy: .public) \
            rosterSeen=\(rosterSeen, privacy: .public) bots=\(bots.count, privacy: .public) \
            chatListsSeen=\(chatsSeen, privacy: .public) mainChat(est/absent/unknown)=\(established, privacy: .public)/\(absent, privacy: .public)/\(unknown, privacy: .public) \
            liveReporting=\(reporting, privacy: .public)/\(live.count, privacy: .public)
            """)
    }

    private func item(_ gatewayID: String, _ sessionID: String, _ requestID: String) -> LiveOpsAttentionItem? {
        environment.liveOps.attentionItems.first {
            $0.operation.id.gatewayID.rawValue == gatewayID
                && $0.pendingApproval?.sessionID == sessionID
                && $0.pendingApproval?.requestID == requestID
        }
    }

    func pendingApproval(gatewayID: String, sessionID: String, requestID: String) -> WatchPendingApproval? {
        guard let item = item(gatewayID, sessionID, requestID), let request = item.pendingApproval else { return nil }
        let preview = ApprovalCommandPreview(command: request.command)
        return WatchPendingApproval(commandDigest: WatchCodec.digest(request.command),
                                    requiresFullReview: preview.requiresReview || request.command.count > 140)
    }

    func deny(gatewayID: String, sessionID: String, requestID: String) async -> String? {
        guard let item = item(gatewayID, sessionID, requestID) else { return "no longer pending" }
        return await environment.liveOps.deny(item)
    }

    func approveOnce(gatewayID: String, sessionID: String, requestID: String) async -> WatchApproveResult {
        guard let item = item(gatewayID, sessionID, requestID) else { return .failed("no longer pending") }
        guard environment.liveOps.canApprove(item) else { return .reviewRequired }
        // Same biometric/passcode gate as the Home approve button.
        guard let message = await environment.liveOps.approve(item, choice: .once) else { return .done }
        if message == LiveOpsStore.reviewRequiredMessage { return .reviewRequired }
        let presenceMessages = Set([PresenceResult.cancelled, .failed, .passcodeNotSet].compactMap {
            PresenceFeedback.message(for: $0, action: .approveOnce)
        })
        // A presence message means nothing reached the gateway; anything else
        // is a changed request or a gateway error.
        return presenceMessages.contains(message) ? .needsPresence(message) : .failed(message)
    }

    /// Sends to the exact destination the Watch froze. It never looks up,
    /// creates or substitutes a chat: Main chat must already be established
    /// (reported by the roster), otherwise the user is told to do that on
    /// iPhone. The registry lookup/creation path is therefore not involved.
    func sendMessage(_ request: WatchMessageRequest) async -> WatchSendResult {
        let gatewayID = GatewayID(rawValue: request.gatewayID)
        let route = Route(gatewayID: gatewayID, profileSlug: ProfileSlug(rawValue: request.profileSlug))
        func reject(_ reason: String) -> WatchSendResult {
            WatchSendResult(.rejected(reason: reason), WatchSendDiagnostic(stage: "validate"))
        }
        // Exact route only; never fall back to another bot or gateway.
        guard let bot = environment.bot(for: route) else {
            return reject("That bot is no longer on this machine.")
        }
        let sessionID = request.target.sessionID
        switch request.target {
        case .mainChat:
            // Same knowledge the snapshot advertised: roster, registry lookup or a
            // canonical open on this phone. Never an invented id.
            switch environment.mainChatState(for: bot) {
            case .established(let ids):
                guard ids.contains(sessionID) else { return reject("Main chat changed. Choose it again on the Watch.") }
            case .notSetUp:
                return reject("This bot has no Main chat yet. Establish it on iPhone first.")
            case .unknown:
                return reject("Couldn't confirm this bot's Main chat. Refresh, or use iPhone.")
            }
        case .conversation:
            guard environment.sessions(for: route)?.contains(where: { $0.id == sessionID }) == true else {
                return reject("That conversation is no longer available.")
            }
        }
        guard let session = environment.conversationSession(for: gatewayID) else {
            return reject("Chat isn't available on that machine.")
        }
        let opened: ConversationSession
        do {
            opened = try await session.conversation.resumeSession(
                sessionID: sessionID, lastEventID: nil, profile: route.profileSlug.rawValue)
        } catch {
            // Nothing was submitted.
            let category = SafeErrorCategory.of(error)
            log.error("watch send failed at resume: \(category, privacy: .public)")
            return WatchSendResult(.failed(reason: Redaction.safeErrorDescription(error)),
                                   WatchSendDiagnostic(stage: "resume", category: category))
        }
        let canonical = environment.isCanonicalBotChat(route: route, sessionID: sessionID)
        let text = BotConversationDraft.protectingCanonical(request.text, isCanonical: canonical).text
        do {
            _ = try await session.conversation.submitPrompt(sessionID: opened.sessionID, text: text)
            return WatchSendResult(.acknowledged, nil)
        } catch let error as ConversationError {
            let category = SafeErrorCategory.of(error)
            log.error("watch send failed at submit: \(category, privacy: .public)")
            let diagnostic = WatchSendDiagnostic(stage: "submit", category: category)
            switch error {
            case .notConnected, .sessionNotFound, .invalidRequest, .invalidSessionKey:
                return WatchSendResult(.failed(reason: Redaction.safeErrorDescription(error)), diagnostic)
            case .rpcFailed, .malformedPayload, .gapUnrecoverable:
                // The gateway may have processed it before failing.
                return WatchSendResult(.uncertain(reason: Redaction.safeErrorDescription(error)), diagnostic)
            }
        } catch {
            let category = SafeErrorCategory.of(error)
            log.error("watch send failed at submit: \(category, privacy: .public)")
            return WatchSendResult(.uncertain(reason: Redaction.safeErrorDescription(error)),
                                   WatchSendDiagnostic(stage: "submit", category: category))
        }
    }
}
