import Foundation
import FleetWatchKit

/// What a gateway reports for one still-pending approval right now.
struct WatchPendingApproval: Equatable {
    let commandDigest: String
    let requiresFullReview: Bool
}

enum WatchApproveResult: Equatable {
    case done
    /// Presence (Face ID/passcode) not verified or not possible right now.
    case needsPresence(String)
    case reviewRequired
    case failed(String)
}

/// The phone-side seam. The real implementation reuses `LiveOpsStore`'s
/// approve/deny (same presence + review gates as the Home screen); tests use a
/// fake. Nothing here ever sees a credential.
@MainActor
protocol WatchBridgeBackend: AnyObject {
    var isContentVisible: Bool { get }
    var isAppActive: Bool { get }
    func snapshot(generation: Int, now: Date) -> WatchSnapshot
    func isGatewayReachable(_ gatewayID: String) -> Bool
    /// Re-read pending approvals from the gateways (fresh, not cached).
    func refreshObservation() async
    func pendingApproval(gatewayID: String, sessionID: String, requestID: String) -> WatchPendingApproval?
    func deny(gatewayID: String, sessionID: String, requestID: String) async -> String?
    func approveOnce(gatewayID: String, sessionID: String, requestID: String) async -> WatchApproveResult
    /// Validates the exact target and, only if valid, submits the prompt.
    func sendMessage(_ request: WatchMessageRequest) async -> WatchMessageOutcome
}

/// Handles Watch requests. All security decisions live here and in
/// FleetWatchKit's pure policies so they can be unit tested.
@MainActor
final class WatchPhoneCoordinator {
    private let backend: any WatchBridgeBackend
    private let flavor: WatchAppFlavor
    private let now: () -> Date
    private var approvalLedger = WatchApprovalLedger()
    private var messageLedger = WatchMessageLedger()
    private(set) var generation = 0

    init(backend: any WatchBridgeBackend, flavor: WatchAppFlavor, now: @escaping () -> Date = Date.init) {
        self.backend = backend
        self.flavor = flavor
        self.now = now
    }

    func makeSnapshot() -> WatchSnapshot {
        generation += 1
        return backend.snapshot(generation: generation, now: now())
    }

    func handle(_ request: WatchRequest) async -> WatchReply {
        guard request.flavor == flavor else {
            return .rejected(reason: "This Watch app belongs to a different Fleet build.")
        }
        switch request {
        case .refresh:
            await backend.refreshObservation()
            return .snapshot(makeSnapshot())
        case .approval(let approval, _):
            return .approval(await handleApproval(approval))
        case .message(let message, _):
            return .message(await handleMessage(message))
        }
    }

    // MARK: Approvals

    private func reply(_ r: WatchApprovalRequest, _ outcome: WatchApprovalOutcome) -> WatchApprovalReply {
        WatchApprovalReply(requestUUID: r.requestUUID, approvalKey: r.approvalKey, outcome: outcome)
    }

    private func finish(_ r: WatchApprovalRequest, _ outcome: WatchApprovalOutcome) -> WatchApprovalReply {
        approvalLedger.finish(r, outcome: outcome)
        return reply(r, outcome)
    }

    func handleApproval(_ r: WatchApprovalRequest) async -> WatchApprovalReply {
        switch approvalLedger.admit(r) {
        case .admit: break
        case .duplicate(let entry):
            switch entry {
            case .inFlight: return reply(r, .duplicate)
            case .finished(let outcome): return reply(r, outcome == .applied ? .duplicate : outcome)
            }
        case .busy: return reply(r, .duplicate)
        case .alreadyFinished(let outcome): return reply(r, outcome)
        }
        guard backend.isContentVisible else {
            return finish(r, .handOffToPhone(reason: "iPhone is locked. Unlock Hermes Fleet to act."))
        }
        guard backend.isGatewayReachable(r.gatewayID) else {
            return finish(r, .unavailable(reason: "That machine isn't reachable from the iPhone right now."))
        }
        // Revalidate against fresh state on the ORIGINAL gateway/session, never
        // against the Watch's cache and never against the Watch's selection.
        await backend.refreshObservation()
        let current = backend.pendingApproval(gatewayID: r.gatewayID, sessionID: r.sessionID, requestID: r.requestID)
        switch WatchApprovalRevalidator.validate(
            request: r, currentCommandDigest: current?.commandDigest, stillPending: current != nil) {
        case .alreadyResolved: return finish(r, .alreadyResolved)
        case .changed: return finish(r, .changed)
        case .proceed: break
        }
        switch r.decision {
        case .deny:
            let error = await backend.deny(gatewayID: r.gatewayID, sessionID: r.sessionID, requestID: r.requestID)
            guard let error else { return finish(r, .applied) }
            return finish(r, await classifyFailure(r, error))
        case .approveOnce:
            if current?.requiresFullReview == true {
                return finish(r, .handOffToPhone(reason: "Long command. Review it in full on iPhone."))
            }
            guard backend.isAppActive else {
                return finish(r, .handOffToPhone(reason: "Open Hermes Fleet on iPhone to confirm with Face ID."))
            }
            switch await backend.approveOnce(gatewayID: r.gatewayID, sessionID: r.sessionID, requestID: r.requestID) {
            case .done: return finish(r, .applied)
            case .needsPresence(let message): return finish(r, .handOffToPhone(reason: message))
            case .reviewRequired: return finish(r, .handOffToPhone(reason: "Review the full command on iPhone."))
            case .failed(let error): return finish(r, await classifyFailure(r, error))
            }
        }
    }

    /// A thrown respond error does not prove the gateway did not act. Re-read:
    /// still pending => genuinely failed; gone => outcome unconfirmed.
    private func classifyFailure(_ r: WatchApprovalRequest, _ error: String) async -> WatchApprovalOutcome {
        await backend.refreshObservation()
        if backend.pendingApproval(gatewayID: r.gatewayID, sessionID: r.sessionID, requestID: r.requestID) != nil {
            return .failed(reason: error)
        }
        return .uncertain(reason: "The request is no longer pending, but the gateway's answer wasn't confirmed.")
    }

    // MARK: Messages

    func handleMessage(_ r: WatchMessageRequest) async -> WatchMessageReply {
        let id = r.clientMessageID
        switch messageLedger.admit(id) {
        case .admit: break
        case .inFlight: return WatchMessageReply(clientMessageID: id, outcome: .uncertain(reason: "Already being sent."))
        case .finished(let outcome): return WatchMessageReply(clientMessageID: id, outcome: outcome)
        }
        func done(_ outcome: WatchMessageOutcome) -> WatchMessageReply {
            messageLedger.finish(id, outcome: outcome)
            return WatchMessageReply(clientMessageID: id, outcome: outcome)
        }
        guard backend.isContentVisible else { return done(.rejected(reason: "iPhone is locked.")) }
        let trimmed = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, r.text.count <= WatchMessageRequest.maxTextLength else {
            return done(.rejected(reason: "Message is empty or too long."))
        }
        guard backend.isGatewayReachable(r.gatewayID) else {
            return done(.rejected(reason: "That machine isn't reachable from the iPhone."))
        }
        return done(await backend.sendMessage(r))
    }
}
