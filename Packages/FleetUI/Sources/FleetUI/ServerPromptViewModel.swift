import Foundation
import Observation
import FleetCore

/// P0.1 — clarify / sudo / secret prompts raised by the gateway as
/// server→client JSON-RPC requests. (`approval` requests feed
/// `ApprovalViewModel`; this model ignores them.)
///
/// Security posture, deliberately mirroring the approval banner:
/// - SKIPPING is always friction-free: one tap, no biometrics. Declining to
///   hand over a secret must never be the hard path.
/// - ENTERING a sudo password or secret is Face ID gated: the entry field is
///   not shown until the biometric evaluation succeeds for THIS request, and a
///   failed / unavailable evaluation sends nothing.
/// - The typed value is never stored here. `submitValue(_:)` takes it as a
///   parameter, forwards it to the seam, and forgets it — it is not held in
///   any property, cached, persisted, logged, or echoed into an error.
/// - `request.cancel` (`cancel(requestID:)`) only dismisses the prompt. It
///   never sends an answer: a withdrawal is not a refusal.
@MainActor
@Observable
public final class ServerPromptViewModel {

    // MARK: Observable state

    /// The prompt on screen, if any.
    public private(set) var pending: ServerRequest?
    /// Prompts waiting behind it (oldest first).
    public private(set) var queued: [ServerRequest] = []

    public enum PromptState: Equatable, Sendable {
        case idle
        case pending
        case sending
        case biometricFailed
        case biometricUnavailable
        case failed(String)
    }

    public private(set) var state: PromptState = .idle

    /// sudo / secret only: the entry field is hidden until Face ID succeeds for
    /// the current request. Reset for every new request.
    public private(set) var isInputUnlocked = false

    /// Batch clarify: answers the gateway has accepted so far (seeded from a
    /// reconnect replay, extended by every successful lock).
    public private(set) var lockedAnswers: [String: String] = [:]

    // MARK: Injected seams

    private let prompts: any ServerPromptResponding
    private let biometrics: any AppLockBiometricAuth
    /// The runtime session id the card answers for (set on open/resume).
    private var boundSessionID: String?

    public init(prompts: any ServerPromptResponding, biometrics: any AppLockBiometricAuth) {
        self.prompts = prompts
        self.biometrics = biometrics
    }

    /// Bind to the open runtime session (requests for other sessions are
    /// ignored — the transport fans out every session's requests).
    public func bind(sessionID: String?) {
        boundSessionID = sessionID
    }

    // MARK: Intake

    /// Handle one server→client request. Approvals are not this model's.
    public func handle(_ request: ServerRequest) {
        if let bound = boundSessionID, request.sessionID != bound { return }
        let stored: ServerRequest
        switch request.kind {
        case .approval:
            return
        case .sudo(let prompt):
            // The gateway redacts server-side; the client never trusts that
            // blindly (same second pass as the approval banner).
            stored = ServerRequest(
                id: request.id,
                sessionID: request.sessionID,
                kind: .sudo(SudoPrompt(
                    sessionID: prompt.sessionID,
                    command: Redaction.commandPreview(prompt.command))),
                replayed: request.replayed)
        case .clarify, .secret:
            stored = request
        }
        // A re-delivery (reconnect `open_requests`) of a request already on
        // screen never renders a second card; for a batch it may carry more
        // locks than we know, so merge them.
        if pending?.id == stored.id {
            if case .clarify(let prompt) = stored.kind {
                lockedAnswers.merge(prompt.lockedAnswers) { current, _ in current }
            }
            return
        }
        if queued.contains(where: { $0.id == stored.id }) { return }
        if pending == nil {
            show(stored)
        } else {
            queued.append(stored)
        }
    }

    /// `request.cancel {id}` — the gateway withdrew the request. Dismiss the
    /// matching prompt only. NOTHING is sent: a withdrawal is not a refusal.
    public func cancel(requestID: String) {
        if pending?.id == requestID {
            promoteNext()
        } else {
            queued.removeAll { $0.id == requestID }
        }
    }

    // MARK: Clarify

    /// Answer a single-question clarify. An empty answer means skipped.
    public func answerClarify(_ answer: String) async {
        guard let request = pending, case .clarify(let prompt) = request.kind, !prompt.isBatch,
              state != .sending else { return }
        await send(for: request) {
            try await self.prompts.answerClarify(requestID: request.id, answer: answer)
        }
    }

