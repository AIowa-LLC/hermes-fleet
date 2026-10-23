import Foundation

// Build 99 (B3) — pure policy for inbox notifications. No platform imports.
//
// Rules this file enforces (tested in InboxNotificationPolicyTests):
// - Only PENDING items notify, and each item id notifies at most once. A
//   re-delivery of the same item (same `InboxItemID`) never posts again.
// - Items that are already pending when the inbox first loads (restored from
//   history) are a baseline: they never notify, they were not new.
// - Nothing posts while notifications are off, not authorized, or while the
//   user is already looking at the item (the Inbox, or that session, in the
//   active app). The item is still marked handled so enabling later does not
//   replay an old request.
// - A resolved item (approved, denied, answered, expired, cancelled, failed)
//   withdraws its delivered notification.
// - Lock-screen privacy: the default text names the agent and the kind of
//   request and carries no command text. Request details (a truncated command)
//   need the explicit opt-in AND App Lock off. Secret and sudo prompts never
//   show a value, a command, or an env var name.

// MARK: - Catalog (categories, actions, identifiers)

/// One notification action button.
public struct FleetNotificationAction: Equatable, Sendable {
    public let id: String
    public let title: String
    public let isDestructive: Bool
    /// True when the action needs the app in the foreground.
    public let opensApp: Bool

    public init(id: String, title: String, isDestructive: Bool, opensApp: Bool) {
        self.id = id
        self.title = title
        self.isDestructive = isDestructive
        self.opensApp = opensApp
    }
}

/// One notification category: the actions a notification of that kind offers,
/// plus the text the system shows on a locked screen when previews are hidden.
public struct FleetNotificationCategory: Equatable, Sendable {
    public let id: String
    public let actions: [FleetNotificationAction]
    public let hiddenPreviewsBodyPlaceholder: String

    public init(id: String, actions: [FleetNotificationAction], hiddenPreviewsBodyPlaceholder: String) {
        self.id = id
        self.actions = actions
        self.hiddenPreviewsBodyPlaceholder = hiddenPreviewsBodyPlaceholder
    }
}

/// Identifiers and category definitions for inbox notifications.
///
/// Approve is deliberately NOT an action. Approving needs the full review of a
/// long command and the biometric presence gate, both of which must happen in
/// the app, so a notification can only Deny (ungated, runs in the background)
/// or Review (opens the item in the app).
public enum InboxNotificationCatalog {
    /// `userInfo` key carrying the `InboxItemID` raw value.
    public static let itemIDKey = "fleet.inbox.itemID"

    public static let approvalCategoryID = "fleet.inbox.approval"
    public static let requestCategoryID = "fleet.inbox.request"

    public static let denyActionID = "fleet.inbox.action.deny"
    public static let reviewActionID = "fleet.inbox.action.review"

    static let hiddenPlaceholder = "Hermes Fleet needs your attention."

    public static let categories: [FleetNotificationCategory] = [
        FleetNotificationCategory(
            id: approvalCategoryID,
            actions: [
                FleetNotificationAction(id: denyActionID, title: "Deny", isDestructive: true, opensApp: false),
                FleetNotificationAction(id: reviewActionID, title: "Review", isDestructive: false, opensApp: true),
            ],
            hiddenPreviewsBodyPlaceholder: hiddenPlaceholder),
        // Questions, sudo and secret prompts: tapping the notification opens the
        // item. There are no actions, because answering needs the typed value.
        FleetNotificationCategory(
            id: requestCategoryID,
            actions: [],
            hiddenPreviewsBodyPlaceholder: hiddenPlaceholder),
    ]

    public static func categoryID(for kind: InboxItemKind) -> String {
        kind == .approval ? approvalCategoryID : requestCategoryID
    }

    /// Delivery id for one item: stable, so a withdrawal is exact.
    public static func notificationID(for itemID: InboxItemID) -> String {
        "fleet.inbox.\(itemID.rawValue)"
    }

