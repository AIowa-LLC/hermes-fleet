import Foundation

// MARK: - Identity

/// Which Fleet app a payload belongs to. A Dev Watch app only accepts Dev
/// payloads and vice versa, so a mispaired build can never act on the other
/// app's gateways.
public enum WatchAppFlavor: String, Codable, Sendable, Hashable {
    case production
    case dev
}

/// Fleet's own hierarchy: a Gateway (the machine/connection) hosts Profiles;
/// a profile is shown as a Bot (`Route` = gateway + profile); a bot has
/// Conversations (sessions). The Watch mirrors that, nothing more.
public struct WatchBotRef: Hashable, Codable, Sendable {
    public let gatewayID: String
    public let profileSlug: String

    public init(gatewayID: String, profileSlug: String) {
        self.gatewayID = gatewayID
        self.profileSlug = profileSlug
    }
}

// MARK: - Snapshot (phone -> watch, observed state only)

public enum WatchGatewayStatus: String, Codable, Sendable, Hashable {
    case online, connecting, degraded, authenticationRequired, offline, unsupported
    /// The iPhone has no gateway connection and has not recorded a failure
    /// (never attempted, or intentionally idle). Not proof the machine is down.
    case notConnected
}

/// How much of a gateway's activity the phone can actually observe.
public enum WatchCoverage: String, Codable, Sendable, Hashable {
    /// The gateway is reporting live operations right now.
    case reporting
    /// Reachable but the gateway cannot report running work (limited coverage).
    case limited
    /// Not reporting; any operations shown are held-over, last-good data.
    case heldOver
    /// Never observed.
    case unknown
}

public struct WatchConversation: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// The bot's canonical "main" chat.
    public let isMain: Bool

    public init(id: String, title: String, isMain: Bool = false) {
        self.id = id
        self.title = title
        self.isMain = isMain
    }
}

/// A conversation the Watch asks the phone to keep in its snapshot. The
/// snapshot caps conversations per bot, so without this a selected chat beyond
/// the cap would fall out of the list.
public struct WatchConversationPin: Hashable, Codable, Sendable {
    public let gatewayID: String
    public let profileSlug: String
    public let conversationID: String

    public init(gatewayID: String, profileSlug: String, conversationID: String) {
        self.gatewayID = gatewayID
        self.profileSlug = profileSlug
        self.conversationID = conversationID
    }
}

/// What the iPhone actually knows about a bot's Main chat. "Unknown" is never
/// shown as "not set up": only a successful registry lookup (with no roster
/// chat) is absence.
public enum WatchMainChatStatus: String, Codable, Sendable, Hashable {
    case established, notSetUp, unknown
}

public struct WatchBot: Hashable, Codable, Sendable, Identifiable {
    public let ref: WatchBotRef
    public let displayName: String
    public let activity: String
    public let conversations: [WatchConversation]
    /// How many conversations the phone knows for this bot before the snapshot
    /// cap. Nil from a sender that doesn't report it.
    public let totalConversations: Int?
    /// The phone's Main chat knowledge (nil from a sender that doesn't report it).
    public let mainChatStatus: WatchMainChatStatus?
    /// Safe one-line reason when the status is `unknown` (stage + error case name).
    public let mainChatDiagnostic: String?
    /// When the phone last successfully read THIS bot's conversation list.
    public let conversationsObservedAt: Date?

    /// Conversations that exist on the phone but are not in `conversations`
    /// because of the snapshot cap (not because they were removed).
    public var omittedConversationCount: Int { max(0, (totalConversations ?? conversations.count) - conversations.count) }

    public var id: String { "\(ref.gatewayID)#\(ref.profileSlug)" }

    /// The roster-reported Main chat, if the iPhone knows one. Nil means Main
    /// chat is not established: the Watch never creates or guesses one.
    public var mainChat: WatchConversation? { conversations.first { $0.isMain } }

    /// Honest guidance when there is no usable Main chat entry, else nil.
    /// `rosterState` says whether the bot list itself is trustworthy right now.
    public func mainChatGuidance(rosterState: WatchSourceState) -> String? {
        if mainChat != nil { return nil }
        switch mainChatStatus ?? .unknown {
        case .established:
            return "Main chat exists but wasn't included. Refresh."
        case .notSetUp:
            return rosterState == .current
                ? "Main chat isn't set up for this bot. Open it on iPhone to establish it."
                : "The last check found no Main chat, but this bot list is out of date. Refresh first."
        case .unknown:
            let why = mainChatDiagnostic.map { " (\($0))" } ?? ""
            return "Can't tell whether Main chat exists\(why). Refresh. If it persists, open this bot on iPhone."
        }
    }

    public init(ref: WatchBotRef, displayName: String, activity: String, conversations: [WatchConversation],
                totalConversations: Int? = nil, mainChatStatus: WatchMainChatStatus? = nil,
                mainChatDiagnostic: String? = nil, conversationsObservedAt: Date? = nil) {
        self.totalConversations = totalConversations
        self.mainChatStatus = mainChatStatus
        self.mainChatDiagnostic = mainChatDiagnostic
        self.conversationsObservedAt = conversationsObservedAt
        self.ref = ref
        self.displayName = displayName
        self.activity = activity
        self.conversations = conversations
    }
}

public struct WatchRunningWork: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let gatewayID: String
    public let title: String
    public let status: String

    public init(id: String, gatewayID: String, title: String, status: String) {
        self.id = id
        self.gatewayID = gatewayID
        self.title = title
        self.status = status
    }
}

