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
/// A send outcome plus the stage that produced it.
struct WatchSendResult: Equatable {
    let outcome: WatchMessageOutcome
    let diagnostic: WatchSendDiagnostic?
    init(_ outcome: WatchMessageOutcome, _ diagnostic: WatchSendDiagnostic? = nil) {
        self.outcome = outcome
        self.diagnostic = diagnostic
    }
}

@MainActor
protocol WatchBridgeBackend: AnyObject {
    var isContentVisible: Bool { get }
    var isAppActive: Bool { get }
    func snapshot(generation: Int, now: Date, pinned: WatchConversationPin?) -> WatchSnapshot
    func isGatewayReachable(_ gatewayID: String) -> Bool
    /// Re-read pending approvals from the gateways (fresh, not cached).
    func refreshObservation() async
    /// Re-read every source the Watch displays: roster, conversation lists and
    /// Live Ops. Used for Watch refreshes; approvals only need Live Ops.
    func refreshFleetState() async
    func pendingApproval(gatewayID: String, sessionID: String, requestID: String) -> WatchPendingApproval?
    func deny(gatewayID: String, sessionID: String, requestID: String) async -> String?
    func approveOnce(gatewayID: String, sessionID: String, requestID: String) async -> WatchApproveResult
    /// Validates the exact target and, only if valid, submits the prompt.
    func sendMessage(_ request: WatchMessageRequest) async -> WatchSendResult
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
    private let ledgerStore: any WatchMessageLedgerStoring
    /// Set when the persisted ledger could not be read: sends then fail closed
    /// instead of forgetting what was already dispatched.
    private var ledgerUnreadable = false
    private(set) var generation = 0
    /// The conversation the Watch last said it has selected. Remembered so the
    /// periodic pushes (which carry no request) keep it in the capped snapshot.
    private(set) var pinnedConversation: WatchConversationPin?

    init(backend: any WatchBridgeBackend, flavor: WatchAppFlavor,
         ledgerStore: any WatchMessageLedgerStoring = InMemoryWatchMessageLedgerStore(),
         now: @escaping () -> Date = Date.init) {
        self.backend = backend
        self.flavor = flavor
        self.ledgerStore = ledgerStore
        self.now = now
        do {
            var ledger = try ledgerStore.load()
            // Anything admitted but unfinished before a restart has an unknown outcome.
            ledger.recoverAfterRestart()
            messageLedger = ledger
            try? ledgerStore.save(ledger)
        } catch {
            ledgerUnreadable = true
        }
    }

    func makeSnapshot() -> WatchSnapshot {
        generation += 1
        return backend.snapshot(generation: generation, now: now(), pinned: pinnedConversation)
    }

    func handle(_ request: WatchRequest) async -> WatchReply {
        guard request.flavor == flavor else {
            return .rejected(reason: "This Watch app belongs to a different Fleet build.")
        }
        switch request {
        case .refresh(_, let pinned):
            pinnedConversation = pinned
            await backend.refreshFleetState()
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
        func reply(_ outcome: WatchMessageOutcome, _ diagnostic: WatchSendDiagnostic? = nil) -> WatchMessageReply {
            WatchMessageReply(clientMessageID: id, outcome: outcome, diagnostic: diagnostic)
        }
        // Cheap structural checks first: these never touch the ledger.
        guard backend.isContentVisible else {
            return reply(.rejected(reason: "iPhone is locked."), WatchSendDiagnostic(stage: "validate"))
        }
        let trimmed = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, r.text.count <= WatchMessageRequest.maxTextLength else {
            return reply(.rejected(reason: "Message is empty or too long."), WatchSendDiagnostic(stage: "validate"))
        }
        guard !ledgerUnreadable else {
            return reply(.rejected(reason: "iPhone couldn't read its send record, so nothing was sent."),
                         WatchSendDiagnostic(stage: "ledger"))
        }
        switch messageLedger.admit(r) {
        case .admit: break
        case .inFlight: return reply(.uncertain(reason: "Already being sent."))
        case .finished(let outcome): return reply(outcome)
        case .conflict:
            return reply(.rejected(reason: "That message ID was already used for different content."),
                         WatchSendDiagnostic(stage: "ledger"))
        }
        // Persist the admission BEFORE any dispatch. If it cannot be recorded,
        // a restart could not tell this was attempted, so do not send.
        do { try ledgerStore.save(messageLedger) } catch {
            messageLedger.revokeAdmission(r)
            return reply(.rejected(reason: "iPhone couldn't record this send safely, so nothing was sent."),
                         WatchSendDiagnostic(stage: "ledger"))
        }
        func done(_ result: WatchSendResult) -> WatchMessageReply {
            messageLedger.finish(id, outcome: result.outcome)
            // Best effort: if this fails, the persisted `admitted` entry reads
            // as uncertain after a restart, which is the safe direction.
            try? ledgerStore.save(messageLedger)
            return reply(result.outcome, result.diagnostic)
        }
        guard backend.isGatewayReachable(r.gatewayID) else {
            return done(WatchSendResult(.rejected(reason: "That machine isn't reachable from the iPhone."),
                                        WatchSendDiagnostic(stage: "validate")))
        }
        return done(await backend.sendMessage(r))
    }
}