    /// Replacement for a Deny that could not be sent from the background (the
    /// gateway transport was closed, or the app was suspended). It reuses the
    /// item's delivery id, so it REPLACES the delivered request notification.
    /// It has no actions: tapping it opens the item in the app, where the
    /// answer goes through the normal path.
    public static func denyFailedNotification(for item: InboxItem) -> FleetLocalNotification {
        FleetLocalNotification(
            id: notificationID(for: item.id),
            threadID: threadID(for: item.agent.gatewayID),
            categoryID: requestCategoryID,
            title: "Couldn't deny from here",
            body: "Open Hermes Fleet to answer.",
            userInfo: [itemIDKey: item.id.rawValue])
    }

    /// Thread (grouping) id: one thread per gateway.
    public static func threadID(for gatewayID: GatewayID) -> String {
        "fleet.inbox.\(gatewayID.rawValue)"
    }
}

// MARK: - Deep link

/// The `<scheme>://inbox?item=<id>` URL that opens one inbox item. The UI
/// worker's Inbox navigation consumes it; the notification Review action and a
/// tap both build it here. The scheme is the app's conversation URL scheme
/// (`hermes-fleet`, or `hermes-fleet-dev` in Fleet Dev).
public enum FleetInboxDeepLink {
    public static let host = "inbox"
    public static let itemQueryName = "item"

    public static func url(scheme: String, itemID: InboxItemID) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: itemQueryName, value: itemID.rawValue)]
        return components.url
    }

    /// The item id a URL names, or nil for any other URL, scheme, host, or
    /// shape. Exactly one `item` query value is accepted.
    public static func itemID(from url: URL, scheme: String) -> InboxItemID? {
        guard url.scheme == scheme, url.host == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == itemQueryName,
              let raw = items[0].value, isWellFormed(raw) else { return nil }
        return InboxItemID(rawValue: raw)
    }

    /// `gateway#session#request`, three non-empty parts, no whitespace.
    static func isWellFormed(_ raw: String) -> Bool {
        guard raw.count <= 512 else { return false }
        let parts = raw.split(separator: "#", omittingEmptySubsequences: false)
        return parts.count == 3
            && parts.allSatisfy { !$0.isEmpty && !$0.contains(where: \.isWhitespace) }
    }
}

// MARK: - Content

/// Lock-screen-safe text for one inbox item.
public enum InboxNotificationContent {
    static let maxNameLength = 40
    static let maxDetailLength = 120

    public static func make(
        for item: InboxItem,
        appLockEnabled: Bool,
        showsRequestDetails: Bool
    ) -> (title: String, body: String) {
        if appLockEnabled {
            // App Lock on: no agent name, no details, for any kind.
            switch item.kind {
            case .approval: return ("Approval needed", "Open Hermes Fleet to continue.")
            case .question, .sudo, .secret: return ("Input needed", "Open Hermes Fleet to continue.")
            }
        }
        let name = agentName(item.agent)
        switch item.kind {
        case .approval:
            let generic = "Open Hermes Fleet to review."
            guard showsRequestDetails, let command = detail(item.context.command) else {
                return ("\(name) needs your approval", generic)
            }
            return ("\(name) needs your approval", command)
        case .question:
            return ("Question from \(name)", "Open Hermes Fleet to answer.")
        case .sudo, .secret:
            // Never the command, env var name, prompt text, or any value.
            return ("\(name) needs your input", "Open Hermes Fleet to respond.")
        }
    }

    /// Display name of the agent. Gateway- or profile-supplied, so sanitized.
    static func agentName(_ identity: InboxAgentIdentity) -> String {
        let raw = identity.profileName ?? identity.gatewayLabel
        if raw == ApprovalOrigin.unknownValue { return "An agent" }
        return sanitized(raw, limit: maxNameLength) ?? "An agent"
    }

    static func detail(_ command: String?) -> String? {
        sanitized(command, limit: maxDetailLength)
    }

    /// Strip control characters, collapse whitespace, cap the length with an
    /// ellipsis. Nil when nothing printable is left.
    static func sanitized(_ text: String?, limit: Int) -> String? {
        let scalars = (text ?? "").unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
        let collapsed = scalars.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}

// MARK: - Policy

/// Ambient conditions at the moment the inbox changes.
public struct InboxNotificationConditions: Equatable, Sendable {
    /// The user opted in (Settings).
    public var isEnabled: Bool
    public var authorization: FleetNotificationAuthorization
    public var isAppActive: Bool
    /// The Inbox list is on screen.
    public var isInboxVisible: Bool
    /// The session whose conversation is on screen, if any.
    public var viewedSessionID: String?
    public var appLockEnabled: Bool
    /// The opt-in "Show request details" setting.
    public var showsRequestDetails: Bool

