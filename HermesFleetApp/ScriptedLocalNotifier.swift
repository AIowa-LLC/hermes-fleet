import Foundation
import FleetCore

#if DEBUG && targetEnvironment(simulator)

/// Deterministic stand-in for `SystemLocalNotifier` in the scripted simulator
/// fleet. It never shows a system permission dialog and never posts to the
/// system, but it keeps a record of what WOULD have been posted, so UI tests
/// and the demo fleet can observe posts and withdrawals in process.
///
/// `HERMES_FLEET_NOTIFICATION_AUTH` selects the initial permission:
/// `authorized` (default: the toggle flips without a prompt), `notDetermined`
/// (asking grants), or `denied` (asking is refused).
final class ScriptedLocalNotifier: FleetLocalNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var status: FleetNotificationAuthorization
    private var posted: [FleetLocalNotification] = []
    private var withdrawn: [String] = []
    private var categories: [FleetNotificationCategory] = []

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        switch environment["HERMES_FLEET_NOTIFICATION_AUTH"] {
        case "notDetermined": status = .notDetermined
        case "denied": status = .denied
        default: status = .authorized
        }
    }

    /// Everything posted and not yet withdrawn, in post order.
    var deliveredNotifications: [FleetLocalNotification] {
        lock.withLock { posted }
    }

    /// Every delivery id withdrawn so far, in order.
    var withdrawnIdentifiers: [String] {
        lock.withLock { withdrawn }
    }

    var registeredCategories: [FleetNotificationCategory] {
        lock.withLock { categories }
    }

    func authorizationStatus() async -> FleetNotificationAuthorization {
        lock.withLock { status }
    }

    func requestAuthorization() async -> Bool {
        lock.withLock {
            if status == .notDetermined { status = .authorized }
            return status == .authorized
        }
    }

    func registerCategories(_ categories: [FleetNotificationCategory]) async {
        lock.withLock { self.categories = categories }
    }

    func post(_ notification: FleetLocalNotification) async {
        lock.withLock {
            posted.removeAll { $0.id == notification.id }
            posted.append(notification)
        }
    }

    func withdraw(ids: [String]) async {
        lock.withLock {
            posted.removeAll { ids.contains($0.id) }
            withdrawn.append(contentsOf: ids)
        }
    }
}

#endif
