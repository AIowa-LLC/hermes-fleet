import Foundation

// Phase B — Approvals inbox domain.
//
// An `InboxItem` is one agent decision the phone is waited on for: a
// dangerous-command approval, a clarify question, or a sudo / secret prompt.
// Items are owned at app level (not per conversation) so an agent asking for
// a decision in ANY session of ANY connected gateway shows up in one place.
//
// Wire facts this model is built on (verified in `ServerRequests.swift`,
// `Approvals.swift`, and `FleetNetworking/GatewayServerRequests.swift`):
// - approval payloads carry `request_id`, `command` (gateway-redacted),
//   `description`, `choices`. NOTHING ELSE: no expiry, no machine/host name,
//   no diff or file-change summary. Those fields are therefore absent here
//   rather than invented.
// - clarify carries `question` / `questions`, `choices`, `multi_select`.
// - sudo carries `command`; secret carries `env_var` and `prompt`. The VALUE a
//   user types for sudo / secret is never part of any model in this file.

/// Stable identity of one inbox item.
///
/// Derived from the gateway, the session, and the request id, so the same
/// request re-delivered by `open_requests`, by the legacy `approval.request`
/// event, or by a second connection collapses onto ONE item. The separator
/// is `#`, which `RoutingGuard` forbids in gateway ids, so the composite is
/// unambiguous.
public struct InboxItemID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(gatewayID: GatewayID, sessionID: String, requestID: String) {
        self.rawValue = "\(gatewayID.rawValue)#\(sessionID)#\(requestID)"
    }

    public var description: String { rawValue }
}

public enum InboxItemKind: String, Codable, Sendable, CaseIterable {
    case approval
    /// A single-question or batch clarify request.
    case question
    case sudo
    case secret
}

public enum InboxStatus: String, Codable, Sendable, CaseIterable {
    /// Waiting for a human decision.
    case pending
    case approved
    case denied
    /// A clarify / sudo / secret answer (or an explicit skip) was accepted.
    case answered
    /// The gateway no longer lists the request as pending (timed out, or it
    /// was resolved on another surface and the gateway did not say how).
    case expired
    /// The gateway withdrew the request (`request.cancel`). Never a denial.
    case cancelled
    /// The item can no longer be answered from the phone (for example its
    /// gateway was removed while it was pending, or the gateway rejected the
    /// decision as final).
    case failed

    public var isTerminal: Bool { self != .pending }
}

/// Who asked: the gateway the request came from and the session it blocks.
public struct InboxAgentIdentity: Codable, Equatable, Sendable {
    public let gatewayID: GatewayID
    /// Display name of the gateway. `ApprovalOrigin.unknownValue` when unknown.
    public let gatewayLabel: String
    /// Bot / profile name for the session when the client knows it. The
    /// approval wire payload does not carry it, so this is nil unless the
    /// feed enriches it.
    public let profileName: String?
    public let sessionID: String
    public let sessionTitle: String?

    public init(
        gatewayID: GatewayID,
        gatewayLabel: String,
        profileName: String? = nil,
        sessionID: String,
        sessionTitle: String? = nil
    ) {
        self.gatewayID = gatewayID
        self.gatewayLabel = gatewayLabel
        self.profileName = profileName
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
    }
}

/// What the agent is asking, limited to fields the wire actually carries.
public struct InboxContext: Codable, Equatable, Sendable {
    /// The command (approval, sudo). Already redacted by the client before it
    /// reaches the model. Nil for kinds without a command.
    public let command: String?
    /// Human explanation of the danger (approval `description`) or the
    /// clarify question text.
    public let detail: String?
    /// Offered choices (approval `once|session|always|deny`, clarify choices).
    public let choices: [String]
    /// Secret prompts only: the environment variable NAME. The value is never
    /// stored.
    public let envVarName: String?
    /// A batch clarify: answered one question at a time in its conversation
    /// (`clarify.lock`), so the inbox shows it but does not answer it.
    public let isBatchQuestion: Bool

    public init(
        command: String? = nil,
        detail: String? = nil,
        choices: [String] = [],
        envVarName: String? = nil,
        isBatchQuestion: Bool = false
    ) {
        self.command = command
        self.detail = detail
        self.choices = choices
        self.envVarName = envVarName
        self.isBatchQuestion = isBatchQuestion
    }
}

/// One item in the inbox.
public struct InboxItem: Identifiable, Codable, Equatable, Sendable {
    public let id: InboxItemID
    public let kind: InboxItemKind
    /// The gateway's request id: the approval `request_id` for an approval,
    /// the `srq-<hex>` id for clarify / sudo / secret. Stable across re-delivery.
    public let requestID: String
    public internal(set) var status: InboxStatus
    public let agent: InboxAgentIdentity
    public let context: InboxContext
    /// The JSON-RPC id (`srq-<hex>`) when the request arrived as a server
    /// request (answered with a JSON-RPC response). Nil for a legacy
    /// `approval.request` event (answered with `approval.respond`).
    public let serverRequestID: String?
    public let createdAt: Date
    public internal(set) var updatedAt: Date
    /// Gateway-indicated expiry. The current wire does not carry one, so this
    /// is nil unless a future gateway supplies it.
    public internal(set) var expiresAt: Date?
    /// Non-secret, display-safe reason for the last failure, if any.
    public internal(set) var failureMessage: String?