    public init(
        isEnabled: Bool,
        authorization: FleetNotificationAuthorization,
        isAppActive: Bool,
        isInboxVisible: Bool,
        viewedSessionID: String?,
        appLockEnabled: Bool,
        showsRequestDetails: Bool
    ) {
        self.isEnabled = isEnabled
        self.authorization = authorization
        self.isAppActive = isAppActive
        self.isInboxVisible = isInboxVisible
        self.viewedSessionID = viewedSessionID
        self.appLockEnabled = appLockEnabled
        self.showsRequestDetails = showsRequestDetails
    }
}

/// Decides which inbox items post, and which delivered notifications to
/// withdraw. A value type with no platform dependencies: the app-level
/// coordinator owns one and feeds it every snapshot.
public struct InboxNotificationTracker: Equatable, Sendable {
    /// Items this tracker has decided about (posted, suppressed, or baseline).
    /// Pruned to pending items on each plan, which is safe because a terminal
    /// item never returns to pending.
    public private(set) var handled: Set<InboxItemID> = []
    /// Items for which a notification was requested and not yet withdrawn.
    public private(set) var posted: Set<InboxItemID> = []

    public init() {}

    /// Mark what is already pending as seen. Used for the first snapshot after
    /// launch, so restored items never notify.
    public mutating func baseline(_ items: [InboxItem]) {
        handled = Set(items.filter { $0.status == .pending }.map(\.id))
    }

    /// Notifications to post for this snapshot, in snapshot order.
    public mutating func plan(_ items: [InboxItem], conditions: InboxNotificationConditions) -> [FleetLocalNotification] {
        let pending = items.filter { $0.status == .pending }
        handled.formIntersection(Set(pending.map(\.id)))
        var output: [FleetLocalNotification] = []
        for item in pending where !handled.contains(item.id) {
            handled.insert(item.id)
            guard Self.shouldPost(item, conditions) else { continue }
            posted.insert(item.id)
            output.append(Self.notification(for: item, conditions: conditions))
        }
        return output
    }

    /// The item reached a terminal status. Returns the delivery id to withdraw.
    public mutating func resolved(_ itemID: InboxItemID) -> String {
        handled.remove(itemID)
        posted.remove(itemID)
        return InboxNotificationCatalog.notificationID(for: itemID)
    }

    /// The user turned notifications off: every delivered id to withdraw.
    public mutating func withdrawAll() -> [String] {
        let ids = posted.map(InboxNotificationCatalog.notificationID(for:)).sorted()
        posted.removeAll()
        return ids
    }

    /// The Inbox came on screen: the user has seen the posted requests, so
    /// withdraw their notifications. The items stay handled and pending.
    public mutating func acknowledge() -> [String] {
        withdrawAll()
    }

    static func shouldPost(_ item: InboxItem, _ conditions: InboxNotificationConditions) -> Bool {
        guard conditions.isEnabled, conditions.authorization == .authorized else { return false }
        let looking = conditions.isInboxVisible || conditions.viewedSessionID == item.agent.sessionID
        return !(conditions.isAppActive && looking)
    }

    static func notification(for item: InboxItem, conditions: InboxNotificationConditions) -> FleetLocalNotification {
        let text = InboxNotificationContent.make(
            for: item,
            appLockEnabled: conditions.appLockEnabled,
            showsRequestDetails: conditions.showsRequestDetails)
        return FleetLocalNotification(
            id: InboxNotificationCatalog.notificationID(for: item.id),
            threadID: InboxNotificationCatalog.threadID(for: item.agent.gatewayID),
            categoryID: InboxNotificationCatalog.categoryID(for: item.kind),
            title: text.title,
            body: text.body,
            userInfo: [InboxNotificationCatalog.itemIDKey: item.id.rawValue])
    }
}
