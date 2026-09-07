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
        case biometricFailed
        case biometricUnavailable
        case respondFailed(String)
        case confirmYolo
    }

    public private(set) var state: BannerState = .idle

    /// Effective YOLO state for THIS session (session.info readback +
    /// optimistic local flip confirmed by the server result).
    public private(set) var isYoloEnabled: Bool

    // MARK: Injected seams

    private let approvals: any ApprovalsProviding
    private let biometrics: any AppLockBiometricAuth
    /// The runtime session id the banner answers for (set on open/resume).
    private var boundSessionID: String?

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
            choices: request.choices
        )
        if pending == nil {
            pending = redacted
            state = .pending
        } else if pending?.requestID != redacted.requestID {
            queued.append(redacted)
        }
    }

    /// Clear a resolved approval (e.g. resolved elsewhere / timed out);
    /// promotes the next queued one if present.
    public func clearApproval(requestID: String) {
        guard pending?.requestID == requestID else { return }
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
            _ = try await approvals.respond(
                sessionID: request.sessionID,
                requestID: request.requestID,
                choice: .deny,
                all: false
            )
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
        // The FaceID gate comes BEFORE any wire call — a failed scan must
        // never send an approval.
        switch await biometrics.evaluateBiometrics(reason: "Approve a dangerous command") {
        case .success:
            break
        case .failure:
            state = .biometricFailed
            return
        case .unavailable:
            state = .biometricUnavailable
            return
        }
        do {
            _ = try await approvals.respond(
                sessionID: request.sessionID,
                requestID: request.requestID,
                choice: scope,
                all: false
            )
            clearApproval(requestID: request.requestID)
        } catch {
            state = .respondFailed(Self.nonSecret(error))
        }
    }

    // MARK: YOLO (per-session, confirmed on enable)

    /// First tap on the toggle: ask for confirmation. Nothing on the wire.
    public func requestYoloEnable() {
        state = .confirmYolo
    }

    public func cancelYoloConfirmation() {
        guard state == .confirmYolo else { return }
        state = pending != nil ? .pending : .idle
    }

    /// Confirmed enable → `config.set yolo=1 scope=session`. Optimistic
    /// local flip; on failure the state reverts (honest, never silent).
    public func confirmYoloEnable() async {
        guard let sid = boundSessionID else {
            state = .respondFailed("no session open")
            return
        }
        do {
            isYoloEnabled = try await approvals.setSessionYolo(true, sessionID: sid)
            state = pending != nil ? .pending : .idle
        } catch {
            isYoloEnabled = false
            state = .respondFailed(Self.nonSecret(error))
        }
    }

    /// Disable — immediate, no confirmation (restoring safety is never
    /// gated). `config.set yolo=0 scope=session`.
    public func disableYolo() async {
        guard let sid = boundSessionID else {
            state = .respondFailed("no session open")
            return
        }
        do {
            isYoloEnabled = try await approvals.setSessionYolo(false, sessionID: sid)
        } catch {
            state = .respondFailed(Self.nonSecret(error))
        }
    }

    // MARK: helpers

    nonisolated private static func nonSecret(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return Redaction.commandPreview(text)
    }
}
