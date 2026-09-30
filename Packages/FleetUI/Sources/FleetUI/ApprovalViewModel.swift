import Foundation
import Observation
import FleetCore

/// R9-T1/T2/T3 — approval banner + per-session YOLO view model.
///
/// Security posture (deliberate friction, per the R9 plan):
/// - DENY is always friction-free: one tap, no biometrics, no confirmation.
///   The safe answer must never be the hard one.
/// - APPROVE requires biometric success (or device-passcode fallback) via
///   the injected `AppLockBiometricAuth` seam. A failed/cancelled/unavailable
///   evaluation NEVER sends `approval.respond` — the command stays blocked
///   server-side (the agent thread parks until timeout or another answer).
/// - YOLO enable requires an explicit confirmation (danger copy) and is
///   SESSION-SCOPED ONLY (`config.set yolo scope=session`,
///   tui_gateway/server.py:14967): never the global `approvals.mode`, never
///   persisted. Disable is immediate (restoring safety needs no friction).
///   The readback adopts `session.info {yolo, approval_mode}` — the same
///   effective OR the guard enforces (server.py:7758) — so a gateway with
///   approvals.mode=off honestly shows YOLO ON.
@MainActor
@Observable
public final class ApprovalViewModel {

    // MARK: Observable state

    /// The pending approval (client-redacted command preview), if any.
    public private(set) var pending: ApprovalRequest?
    /// One banner may be showing at a time; a second concurrent approval
    /// queues behind it (the gateway resolves FIFO — deny answers the
    /// oldest).
    public private(set) var queued: [ApprovalRequest] = []

    public enum BannerState: Equatable, Sendable {
        case idle
        case pending
        /// Presence check did not match. Nothing was sent.
        case biometricFailed
        /// P0.2b: the user cancelled the presence prompt. Nothing was sent.
        case authCancelled
        /// P0.2b: the device has no passcode, so no presence check is
        /// possible. Nothing was sent; the UI explains how to fix it.
        case passcodeNotSet
        case respondFailed(String)
        case confirmYolo
        /// P0.2a: Approve was attempted before the full-command review for a
        /// long command. Nothing was sent.
        case reviewRequired
    }

    public private(set) var state: BannerState = .idle

    /// P0.2a — which long commands the user has reviewed in full.
    private var reviewTracker = ApprovalReviewTracker()

    /// True when the pending command is longer than the inline preview and
    /// must be reviewed in full before Approve is allowed.
    public var pendingRequiresReview: Bool {
        guard let request = pending else { return false }
        return reviewTracker.requiresReview(request)
    }

    /// True once the pending long command has been reviewed in full (always
    /// false when there is no pending request).
    public var pendingIsReviewed: Bool {
        guard let request = pending else { return false }
        return reviewTracker.isReviewed(request)
    }

    /// Whether Approve is currently allowed for the pending request. Deny is
    /// never gated and does not consult this.
    public var canApprove: Bool {
        guard let request = pending else { return false }
        return reviewTracker.canApprove(request)
    }

    /// The user opened the full-command review and finished it (scrolled to
    /// the end or confirmed). Only the CURRENT pending request is affected.
    public func markPendingReviewed() {
        guard let request = pending else { return }
        reviewTracker.markReviewed(request)
        if state == .reviewRequired { state = .pending }
    }

    /// P0.2b: which privilege-expanding action the current banner feedback
    /// (`biometricFailed` / `authCancelled` / `passcodeNotSet`) is about.
    public private(set) var lastPresenceAction: PresenceAction = .approveOnce

    /// P0.2b: inline feedback for a failed/cancelled YOLO-enable presence
    /// check. Kept apart from `state` so it never clobbers a pending banner.
    public private(set) var yoloNotice: String?

    /// True while a presence prompt is up; a second tap must not stack a
    /// second prompt or a second wire call.
    public private(set) var isVerifyingPresence = false

    public func dismissYoloNotice() { yoloNotice = nil }

    /// Effective YOLO state for THIS session (session.info readback +
    /// optimistic local flip confirmed by the server result).
    public private(set) var isYoloEnabled: Bool

    // MARK: Injected seams

    private let approvals: any ApprovalsProviding
    private let biometrics: any AppLockBiometricAuth
    /// The runtime session id the banner answers for (set on open/resume).
    private var boundSessionID: String?
    private var yoloIntent = 0

    public init(
        approvals: any ApprovalsProviding,
        biometrics: any AppLockBiometricAuth,
        initialYolo: Bool? = nil
    ) {
        self.approvals = approvals
        self.biometrics = biometrics
        self.isYoloEnabled = initialYolo ?? false
    }

