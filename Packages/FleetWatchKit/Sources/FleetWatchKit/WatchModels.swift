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

public struct WatchBot: Hashable, Codable, Sendable, Identifiable {
    public let ref: WatchBotRef
    public let displayName: String
    public let activity: String
    public let conversations: [WatchConversation]

    public var id: String { "\(ref.gatewayID)#\(ref.profileSlug)" }

    public init(ref: WatchBotRef, displayName: String, activity: String, conversations: [WatchConversation]) {
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
    /// When the phone last observed this gateway's state (nil = never).
    public let observedAt: Date?
    public let bots: [WatchBot]
    public let running: [WatchRunningWork]

    public init(
        id: String, displayName: String, status: WatchGatewayStatus, coverage: WatchCoverage,
        observedAt: Date?, bots: [WatchBot], running: [WatchRunningWork]
    ) {
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
    public let observedAt: Date

    public var id: String { WatchApproval.key(gatewayID: gatewayID, sessionID: sessionID, requestID: requestID) }

    public static func key(gatewayID: String, sessionID: String, requestID: String) -> String {
        "\(gatewayID)|\(sessionID)|\(requestID)"
    }

    public init(
        gatewayID: String, gatewayName: String, profileSlug: String?, botName: String?,
        sessionID: String, sessionLabel: String, requestID: String,
        commandPreview: String, commandDigest: String, requiresFullReview: Bool,
        choices: [String], observedAt: Date
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
    public static let schemaVersion = 1

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

    public init(
        flavor: WatchAppFlavor, generation: Int, builtAt: Date, contentVisible: Bool,
        isFixture: Bool = false, gateways: [WatchGateway], attention: [WatchAttention],
        approvals: [WatchApproval]
    ) {
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