public struct WatchAttention: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let gatewayID: String
    public let title: String
    public let detail: String?
    public let isApproval: Bool

    public init(id: String, gatewayID: String, title: String, detail: String? = nil, isApproval: Bool = false) {
        self.id = id
        self.gatewayID = gatewayID
        self.title = title
        self.detail = detail
        self.isApproval = isApproval
    }
}

public struct WatchGateway: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let status: WatchGatewayStatus
    public let coverage: WatchCoverage
    /// When the phone last observed this gateway's running work / approvals
    /// (Live Ops; nil = never).
    public let observedAt: Date?
    public let bots: [WatchBot]
    public let running: [WatchRunningWork]
    /// When the phone last successfully read this gateway's bot roster.
    public let rosterObservedAt: Date?
    /// When the phone last successfully read this gateway's conversation lists.
    public let conversationsObservedAt: Date?

    public init(
        id: String, displayName: String, status: WatchGatewayStatus, coverage: WatchCoverage,
        observedAt: Date?, bots: [WatchBot], running: [WatchRunningWork],
        rosterObservedAt: Date? = nil, conversationsObservedAt: Date? = nil
    ) {
        self.rosterObservedAt = rosterObservedAt
        self.conversationsObservedAt = conversationsObservedAt
        self.id = id
        self.displayName = displayName
        self.status = status
        self.coverage = coverage
        self.observedAt = observedAt
        self.bots = bots
        self.running = running
    }
}

/// A pending approval, bound to its ORIGINAL gateway/session/request. The
/// digest is a hash of the exact (already redacted) command the phone saw, so
/// the phone can detect that the request changed before acting.
public struct WatchApproval: Hashable, Codable, Sendable, Identifiable {
    public let gatewayID: String
    public let gatewayName: String
    /// Profile/bot when the phone could resolve it; nil renders as unknown.
    public let profileSlug: String?
    public let botName: String?
    public let sessionID: String
    public let sessionLabel: String
    public let requestID: String
    public let commandPreview: String
    public let commandDigest: String
    /// The phone's full-review rule: the command is longer than the compact
    /// preview, so approval needs the phone's full command review.
    public let requiresFullReview: Bool
    public let choices: [String]
    /// When the phone last observed THIS request's gateway reporting pending
    /// approvals. Nil (never observed) is never actionable. This is deliberately
    /// not the snapshot's creation time.
    public let observedAt: Date?

    public var id: String { WatchApproval.key(gatewayID: gatewayID, sessionID: sessionID, requestID: requestID) }

    public static func key(gatewayID: String, sessionID: String, requestID: String) -> String {
        "\(gatewayID)|\(sessionID)|\(requestID)"
    }

    public init(
        gatewayID: String, gatewayName: String, profileSlug: String?, botName: String?,
        sessionID: String, sessionLabel: String, requestID: String,
        commandPreview: String, commandDigest: String, requiresFullReview: Bool,
        choices: [String], observedAt: Date?
    ) {
        self.gatewayID = gatewayID
        self.gatewayName = gatewayName
        self.profileSlug = profileSlug
        self.botName = botName
        self.sessionID = sessionID
        self.sessionLabel = sessionLabel
        self.requestID = requestID
        self.commandPreview = commandPreview
        self.commandDigest = commandDigest
        self.requiresFullReview = requiresFullReview
        self.choices = choices
        self.observedAt = observedAt
    }
}

public struct WatchSnapshot: Hashable, Codable, Sendable {
    public static let schemaVersion = 2

    public let schemaVersion: Int
    public let flavor: WatchAppFlavor
    /// Monotonic per phone install; lets the Watch drop out-of-order contexts.
    public let generation: Int
    /// When the phone built this snapshot.
    public let builtAt: Date
    /// False when the phone app is locked or App Lock hides content; the
    /// Watch must then show no names or commands.
    public let contentVisible: Bool
    /// True when this snapshot is fixture/mock data, never live state.
    public let isFixture: Bool
    public let gateways: [WatchGateway]
    public let attention: [WatchAttention]
    public let approvals: [WatchApproval]
    /// Set when the Watch pinned a conversation and the phone checked its FULL
    /// roster and found no such conversation: genuinely removed, as opposed to
    /// merely beyond the snapshot cap.
    public let removedPin: WatchConversationPin?

    public init(
        flavor: WatchAppFlavor, generation: Int, builtAt: Date, contentVisible: Bool,
        isFixture: Bool = false, gateways: [WatchGateway], attention: [WatchAttention],
        approvals: [WatchApproval], removedPin: WatchConversationPin? = nil
    ) {
        self.removedPin = removedPin
        self.schemaVersion = Self.schemaVersion
        self.flavor = flavor
        self.generation = generation
        self.builtAt = builtAt
        self.contentVisible = contentVisible
        self.isFixture = isFixture
        self.gateways = gateways
        self.attention = attention
        self.approvals = approvals
    }

    /// A snapshot that carries only "locked" so no names leak to the wrist.
    public static func hidden(flavor: WatchAppFlavor, generation: Int, builtAt: Date) -> WatchSnapshot {
        WatchSnapshot(flavor: flavor, generation: generation, builtAt: builtAt,
                      contentVisible: false, gateways: [], attention: [], approvals: [])
    }
}
