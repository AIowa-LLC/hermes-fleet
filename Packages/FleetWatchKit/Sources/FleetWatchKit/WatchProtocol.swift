import Foundation

// MARK: - Watch -> phone requests

public enum WatchApprovalDecision: String, Codable, Sendable, Hashable {
    /// Always allowed for a still-pending request; never needs presence.
    case deny
    /// "Approve once" only. Session/always scopes are never offered on the Watch.
    case approveOnce
}

/// Binds the decision to the exact request the user saw. Nothing here refers
/// to "the currently selected bot": the Watch's picker is irrelevant to it.
public struct WatchApprovalRequest: Codable, Sendable, Hashable {
    public let requestUUID: String
    public let gatewayID: String
    public let sessionID: String
    public let requestID: String
    public let commandDigest: String
    public let decision: WatchApprovalDecision
    public let snapshotGeneration: Int
    public let sentAt: Date

    public init(
        requestUUID: String = UUID().uuidString, gatewayID: String, sessionID: String,
        requestID: String, commandDigest: String, decision: WatchApprovalDecision,
        snapshotGeneration: Int, sentAt: Date
    ) {
        self.requestUUID = requestUUID
        self.gatewayID = gatewayID
        self.sessionID = sessionID
        self.requestID = requestID
        self.commandDigest = commandDigest
        self.decision = decision
        self.snapshotGeneration = snapshotGeneration
        self.sentAt = sentAt
    }

    public var approvalKey: String {
        WatchApproval.key(gatewayID: gatewayID, sessionID: sessionID, requestID: requestID)
    }
}

/// The exact conversation a message is for. There is deliberately no
/// "bot only" or "default" destination: the Watch can only send to a Main chat
/// the iPhone has reported, or to a named conversation, and the phone never
/// resolves, creates or substitutes a chat on the Watch's behalf.
public enum WatchMessageTarget: Codable, Sendable, Hashable {
    /// The bot's established Main chat, identified by the session id the
    /// iPhone reported for it. The phone re-checks it is still the Main chat.
    case mainChat(sessionID: String)
    case conversation(sessionID: String)

    public var sessionID: String {
        switch self {
        case .mainChat(let id), .conversation(let id): return id
        }
    }
    public var isMain: Bool { if case .mainChat = self { return true }; return false }
}

public struct WatchMessageRequest: Codable, Sendable, Hashable {
    /// Idempotency key. The phone refuses to send the same ID to a gateway twice,
    /// and refuses the same ID with a different destination or text.
    public let clientMessageID: String
    public let gatewayID: String
    public let profileSlug: String
    public let target: WatchMessageTarget
    public let text: String
    public let composedAt: Date

    public static let maxTextLength = 1000

    public init(
        clientMessageID: String = UUID().uuidString, gatewayID: String, profileSlug: String,
        target: WatchMessageTarget, text: String, composedAt: Date
    ) {
        self.clientMessageID = clientMessageID
        self.gatewayID = gatewayID
        self.profileSlug = profileSlug
        self.target = target
        self.text = text
        self.composedAt = composedAt
    }

    /// Binds message ID, destination and payload. The random message ID salts
    /// the hash so the persisted fingerprint reveals nothing about the text.
    public var fingerprint: String {
        let kind = target.isMain ? "main" : "chat"
        return WatchCodec.digest([clientMessageID, gatewayID, profileSlug, kind, target.sessionID, text]
            .joined(separator: "\u{1F}"))
    }
}

public enum WatchRequest: Codable, Sendable, Hashable {
    /// `pinned` is the conversation the Watch has selected, so the phone keeps it
    /// in the (capped) snapshot while it still exists.
    case refresh(flavor: WatchAppFlavor, pinned: WatchConversationPin? = nil)
    case approval(WatchApprovalRequest, flavor: WatchAppFlavor)
    case message(WatchMessageRequest, flavor: WatchAppFlavor)

    public var flavor: WatchAppFlavor {
        switch self {
        case .refresh(let f, _), .approval(_, let f), .message(_, let f): return f
        }
    }
}

// MARK: - Phone -> watch replies

public enum WatchApprovalOutcome: Codable, Sendable, Hashable {
    /// The gateway acknowledged the response.
    case applied
    /// Resolved elsewhere or no longer pending when revalidated.
    case alreadyResolved
    /// The request is no longer present on its original gateway/session.
    case expired
    /// Same request ID but different content (or session): refreshed, not acted on.
    case changed
    /// The Watch acted on a snapshot too old to trust.
    case staleSnapshot
    /// Needs the iPhone (presence check, full command review, unsupported scope…).
    case handOffToPhone(reason: String)
    /// Gateway not reachable; nothing was sent.
    case unavailable(reason: String)
    /// This exact request UUID was already handled; carries the prior result.
    case duplicate
    /// The attempt reached the gateway call but the result is unknown.
    case uncertain(reason: String)
    case failed(reason: String)
}

public struct WatchApprovalReply: Codable, Sendable, Hashable {
    public let requestUUID: String
    public let approvalKey: String
    public let outcome: WatchApprovalOutcome

    public init(requestUUID: String, approvalKey: String, outcome: WatchApprovalOutcome) {
        self.requestUUID = requestUUID
        self.approvalKey = approvalKey
        self.outcome = outcome
    }
}

public enum WatchMessageOutcome: Codable, Sendable, Hashable {
    /// The gateway accepted the prompt (`submitPrompt` returned). This is NOT
    /// an assistant reply or turn completion.
    case acknowledged
    /// Rejected before any gateway call: unknown/removed target, offline, locked…
    case rejected(reason: String)
    /// Definitively not delivered (the gateway call failed before acceptance).
    case failed(reason: String)
    /// The gateway call may or may not have landed. Never auto-resent.
    case uncertain(reason: String)
    /// This clientMessageID was already acknowledged earlier.
    case alreadyAcknowledged
}

/// Which step of the phone's send path produced an outcome. Never carries
/// tokens, endpoints or message content.
public struct WatchSendDiagnostic: Codable, Sendable, Hashable {
    /// "validate", "resume" or "submit".
    public let stage: String
    /// A Swift error case name such as "ConversationError.notConnected".
    public let category: String?

    public init(stage: String, category: String? = nil) {
        self.stage = stage
        self.category = category
    }

    public var text: String { category.map { "\(stage) · \($0)" } ?? stage }
}

public struct WatchMessageReply: Codable, Sendable, Hashable {
    public let clientMessageID: String
    public let outcome: WatchMessageOutcome
    public let diagnostic: WatchSendDiagnostic?

    public init(clientMessageID: String, outcome: WatchMessageOutcome, diagnostic: WatchSendDiagnostic? = nil) {
        self.clientMessageID = clientMessageID
        self.outcome = outcome
        self.diagnostic = diagnostic
    }
}

public enum WatchReply: Codable, Sendable, Hashable {
    case snapshot(WatchSnapshot)
    case approval(WatchApprovalReply)
    case message(WatchMessageReply)
    case rejected(reason: String)
}