    /// Lock one answer of a batch clarify. The lock that empties the remaining
    /// set resolves the request server-side and dismisses the card.
    public func lockClarify(questionID: String, answer: String) async {
        guard let request = pending, case .clarify(let prompt) = request.kind, prompt.isBatch,
              prompt.questions.contains(where: { $0.qid == questionID }),
              state != .sending else { return }
        state = .sending
        do {
            let status = try await prompts.lockClarifyAnswer(
                requestID: request.id, questionID: questionID, answer: answer)
            guard pending?.id == request.id else { return }
            switch status {
            case .locked(let remaining):
                lockedAnswers[questionID] = answer
                if remaining.isEmpty {
                    promoteNext()
                } else {
                    state = .pending
                }
            case .expired:
                promoteNext()
            }
        } catch {
            guard pending?.id == request.id else { return }
            state = .failed(Self.nonSecret(error))
        }
    }

    /// Skip a clarify: single → an empty answer; batch → cancel-all. Always
    /// one tap.
    public func skipClarify() async {
        guard let request = pending, case .clarify(let prompt) = request.kind,
              state != .sending else { return }
        await send(for: request) {
            if prompt.isBatch {
                try await self.prompts.cancelClarify(requestID: request.id)
            } else {
                try await self.prompts.answerClarify(requestID: request.id, answer: "")
            }
        }
    }

    // MARK: sudo / secret

    /// Face ID gate for entering a sudo password or secret. Nothing is on the
    /// wire; on success the entry field becomes available for THIS request.
    public func unlockInput() async {
        guard let request = pending, Self.isValuePrompt(request), state != .sending else { return }
        let reason: String
        switch request.kind {
        case .sudo: reason = "Enter your sudo password for the agent"
        default: reason = "Enter a secret for the agent"
        }
        switch await biometrics.evaluateBiometrics(reason: reason) {
        case .success:
            guard pending?.id == request.id else { return }
            isInputUnlocked = true
            state = .pending
        case .failure:
            guard pending?.id == request.id else { return }
            state = .biometricFailed
        case .unavailable:
            guard pending?.id == request.id else { return }
            state = .biometricUnavailable
        }
    }

    /// Send the typed sudo password / secret. Refused unless Face ID succeeded
    /// for this request. The value is forwarded and forgotten — never stored.
    public func submitValue(_ value: String) async {
        guard let request = pending, Self.isValuePrompt(request), isInputUnlocked,
              !value.isEmpty, state != .sending else { return }
        await send(for: request) {
            try await self.prompts.answerValue(requestID: request.id, value: value)
        }
    }

    /// Decline a sudo / secret request (an empty value). Friction-free: no
    /// biometrics, no confirmation.
    public func skipValue() async {
        guard let request = pending, Self.isValuePrompt(request), state != .sending else { return }
        await send(for: request) {
            try await self.prompts.answerValue(requestID: request.id, value: "")
        }
    }

    // MARK: helpers

    private static func isValuePrompt(_ request: ServerRequest) -> Bool {
        switch request.kind {
        case .sudo, .secret: return true
        case .approval, .clarify: return false
        }
    }

    private func show(_ request: ServerRequest) {
        pending = request
        state = .pending
        isInputUnlocked = false
        if case .clarify(let prompt) = request.kind {
            lockedAnswers = prompt.lockedAnswers
        } else {
            lockedAnswers = [:]
        }
    }

    private func promoteNext() {
        if queued.isEmpty {
            pending = nil
            state = .idle
            isInputUnlocked = false
            lockedAnswers = [:]
        } else {
            show(queued.removeFirst())
        }
    }

    /// Run one wire answer for `request`; dismiss on success, surface a
    /// non-secret failure otherwise (the prompt stays so the user can retry).
    private func send(for request: ServerRequest, _ action: () async throws -> Void) async {
        state = .sending
        do {
            try await action()
            if pending?.id == request.id { promoteNext() }
        } catch {
            guard pending?.id == request.id else { return }
            state = .failed(Self.nonSecret(error))
        }
    }

    nonisolated private static func nonSecret(_ error: Error) -> String {
        Redaction.safeErrorDescription(error)
    }
}
