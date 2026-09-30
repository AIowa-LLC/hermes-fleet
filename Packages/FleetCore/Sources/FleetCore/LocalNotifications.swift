import Foundation

// R8 (#95) — interim local notifications.
//
// Everything here is best-effort and local-only: a notification is a HINT that
// something needs attention, never authoritative state (the conversation
// re-reads `approval.pending` when opened), and it is never presented as
// reliable push (that is the APNs relay, #89). FleetCore owns only the
// vocabulary, the pure decision rules and the two platform seams; the
// `UNUserNotificationCenter` / `UIApplication` implementations live in the
// app target.

// MARK: - Seams

/// Notification permission as the UI needs to see it.
public enum FleetNotificationAuthorization: Sendable, Equatable {
    /// The system has not been asked yet (the only state in which asking can
    /// show the system prompt).
    case notDetermined
    /// The user declined (or turned notifications off in system Settings).
    case denied
    /// Alerts may be delivered (includes provisional delivery).
    case authorized
    /// This build/runtime cannot post notifications (no notifier wired).
    case unavailable
}

/// Where tapping a notification lands: the owning conversation, expressed with
/// the same source-qualified identity the `hermes-fleet://conversation` deep
/// link carries.
public struct FleetNotificationTarget: Sendable, Equatable {
    public let route: Route
    public let sessionID: String
    public let canonical: Bool

    public init(route: Route, sessionID: String, canonical: Bool) {
        self.route = route
        self.sessionID = sessionID
        self.canonical = canonical
    }
}

/// One local notification request. `id` is the delivery identifier: posting
/// the same id again REPLACES the delivered notification (this is how a
/// per-session completion coalesces), and withdrawing the id removes it.
public struct FleetLocalNotification: Sendable, Equatable {
    public let id: String
    /// Notification grouping (one thread per gateway/bot).
    public let threadID: String
    public let title: String
    public let body: String
    public let target: FleetNotificationTarget?

    public init(id: String, threadID: String, title: String, body: String, target: FleetNotificationTarget?) {
        self.id = id
        self.threadID = threadID
        self.title = title
        self.body = body
        self.target = target
    }
}

/// The local notification seam. `UNUserNotificationCenter` implements it in
/// `HermesFleetApp`; tests use a stub. Implementations must never log
/// notification content.
public protocol FleetLocalNotifier: Sendable {
    /// Current permission; never prompts.
    func authorizationStatus() async -> FleetNotificationAuthorization
    /// Ask the system for permission. Only call from an explicit user action
    /// (Settings toggle or the explain-first card) — never at launch.
    func requestAuthorization() async -> Bool
    func post(_ notification: FleetLocalNotification) async
    /// Remove delivered (and pending) notifications by delivery id.
    func withdraw(ids: [String]) async
    /// Remove every delivered notification in a thread.
    func withdraw(threadID: String) async
}

/// Fail-closed default: nothing can be posted.
public struct UnavailableLocalNotifier: FleetLocalNotifier {
    public init() {}
    public func authorizationStatus() async -> FleetNotificationAuthorization { .unavailable }
    public func requestAuthorization() async -> Bool { false }
    public func post(_ notification: FleetLocalNotification) async {}
    public func withdraw(ids: [String]) async {}
    public func withdraw(threadID: String) async {}
}

// MARK: - Policy

/// What about a conversation event deserves the user's attention.
public enum ConversationAttentionKind: Sendable, Equatable {
    /// A command approval is waiting. `aliases` are the other ids the same
    /// request is known by (the JSON-RPC `srq-` id and the legacy request id),
    /// so a `request.cancel` or an answer can withdraw it by either.
    case approval(requestID: String, aliases: [String])
    /// A clarify question is waiting.
    case clarify(requestID: String)
    /// A sudo password / secret entry is waiting.
    case secretInput(requestID: String)
    /// A turn started from this device finished.
    case turnFinished
    /// A turn stopped with an error.
    case turnFailed

    /// Request-backed kinds return their primary id.
    public var requestID: String? {
        switch self {
        case .approval(let id, _), .clarify(let id), .secretInput(let id): return id
        case .turnFinished, .turnFailed: return nil
        }
    }

    /// Every id this request answers to (primary first).
    public var requestIDs: [String] {
        switch self {
        case .approval(let id, let aliases): return [id] + aliases.filter { $0 != id }
        case .clarify(let id), .secretInput(let id): return [id]
        case .turnFinished, .turnFailed: return []
        }
    }