    public init(
        id: InboxItemID,
        kind: InboxItemKind,
        requestID: String,
        status: InboxStatus = .pending,
        agent: InboxAgentIdentity,
        context: InboxContext,
        serverRequestID: String?,
        createdAt: Date,
        updatedAt: Date? = nil,
        expiresAt: Date? = nil,
        failureMessage: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.requestID = requestID
        self.status = status
        self.agent = agent
        self.context = context
        self.serverRequestID = serverRequestID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.expiresAt = expiresAt
        self.failureMessage = failureMessage
    }
}

/// What the user chose. `answer` carries the typed value for clarify / sudo /
/// secret. The value is sent and forgotten: it is never stored on an item,
/// never written to the audit trail, and never logged.
public enum InboxDecision: Equatable, Sendable {
    /// Approve a dangerous command. Gated by user presence (see `InboxStore`).
    case approve(ApprovalChoice)
    /// Deny. Friction-free, matching the conversation banner.
    case deny
    /// Answer a clarify (single question), sudo, or secret. Empty means
    /// skipped / declined.
    case answer(String)
    /// Skip a clarify / sudo / secret without answering (sent as an empty answer).
    case skip
}

/// The audit-safe name of a decision (no values, no command text).
public enum InboxDecisionAction: String, Codable, Sendable, CaseIterable {
    case approveOnce
    case approveSession
    case approveAlways
    case deny
    case answer
    case skip

    public init(_ decision: InboxDecision) {
        switch decision {
        case .approve(.once): self = .approveOnce
        case .approve(.session): self = .approveSession
        case .approve(.always): self = .approveAlways
        case .approve(.deny), .deny: self = .deny
        case .answer: self = .answer
        case .skip: self = .skip
        }
    }
}

/// Who made the decision. The app does not know the signed-in owner's name
/// in this layer, so `ownerName` is optional and nil unless the composition
/// root supplies it.
public struct InboxDecider: Codable, Equatable, Sendable {
    public let deviceLabel: String
    public let ownerName: String?

    public init(deviceLabel: String, ownerName: String?) {
        self.deviceLabel = deviceLabel
        self.ownerName = ownerName
    }

    public static func thisDevice(ownerName: String?) -> InboxDecider {
        InboxDecider(deviceLabel: "this device", ownerName: ownerName)
    }
}

public enum InboxDecisionOutcome: Codable, Equatable, Sendable {
    case succeeded
    /// Non-secret, display-safe failure text.
    case failed(message: String)
}

/// One audit line: what was decided, on what, by whom, when, and whether the
/// gateway accepted it. Carries no command text and no answer text.
public struct InboxDecisionRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let itemID: InboxItemID
    public let kind: InboxItemKind
    public let action: InboxDecisionAction
    public let gatewayID: GatewayID
    public let sessionID: String
    public let agentLabel: String
    public let decider: InboxDecider
    public let decidedAt: Date
    public let outcome: InboxDecisionOutcome

    public init(
        id: UUID = UUID(),
        itemID: InboxItemID,
        kind: InboxItemKind,
        action: InboxDecisionAction,
        gatewayID: GatewayID,
        sessionID: String,
        agentLabel: String,
        decider: InboxDecider,
        decidedAt: Date,
        outcome: InboxDecisionOutcome
    ) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.action = action
        self.gatewayID = gatewayID
        self.sessionID = sessionID
        self.agentLabel = agentLabel
        self.decider = decider
        self.decidedAt = decidedAt
        self.outcome = outcome
    }
}

/// Everything the inbox persists: last-known items and the audit trail.
public struct InboxPersistedState: Codable, Equatable, Sendable {
    public var items: [InboxItem]
    public var audit: [InboxDecisionRecord]

    public init(items: [InboxItem] = [], audit: [InboxDecisionRecord] = []) {
        self.items = items
        self.audit = audit
    }

    public static let empty = InboxPersistedState()
}

/// Inbox failures. Descriptions are safe to show: none includes a command,
/// an answer, or a credential.
public enum InboxError: Error, Equatable, Sendable, LocalizedError {
    case notFound
    /// The item is already resolved and cannot be decided again.
    case notPending
    /// Approve was attempted on a long command that has not been reviewed in full.
    case reviewRequired
    /// The user-presence check for an approval did not verify. Nothing was sent.
    case presenceNotVerified(PresenceResult)
    /// The item's kind cannot be answered from the inbox (a batch clarify is
    /// answered question by question in the conversation).
    case unsupportedKind(InboxItemKind)
    /// The gateway that owns the item is not attached. Nothing was sent.
    case gatewayUnavailable
    /// The gateway rejected or failed the decision. Display-safe text.
    case gatewayRejected(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "That request is no longer in the inbox."
        case .notPending: return "That request has already been answered."
        case .reviewRequired: return "Review the full command before approving."
        case .presenceNotVerified: return "Approval needs your confirmation. Nothing was sent."
        case .unsupportedKind: return "Answer this one in its conversation."
        case .gatewayUnavailable: return "The gateway is not connected. Nothing was sent."
        case .gatewayRejected(let message): return message
        }
    }
}
