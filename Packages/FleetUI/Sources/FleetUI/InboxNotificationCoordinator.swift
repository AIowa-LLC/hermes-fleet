import Foundation
import Observation
import FleetCore

/// The opt-in notification settings, persisted locally. Off until the user
/// turns notifications on in Settings; details are off until they opt in.
@MainActor
@Observable
public final class InboxNotificationSettingsStore {
    public static let enabledKey = "fleet.inbox.notifications.enabled"
    public static let detailsKey = "fleet.inbox.notifications.details"

    public private(set) var isEnabled: Bool
    public private(set) var showsRequestDetails: Bool

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.showsRequestDetails = defaults.bool(forKey: Self.detailsKey)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    public func setShowsRequestDetails(_ shows: Bool) {
        showsRequestDetails = shows
        defaults.set(shows, forKey: Self.detailsKey)
    }
}

/// Posts a local notification for each NEW pending inbox item and withdraws it
/// when the item resolves. App-level: it observes `InboxStore` and never a
/// conversation. The pure rules live in `InboxNotificationTracker` (FleetCore).
///
/// Presence (the Inbox on screen, a conversation on screen, the app active) is
/// reported by the composition root and the views through `setAppActive`,
/// `setInboxVisible` and `setViewedSession`. Those seams are the only way the
/// coordinator learns what the user is looking at.
@MainActor
public final class InboxNotificationCoordinator {
    public let settings: InboxNotificationSettingsStore

    private let inbox: InboxStore
    private let notifier: any FleetLocalNotifier
    private let urlScheme: String
    private let appLockEnabled: @MainActor () -> Bool

    /// Opens a URL in the app (the `<scheme>://inbox?item=` deep link). Set by
    /// the app target, which owns the UIKit call.
    public var openURL: @MainActor (URL) -> Void = { _ in }

    private var tracker = InboxNotificationTracker()
    private var isAppActive = false
    private var isInboxVisible = false
    private var viewedSessionID: String?
    private var snapshotTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?

    public init(
        inbox: InboxStore,
        notifier: any FleetLocalNotifier,
        settings: InboxNotificationSettingsStore,
        urlScheme: String,
        appLockEnabled: @escaping @MainActor () -> Bool = InboxNotificationCoordinator.persistedAppLockEnabled
    ) {
        self.inbox = inbox
        self.notifier = notifier
        self.settings = settings
        self.urlScheme = urlScheme
        self.appLockEnabled = appLockEnabled
    }

    /// Mirrors `AppLockController`'s persisted setting: on for a fresh install.
    public static func persistedAppLockEnabled() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AppLockController.defaultsKey) != nil else { return true }
        return defaults.bool(forKey: AppLockController.defaultsKey)
    }

    /// Whether App Lock is on. Request details are never shown while it is.
    public var isAppLockEnabled: Bool { appLockEnabled() }

    // MARK: Lifecycle

    /// Baseline the restored inbox and subscribe to changes. Returns once
    /// subscribed, so nothing that arrives afterwards can be mistaken for
    /// restored state. Idempotent. Call once from the composition root.
    public func start() async {
        guard snapshotTask == nil else { return }
        // Restored pending items are the baseline: they were not new, so they
        // never notify. Subscribing after the load keeps the snapshot current.
        await inbox.awaitLoaded()
        await notifier.registerCategories(InboxNotificationCatalog.categories)
        tracker.baseline(inbox.items)
        let resolutions = inbox.resolutions()
        let snapshots = inbox.updates()
        resolutionTask = Task { @MainActor [weak self] in
            for await resolution in resolutions {
                await self?.handle(resolution)
            }
        }
        snapshotTask = Task { @MainActor [weak self] in
            for await items in snapshots {
                await self?.observe(items)
            }
        }
    }

    private func observe(_ items: [InboxItem]) async {
        let authorization = await notifier.authorizationStatus()
        let conditions = InboxNotificationConditions(
            isEnabled: settings.isEnabled,
            authorization: authorization,
            isAppActive: isAppActive,
            isInboxVisible: isInboxVisible,
            viewedSessionID: viewedSessionID,
            appLockEnabled: isAppLockEnabled,
            showsRequestDetails: settings.showsRequestDetails)
        for notification in tracker.plan(items, conditions: conditions) {
            await notifier.post(notification)
        }
    }

    private func handle(_ resolution: InboxResolution) async {
        let id = tracker.resolved(resolution.itemID)
        await notifier.withdraw(ids: [id])
    }

    // MARK: Settings

    /// The user changed the notifications toggle. Turning ON asks the system
    /// for permission if it has not been asked; returns false (and stays off)
    /// when permission is refused or unavailable. Turning OFF withdraws every
    /// delivered inbox notification.
    @discardableResult
    public func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            settings.setEnabled(false)
            await notifier.withdraw(ids: tracker.withdrawAll())
            return true
        }
        if await notifier.authorizationStatus() == .notDetermined {
            _ = await notifier.requestAuthorization()
        }
        guard await notifier.authorizationStatus() == .authorized else {
            settings.setEnabled(false)
            return false
        }
        settings.setEnabled(true)
        return true
    }

    /// Current permission, for the Settings footer copy.
    public func authorizationStatus() async -> FleetNotificationAuthorization {
        await notifier.authorizationStatus()
    }

    // MARK: Presence

    public func setAppActive(_ active: Bool) {
        isAppActive = active
    }

    /// The Inbox list appeared or disappeared. Appearing acknowledges the
    /// delivered requests: their notifications are withdrawn, and the items
    /// stay pending in the Inbox.
    public func setInboxVisible(_ visible: Bool) async {
        isInboxVisible = visible
        guard visible else { return }
        await notifier.withdraw(ids: tracker.acknowledge())
    }

    /// The conversation on screen changed (nil when none).
    public func setViewedSession(_ sessionID: String?) {
        viewedSessionID = sessionID
    }

    // MARK: Responses

    /// Whether a notification should show its banner while the app is in the
    /// foreground. Suppressed when the user is already looking at the item.
    public func presentsInForeground(itemIDRaw: String) -> Bool {
        guard let item = inbox.items.first(where: { $0.id.rawValue == itemIDRaw }) else { return true }
        return !(isInboxVisible || viewedSessionID == item.agent.sessionID)
    }

    /// A notification action (or a tap, which the app maps to the Review
    /// action) for one item.
    ///
    /// - Deny: sent through `InboxStore.decide(_, .deny)`, which is ungated and
    ///   runs without opening the app. A failure leaves the item pending.
    /// - Review: opens `<scheme>://inbox?item=<id>` in the app.
    /// Approve is never reachable from a notification.
    public func handleResponse(actionID: String, itemIDRaw: String) async {
        let itemID = InboxItemID(rawValue: itemIDRaw)
        switch actionID {
        case InboxNotificationCatalog.denyActionID:
            do {
                _ = try await inbox.decide(itemID, .deny)
            } catch {
                // Typically the gateway transport is closed (the conversation
                // is not live, or the app was suspended), so nothing was sent.
                // Say so, and let a tap open the item. Only while still pending.
                await reportDenyFailed(itemID)
            }
        case InboxNotificationCatalog.reviewActionID:
            if let url = FleetInboxDeepLink.url(scheme: urlScheme, itemID: itemID) {
                openURL(url)
            }
        default:
            break
        }
    }

    private func reportDenyFailed(_ itemID: InboxItemID) async {
        guard let item = inbox.items.first(where: { $0.id == itemID }), item.status == .pending else { return }
        await notifier.post(InboxNotificationCatalog.denyFailedNotification(for: item))
    }

}
