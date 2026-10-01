import Foundation
import Observation
import FleetCore

/// Identity of the conversation an event came from, as the notification layer
/// needs it. Built per event by the composition (`AppEnvironment`) so the
/// session id and bot name are current.
public struct ConversationNotificationContext: Sendable, Equatable {
    /// Stable per open conversation screen (its view model), used to know
    /// whether THIS conversation is the one on screen.
    public let token: UUID
    public let route: Route
    /// Durable session id for the deep link; nil until the session resolves.
    public let sessionID: String?
    public let canonical: Bool
    public let botName: String?

    public init(token: UUID, route: Route, sessionID: String?, canonical: Bool, botName: String?) {
        self.token = token
        self.route = route
        self.sessionID = sessionID
        self.canonical = canonical
        self.botName = botName
    }
}

/// R8 (#95) — turns attention-worthy conversation events into interim LOCAL
/// notifications, and withdraws them when the item is resolved.
///
/// Best-effort and local-only: it only ever sees events from conversation
/// transports that are open and subscribed in this process, it is never
/// presented as reliable push (APNs is #89), and a delivered notification is a
/// hint — the conversation re-reads `approval.pending` when opened.
///
/// Privacy: text is generic (`LocalNotificationPolicy.content`): never the
/// command, prompt, question, secret or sudo text; with App Lock on the bot
/// name is withheld as well. Nothing here logs content.
///
/// Permission is never requested at launch. It is requested only from the
/// Settings toggle or from the explain-first card the conversation shows at the
/// first approval-worthy moment (`isOfferPending`).
@MainActor
@Observable
public final class LocalNotificationCoordinator {

    // MARK: Observable state

    /// The user's opt-in. Default off: notifying is an explicit choice.
    public private(set) var isEnabled: Bool
    /// Last known system permission (refreshed, never prompting).
    public private(set) var authorization: FleetNotificationAuthorization = .notDetermined
    /// True while the explain-first card should show: an approval-worthy
    /// request is waiting, the user has not opted in, the system has not been
    /// asked, and the user has not already answered the card.
    public private(set) var isOfferPending = false

    /// True when the toggle can ever work on this build.
    public var isAvailable: Bool { authorization != .unavailable }
    /// What the toggle shows: opted in AND the system still allows delivery.
    public var isDeliveryActive: Bool { isEnabled && authorization == .authorized }

    // MARK: Collaborators

    @ObservationIgnored private let notifier: any FleetLocalNotifier
    @ObservationIgnored private let defaults: UserDefaults
    /// Whether App Lock is on. Fail closed: until the composition attaches the
    /// lock controller, notification text is redacted.
    @ObservationIgnored public var appLockEnabled: @MainActor () -> Bool = { true }

    // MARK: Internal state

    @ObservationIgnored private var isAppActive = true
    /// Open conversation screens currently on screen (by context token).
    @ObservationIgnored private var visibleTokens: Set<UUID> = []
    /// Highest live `seq` seen per gateway+session: an event at or below it is
    /// a replay/duplicate and never notifies.
    @ObservationIgnored private var watermarks: [String: Int] = [:]
    /// Any id a request is known by -> the delivery id posted for it. Doubles
    /// as the duplicate guard for a request seen through two paths.
    @ObservationIgnored private var requestIndex: [String: String] = [:]
    @ObservationIgnored private var requestIndexOrder: [String] = []
    /// Delivery ids posted per conversation screen, for clear-on-view.
    @ObservationIgnored private var deliveredByToken: [UUID: Set<String>] = [:]
    /// Conversations that already posted an outcome for the current turn.
    @ObservationIgnored private var turnOutcomePosted: Set<String> = []
    /// Delivery ids already withdrawn (idempotence guard).
    @ObservationIgnored private var withdrawnDeliveryIDs: Set<String> = []
    /// Delivery ids of the requests the pending offer was raised for.
    @ObservationIgnored private var offerDeliveryIDs: Set<String> = []
    /// Serializes notifier calls so a post never overtakes its withdrawal.
    @ObservationIgnored private var chain: Task<Void, Never>?