    /// True for kinds that block the agent on the user.
    public var isBlockingRequest: Bool { requestID != nil }
}

/// Pure rules for when a conversation event becomes a notification, and what
/// the notification says. No platform dependencies.
public enum LocalNotificationPolicy {

    /// Map one conversation event to an attention kind, or nil when the event
    /// never notifies (deltas, tool chatter, title updates, ...).
    ///
    /// - `turnStartedHere`: whether the turn this event belongs to was started
    ///   from this device. A completion of a turn someone else started is not
    ///   news to this device.
    /// - A request re-delivered through `open_requests` (`replayed`) never
    ///   notifies: it is old, and the gateway re-surfaces it on resume.
    public static func attention(for event: ConversationEvent, turnStartedHere: Bool) -> ConversationAttentionKind? {
        switch event {
        case .approvalRequested(_, let requestID, _, _, _, _):
            return .approval(requestID: requestID, aliases: [])
        case .serverRequest(let request):
            guard !request.replayed else { return nil }
            switch request.kind {
            case .approval(let approval):
                // The legacy request id is the primary key so the legacy
                // event and the server request for one approval coalesce.
                return .approval(requestID: approval.requestID, aliases: [request.id])
            case .clarify:
                return .clarify(requestID: request.id)
            case .sudo, .secret:
                return .secretInput(requestID: request.id)
            }
        case .messageComplete(_, _, let status, let error, _):
            guard turnStartedHere else { return nil }
            return (status == "error" || error != nil) ? .turnFailed : .turnFinished
        case .error:
            return .turnFailed
        default:
            return nil
        }
    }

    /// The request id a withdrawal event names, if the event is one.
    public static func withdrawnRequestID(for event: ConversationEvent) -> String? {
        if case .requestCancelled(_, let requestID, _, _, _) = event { return requestID }
        return nil
    }

    /// Ambient conditions at the moment an event arrives.
    public struct Conditions: Sendable, Equatable {
        public var isEnabled: Bool
        public var authorization: FleetNotificationAuthorization
        public var isAppActive: Bool
        public var isConversationVisible: Bool

        public init(isEnabled: Bool, authorization: FleetNotificationAuthorization,
                    isAppActive: Bool, isConversationVisible: Bool) {
            self.isEnabled = isEnabled
            self.authorization = authorization
            self.isAppActive = isAppActive
            self.isConversationVisible = isConversationVisible
        }
    }

    /// Whether to post: the user opted in, the system allows it, and the user
    /// is not already looking at this conversation in the active app.
    public static func shouldPost(_ conditions: Conditions) -> Bool {
        guard conditions.isEnabled, conditions.authorization == .authorized else { return false }
        return !(conditions.isAppActive && conditions.isConversationVisible)
    }

    // MARK: Content

    /// Maximum bot-name length echoed into a notification title.
    static let maxBotNameLength = 40

    /// Generic, content-free text. Never includes commands, prompts, secrets,
    /// sudo text, question text or message bodies. With App Lock on, the bot
    /// name is withheld too.
    public static func content(
        for kind: ConversationAttentionKind,
        botName: String?,
        appLockEnabled: Bool
    ) -> (title: String, body: String) {
        if appLockEnabled {
            switch kind {
            case .approval: return ("Approval needed", "Open Hermes Fleet to continue.")
            case .clarify, .secretInput: return ("Input needed", "Open Hermes Fleet to continue.")
            case .turnFinished: return ("Turn finished", "Open Hermes Fleet to continue.")
            case .turnFailed: return ("Turn stopped", "Open Hermes Fleet to continue.")
            }
        }
        let name = sanitizedBotName(botName)
        switch kind {
        case .approval:
            return ("\(name) needs approval", "Open Hermes Fleet to review. Details stay in the app.")
        case .clarify:
            return ("Question from \(name)", "Open Hermes Fleet to answer.")
        case .secretInput:
            return ("\(name) needs your input", "Open Hermes Fleet to respond. Details stay in the app.")
        case .turnFinished:
            return ("\(name) finished", "Open Hermes Fleet to see the reply.")
        case .turnFailed:
            return ("\(name) stopped", "Open Hermes Fleet for details.")
        }
    }