    // MARK: Binding

    /// Bind to the open runtime session (approvals for other sessions are
    /// ignored — the transport fans out every session's events).
    public func bind(sessionID: String?) {
        if boundSessionID != sessionID { yoloIntent += 1 }
        boundSessionID = sessionID
    }

    // MARK: Event intake

    /// Handle one pushed `approval.request`. The stored command preview is
    /// the CLIENT-side redacted pass (`Redaction.commandPreview`) — the
    /// gateway already redacts (#48456) but the client never trusts that
    /// blindly.
    public func handleApprovalRequest(_ request: ApprovalRequest) {
        // Only surface approvals for THIS conversation's session.
        if let bound = boundSessionID, request.sessionID != bound { return }
        let redacted = ApprovalRequest(
            requestID: request.requestID,
            sessionID: request.sessionID,
            command: Redaction.commandPreview(request.command),
            detail: request.detail,
            choices: request.choices,
            serverRequestID: request.serverRequestID
        )
        // The same approval seen twice (a reconnect re-delivering it through
        // `open_requests`, or the legacy event racing the server request)
        // never renders a second banner. If the new copy carries the
        // server-request id, adopt it so the answer takes the JSON-RPC
        // response path.
        if let current = pending, current.requestID == redacted.requestID {
            if current.serverRequestID == nil, redacted.serverRequestID != nil {
                pending = redacted
            }
            return
        }
        if let index = queued.firstIndex(where: { $0.requestID == redacted.requestID }) {
            if queued[index].serverRequestID == nil, redacted.serverRequestID != nil {
                queued[index] = redacted
            }
            return
        }
        if pending == nil {
            pending = redacted
            state = .pending
        } else {
            queued.append(redacted)
        }
    }

    /// Clear a resolved approval (e.g. resolved elsewhere / timed out);
    /// promotes the next queued one if present.
    public func clearApproval(requestID: String) {
        guard pending?.requestID == requestID else { return }
        promoteNext()
    }

    /// P0.1 — `request.cancel {id}`: the gateway withdrew the server→client
    /// request (timeout, interrupt, answered from another surface). Dismiss
    /// the matching banner ONLY. A withdrawal is never a denial: nothing is
    /// sent, no `respond` call is made, and the queued approval behind it (if
    /// any) is promoted.
    public func cancelServerRequest(id: String) {
        if pending?.serverRequestID == id {
            promoteNext()
        } else {
            queued.removeAll { $0.serverRequestID == id }
        }
    }

    private func promoteNext() {
        reviewTracker.retain(requestIDs: Set(queued.map(\.requestID)))
        if !queued.isEmpty {
            pending = queued.removeFirst()
            state = .pending
        } else {
            pending = nil
            state = .idle
        }
    }

    /// Adopt the `session.info` approval-bypass readback.
    public func applySessionInfo(yolo: Bool?, approvalMode: String?) {
        if let yolo {
            isYoloEnabled = yolo
        } else if let approvalMode {
            isYoloEnabled = approvalMode == "off"
        }
    }

    /// R9-T1 rework: reconnect-restore — `approval.pending` readback for
    /// banners whose push event was missed while detached. Called on
    /// open/reconnect. Fail-soft by design: a failed restore must never
    /// break the conversation (a later push event or the next reconnect
    /// retries); results are deduped against already-pending/queued ids so
    /// a push racing the restore never double-renders one banner.
    public func restorePendingApprovals() async {
        guard let sid = boundSessionID else { return }
        let restored: [ApprovalRequest]
        do {
            restored = try await approvals.pendingApprovals(sessionID: sid)
        } catch {
            // Fail-soft: leave current banner state untouched.
            return
        }
        let known = Set([self.pending?.requestID].compactMap { $0 } + queued.map(\.requestID))
        for request in restored where !known.contains(request.requestID) {
            handleApprovalRequest(request)
        }
    }

    // MARK: Actions

    /// DENY — friction-free, no biometrics. The safe answer is one tap.
    public func deny() async {
        guard let request = pending else { return }
        do {
            _ = try await approvals.respond(to: request, choice: .deny, all: false)
            clearApproval(requestID: request.requestID)
        } catch {
            state = .respondFailed(Self.nonSecret(error))
        }
    }

