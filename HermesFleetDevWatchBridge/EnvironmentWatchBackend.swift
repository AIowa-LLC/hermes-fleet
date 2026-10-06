import Foundation
import UIKit
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
        for gateway in environment.gateways {
            let list = environment.bots(on: gateway.id)
            bots[gateway.id] = list
            for bot in list { sessions[bot.route] = environment.sessions(for: bot.route) }
        }
        return WatchFleetObservation(
            gateways: environment.gateways, connectionStates: environment.connectionStates,
            botsByGateway: bots, sessionsByRoute: sessions,
            liveOps: environment.liveOps.snapshot, liveOpsAttention: environment.liveOps.attentionItems,
            fleetAttention: environment.attentionItems(), rosterObservedAt: environment.rosterObservedAt,
            routeForSessionKey: { [environment] key, gateway in
                environment.route(forLiveOperationSessionKey: key, gatewayID: gateway)
            })
    }

    func snapshot(generation: Int, now: Date) -> WatchSnapshot {
        WatchSnapshotBuilder.build(observation(), flavor: flavor, generation: generation, now: now,
                                   contentVisible: isContentVisible, isFixture: Self.isScriptedFleet)
    }

    func isGatewayReachable(_ gatewayID: String) -> Bool {
        environment.connectionStates[GatewayID(rawValue: gatewayID)] == .connected
    }

    func refreshObservation() async { await environment.liveOps.checkReportingNow() }

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

    func sendMessage(_ request: WatchMessageRequest) async -> WatchMessageOutcome {
        let gatewayID = GatewayID(rawValue: request.gatewayID)
        let route = Route(gatewayID: gatewayID, profileSlug: ProfileSlug(rawValue: request.profileSlug))
        // Exact route only; never fall back to another bot or gateway.
        guard let bot = environment.bot(for: route) else {
            return .rejected(reason: "That bot is no longer on this machine.")
        }
        let listedID: String
        if let requested = request.conversationID {
            let canonical = bot.canonicalSession.map { [$0.id, $0.resolvedID].compactMap { $0 } } ?? []
            let known = environment.sessions(for: route)?.contains { $0.id == requested } == true
            guard known || canonical.contains(requested) else {
                return .rejected(reason: "That conversation is no longer available.")
            }
            listedID = requested
        } else {
            switch await environment.resolveCanonicalChatTarget(for: bot) {
            case .success(let id): listedID = id
            case .failure(let failure): return .rejected(reason: failure.message)
            }
        }
        guard let session = environment.conversationSession(for: gatewayID) else {
            return .rejected(reason: "Chat isn't available on that machine.")
        }
        let opened: ConversationSession
        do {
            opened = try await session.conversation.resumeSession(
                sessionID: listedID, lastEventID: nil, profile: route.profileSlug.rawValue)
        } catch {
            // Nothing was submitted.
            return .failed(reason: Redaction.safeErrorDescription(error))
        }
        let canonical = environment.isCanonicalBotChat(route: route, sessionID: listedID)
        let text = BotConversationDraft.protectingCanonical(request.text, isCanonical: canonical).text
        do {
            _ = try await session.conversation.submitPrompt(sessionID: opened.sessionID, text: text)
            return .acknowledged
        } catch let error as ConversationError {
            switch error {
            case .notConnected, .sessionNotFound, .invalidRequest, .invalidSessionKey:
                return .failed(reason: Redaction.safeErrorDescription(error))
            case .rpcFailed, .malformedPayload, .gapUnrecoverable:
                // The gateway may have processed it before failing.
                return .uncertain(reason: Redaction.safeErrorDescription(error))
            }
        } catch {
            return .uncertain(reason: Redaction.safeErrorDescription(error))
        }
    }
}