    public static let enabledKey = "fleet.localNotifications.enabled"
    static let offerAnsweredKey = "fleet.localNotifications.offerAnswered"
    private static let maxTrackedRequests = 256

    public init(notifier: any FleetLocalNotifier, defaults: UserDefaults = .standard) {
        self.notifier = notifier
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    // MARK: Permission

    /// Re-read the system permission. Never prompts; safe at launch.
    public func refreshAuthorization() async {
        authorization = await notifier.authorizationStatus()
    }

    /// The Settings toggle (and the explain-first card's accept). Turning ON
    /// asks the system if it has never been asked; it stays off when denied.
    /// Returns the resulting opt-in state.
    @discardableResult
    public func setEnabled(_ enabled: Bool) async -> Bool {
        if !enabled {
            setStoredEnabled(false)
            await withdrawAll()
            return false
        }
        var status = await notifier.authorizationStatus()
        if status == .notDetermined {
            _ = await notifier.requestAuthorization()
            status = await notifier.authorizationStatus()
        }
        authorization = status
        setStoredEnabled(status == .authorized)
        if status == .authorized { isOfferPending = false }
        return isEnabled
    }

    /// Explain-first card: "Turn on".
    public func acceptOffer() async {
        defaults.set(true, forKey: Self.offerAnsweredKey)
        isOfferPending = false
        offerDeliveryIDs.removeAll()
        await setEnabled(true)
    }

    /// Explain-first card: "Not now". Not asked again; Settings remains.
    public func declineOffer() {
        defaults.set(true, forKey: Self.offerAnsweredKey)
        isOfferPending = false
        offerDeliveryIDs.removeAll()
    }

    private func setStoredEnabled(_ value: Bool) {
        isEnabled = value
        defaults.set(value, forKey: Self.enabledKey)
    }

    // MARK: App / screen state

    /// `scenePhase == .active`. Returning clears what the visible conversation
    /// already shows.
    public func setAppActive(_ active: Bool) {
        let becameActive = active && !isAppActive
        isAppActive = active
        if becameActive {
            enqueue { [self] in
                await refreshAuthorization()
                await withdrawDeliveredForVisibleConversations()
            }
        }
    }

    public func conversationDidAppear(token: UUID) {
        visibleTokens.insert(token)
        enqueue { [self] in await withdrawDelivered(for: token) }
    }

    public func conversationDidDisappear(token: UUID) {
        visibleTokens.remove(token)
    }

    // MARK: Event intake

    /// One applied conversation event. The caller has already dropped
    /// duplicates by its own cursor; the coordinator keeps an independent
    /// per-session watermark so a replayed event never notifies even across
    /// view-model instances.
    ///
    /// - `turnStartedHere`: the turn was started from this device.
    /// - `isReplay`: the event is being re-applied from a replay/gap recovery.
    public func observe(
        _ event: ConversationEvent,
        context: ConversationNotificationContext,
        turnStartedHere: Bool,
        isReplay: Bool
    ) {
        // A withdrawal is idempotent and always honored, even when replayed.
        if let cancelled = LocalNotificationPolicy.withdrawnRequestID(for: event) {
            requestsResolved(ids: [cancelled])
        }

        // Watermark gate.
        if let seq = event.seq, let sid = event.sessionID {
            let key = "\(context.route.gatewayID.rawValue)|\(sid)"
            if let seen = watermarks[key], seq <= seen { return }
            watermarks[key] = seq
        }

        guard let conversationKey = Self.conversationKey(context) else { return }
        if case .messageStart = event { turnOutcomePosted.remove(conversationKey) }
        guard !isReplay,
              let kind = LocalNotificationPolicy.attention(for: event, turnStartedHere: turnStartedHere)
        else { return }

        // A request seen before (legacy event + server request, re-delivery)
        // never produces a second notification.
        if kind.isBlockingRequest, kind.requestIDs.contains(where: { requestIndex[$0] != nil }) { return }
        // One outcome notification per turn.
        if !kind.isBlockingRequest, turnOutcomePosted.contains(conversationKey) { return }

        let deliveryID: String
        if let requestID = kind.requestID {
            deliveryID = LocalNotificationPolicy.requestNotificationID(
                conversationKey: conversationKey, requestID: requestID)
            track(requestIDs: kind.requestIDs, deliveryID: deliveryID)
            considerOffer(deliveryID: deliveryID)
        } else {
            deliveryID = LocalNotificationPolicy.turnNotificationID(conversationKey: conversationKey)
        }

        let conditions = LocalNotificationPolicy.Conditions(
            isEnabled: isEnabled,
            authorization: authorization,
            isAppActive: isAppActive,
            isConversationVisible: visibleTokens.contains(context.token))
        guard LocalNotificationPolicy.shouldPost(conditions) else { return }

        if !kind.isBlockingRequest { turnOutcomePosted.insert(conversationKey) }
        deliveredByToken[context.token, default: []].insert(deliveryID)

        let text = LocalNotificationPolicy.content(
            for: kind, botName: context.botName, appLockEnabled: appLockEnabled())
        let target = context.sessionID.map {
            FleetNotificationTarget(route: context.route, sessionID: $0, canonical: context.canonical)
        }
        let notification = FleetLocalNotification(
            id: deliveryID,
            threadID: "fleet.thread.\(context.route.gatewayID.rawValue).\(context.route.profileSlug.rawValue)",
            title: text.title,
            body: text.body,
            target: target)
        enqueue { [notifier] in await notifier.post(notification) }
    }

    /// The answering surface resolved these request ids (answered here,
    /// `request.cancel`, answered elsewhere): remove the delivered
    /// notification and any pending explain-first offer for them.
    public func requestsResolved(ids: [String]) {
        var deliveryIDs: [String] = []
        for id in ids {
            guard let delivery = requestIndex[id] else { continue }
            offerDeliveryIDs.remove(delivery)
            // One withdrawal per notification, however many surfaces (the
            // answering view model, the `request.cancel` event) report it.
            if !deliveryIDs.contains(delivery), withdrawnDeliveryIDs.insert(delivery).inserted {
                deliveryIDs.append(delivery)
            }
        }
        if withdrawnDeliveryIDs.count > 2 * Self.maxTrackedRequests { withdrawnDeliveryIDs.removeAll() }
        if isOfferPending, offerDeliveryIDs.isEmpty { isOfferPending = false }
        guard !deliveryIDs.isEmpty else { return }
        for set in deliveredByToken.keys { deliveredByToken[set]?.subtract(deliveryIDs) }
        enqueue { [notifier] in await notifier.withdraw(ids: deliveryIDs) }
    }

    // MARK: Test support

    /// Awaits every queued notifier call (tests).
    public func waitForIdle() async {
        await chain?.value
    }

    // MARK: Helpers

    static func conversationKey(_ context: ConversationNotificationContext) -> String? {
        guard let sessionID = context.sessionID else { return nil }
        return "\(context.route.gatewayID.rawValue).\(context.route.profileSlug.rawValue).\(sessionID)"
    }

    private func track(requestIDs: [String], deliveryID: String) {
        for id in requestIDs where requestIndex[id] == nil {
            requestIndex[id] = deliveryID
            requestIndexOrder.append(id)
        }
        while requestIndexOrder.count > Self.maxTrackedRequests {
            requestIndex[requestIndexOrder.removeFirst()] = nil
        }
    }

    private func considerOffer(deliveryID: String) {
        guard isAppActive, !isEnabled, authorization == .notDetermined,
              !defaults.bool(forKey: Self.offerAnsweredKey) else { return }
        isOfferPending = true
        offerDeliveryIDs.insert(deliveryID)
    }

    private func withdrawDelivered(for token: UUID) async {
        guard let ids = deliveredByToken[token], !ids.isEmpty else { return }
        deliveredByToken[token] = []
        await notifier.withdraw(ids: Array(ids))
    }

    private func withdrawDeliveredForVisibleConversations() async {
        for token in visibleTokens { await withdrawDelivered(for: token) }
    }

    private func withdrawAll() async {
        let ids = deliveredByToken.values.flatMap { $0 }
        deliveredByToken.removeAll()
        turnOutcomePosted.removeAll()
        guard !ids.isEmpty else { return }
        await notifier.withdraw(ids: Array(ids))
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }
}