    /// APPROVE — biometric-gated. `scope` picks the gateway choice:
    /// `.once` runs this command only; `.session` auto-approves the pattern
    /// for the rest of the session; `.always` persists the allowlist entry
    /// (presented only when the gateway offered it in `choices`).
    public func approve(scope: ApprovalChoice) async {
        guard let request = pending else { return }
        // P0.2a: a long command must be reviewed in full first. This sits
        // before the biometric prompt so an unreviewed approval never even
        // asks for Face ID, and never reaches the wire.
        guard reviewTracker.canApprove(request) else {
            state = .reviewRequired
            return
        }
        // The user-presence gate (biometrics, device-passcode fallback) comes
        // BEFORE any wire call — a failed/cancelled check never sends an
        // approval. Approve once / session / Always each check exactly once.
        guard let action = PresenceAction(approvalChoice: scope), !isVerifyingPresence else { return }
        isVerifyingPresence = true
        let result = await biometrics.verifyPresence(action)
        isVerifyingPresence = false
        guard let current = pending, current.requestID == request.requestID,
              current.sessionID == request.sessionID, current.command == request.command,
              reviewTracker.canApprove(current) else { return }
        lastPresenceAction = action
        switch result {
        case .verified:
            break
        case .failed:
            state = .biometricFailed
            return
        case .cancelled:
            state = .authCancelled
            return
        case .passcodeNotSet:
            state = .passcodeNotSet
            return
        }
        // The request may have been withdrawn/answered while the prompt was up.
        guard pending?.requestID == request.requestID else { return }
        do {
            _ = try await approvals.respond(to: current, choice: scope, all: false)
            clearApproval(requestID: request.requestID)
        } catch {
            state = .respondFailed(Self.nonSecret(error))
        }
    }

    // MARK: YOLO (per-session, confirmed on enable)

    /// First tap on the toggle: ask for confirmation. Nothing on the wire.
    public func requestYoloEnable() {
        yoloIntent += 1
        state = .confirmYolo
    }

    public func cancelYoloConfirmation() {
        guard state == .confirmYolo else { return }
        yoloIntent += 1
        state = pending != nil ? .pending : .idle
    }

    /// Confirmed enable → `config.set yolo=1 scope=session`. Optimistic
    /// local flip; on failure the state reverts (honest, never silent).
    ///
    /// P0.2b: the confirmation alone is not enough — a fresh user-presence
    /// check (biometrics, passcode fallback) must verify first. On cancel or
    /// failure YOLO stays off, nothing is sent, and `yoloNotice` says why.
    public func confirmYoloEnable() async {
        await beginYoloEnable()?.value
    }

    /// Capture confirmation synchronously before SwiftUI dismisses the dialog.
    @discardableResult
    public func beginYoloEnable() -> Task<Void, Never>? {
        guard let sid = boundSessionID, !isVerifyingPresence, state == .confirmYolo else { return nil }
        let intent = yoloIntent
        state = pending != nil ? .pending : .idle
        isVerifyingPresence = true
        return Task { await completeYoloEnable(sessionID: sid, intent: intent) }
    }

    private func completeYoloEnable(sessionID sid: String, intent: Int) async {
        guard yoloIntent == intent, boundSessionID == sid else {
            isVerifyingPresence = false
            return
        }
        yoloNotice = nil
        isVerifyingPresence = true
        let result = await biometrics.verifyPresence(.enableYolo)
        isVerifyingPresence = false
        guard yoloIntent == intent, boundSessionID == sid else { return }
        guard result == .verified else {
            yoloNotice = PresenceFeedback.message(for: result, action: .enableYolo)
            return
        }
        do {
            let enabled = try await approvals.setSessionYolo(true, sessionID: sid)
            guard yoloIntent == intent, boundSessionID == sid else { return }
            isYoloEnabled = enabled
            state = pending != nil ? .pending : .idle
        } catch {
            guard yoloIntent == intent, boundSessionID == sid else { return }
            isYoloEnabled = false
            state = .respondFailed(Self.nonSecret(error))
        }
    }

    /// Disable — immediate, no confirmation (restoring safety is never
    /// gated). `config.set yolo=0 scope=session`.
    public func disableYolo() async {
        yoloIntent += 1
        guard let sid = boundSessionID else {
            state = .respondFailed("no session open")
            return
        }
        let intent = yoloIntent
        do {
            let enabled = try await approvals.setSessionYolo(false, sessionID: sid)
            guard yoloIntent == intent, boundSessionID == sid else { return }
            isYoloEnabled = enabled
        } catch {
            guard yoloIntent == intent, boundSessionID == sid else { return }
            state = .respondFailed(Self.nonSecret(error))
        }
    }

    // MARK: helpers

    nonisolated private static func nonSecret(_ error: Error) -> String {
        Redaction.safeErrorDescription(error)
    }
}