    /// Bot display names are user/gateway supplied: strip control characters,
    /// collapse whitespace and cap the length. Falls back to a neutral word.
    public static func sanitizedBotName(_ name: String?) -> String {
        let filtered = (name ?? "").unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
        let collapsed = filtered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return "Your bot" }
        if collapsed.count <= maxBotNameLength { return collapsed }
        return String(collapsed.prefix(maxBotNameLength - 1)) + "…"
    }

    // MARK: Identifiers

    /// Delivery id for a request-backed notification: stable per request so
    /// withdrawal is exact and a re-delivery coalesces.
    public static func requestNotificationID(conversationKey: String, requestID: String) -> String {
        "fleet.request.\(conversationKey).\(requestID)"
    }

    /// Delivery id for a turn outcome: one per conversation, so a newer
    /// outcome replaces an older one (coalescing).
    public static func turnNotificationID(conversationKey: String) -> String {
        "fleet.turn.\(conversationKey)"
    }
}

// MARK: - Background grace window

/// Seam over `UIApplication.beginBackgroundTask` so the grace window is
/// testable. `beginBackgroundTask` ONLY: no background modes are involved.
@MainActor
public protocol FleetBackgroundTaskProviding: AnyObject {
    /// Begin a short background task. `expiration` runs when the OS ends the
    /// grant. Returns nil when the OS refuses (no grace available).
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int?
    /// End a task previously returned by `begin`. Must be called exactly once
    /// per granted task.
    func end(_ identifier: Int)
}

/// Keeps already-open conversation transports alive for the short window iOS
/// grants after backgrounding (about 30 s), then stops promptly.
///
/// Best-effort by design: this is not a background mode and the app may still
/// be suspended at any time. On expiry the `suspend` hook runs (production:
/// `AppEnvironment.disconnectAll()`, which leaves connection INTENT untouched
/// so the normal foreground restore reconnects), bounded by `suspendBudget`,
/// and the OS task is then ended. Returning to the foreground ends the task
/// without touching the connections.
@MainActor
public final class BackgroundGraceWindow {
    public enum State: Equatable, Sendable {
        case idle
        case active
        /// Expired and intentionally suspended.
        case suspended
    }

    public private(set) var state: State = .idle
    /// The live OS task identifier, nil whenever no task is held.
    public private(set) var taskIdentifier: Int?

    private let provider: any FleetBackgroundTaskProviding
    private let hasLiveConnections: @MainActor () -> Bool
    private let suspend: @MainActor () async -> Void
    private let suspendBudget: Duration
    private var generation = 0

    public init(
        provider: any FleetBackgroundTaskProviding,
        suspendBudget: Duration = .seconds(2),
        hasLiveConnections: @escaping @MainActor () -> Bool,
        suspend: @escaping @MainActor () async -> Void
    ) {
        self.provider = provider
        self.suspendBudget = suspendBudget
        self.hasLiveConnections = hasLiveConnections
        self.suspend = suspend
    }

    /// `scenePhase == .background`. Idempotent: a second call while a task is
    /// held never begins another (no leaked identifiers).
    public func enterBackground() {
        guard taskIdentifier == nil else { return }
        guard hasLiveConnections() else { state = .idle; return }
        generation += 1
        let token = generation
        let identifier = provider.begin(name: "fleet.grace-window") { [weak self] in
            self?.handleExpiration(token: token)
        }
        guard let identifier else { state = .idle; return }
        taskIdentifier = identifier
        state = .active
    }

    /// Back in the foreground (any non-background phase): release the task.
    /// Connections are left exactly as they are.
    public func enterForeground() {
        generation += 1
        endTaskIfHeld()
        state = .idle
    }

    private func handleExpiration(token: Int) {
        // A stale expiry (the task already ended by foreground) does nothing.
        guard token == generation, taskIdentifier != nil else { return }
        state = .suspended
        let budget = suspendBudget
        // Whichever finishes first (the suspend hook, or the time budget)
        // ends the OS task; the other is a no-op. The OS allows only a moment
        // after expiry, so a hung hook must never hold the task open.
        let suspend = self.suspend
        Task { @MainActor [weak self] in
            await suspend()
            self?.finishExpiration(token: token)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: budget)
            self?.finishExpiration(token: token)
        }
    }

    private func finishExpiration(token: Int) {
        guard generation == token else { return }
        endTaskIfHeld()
    }

    private func endTaskIfHeld() {
        guard let identifier = taskIdentifier else { return }
        taskIdentifier = nil
        provider.end(identifier)
    }
}
