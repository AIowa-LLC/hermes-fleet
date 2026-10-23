import Foundation
import UserNotifications
import FleetCore

/// Production `FleetLocalNotifier` over `UNUserNotificationCenter`. Local
/// notifications only: no APNs, no remote registration, no extension, no
/// background mode. Never logs notification content.
///
/// `requestAuthorization()` is called only from the Settings toggle (an
/// explicit user action), never at launch.
struct SystemLocalNotifier: FleetLocalNotifier {

    func authorizationStatus() async -> FleetNotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func registerCategories(_ categories: [FleetNotificationCategory]) async {
        let unCategories = categories.map { category in
            UNNotificationCategory(
                identifier: category.id,
                actions: category.actions.map { action in
                    var options: UNNotificationActionOptions = []
                    if action.isDestructive { options.insert(.destructive) }
                    if action.opensApp { options.insert(.foreground) }
                    return UNNotificationAction(identifier: action.id, title: action.title, options: options)
                },
                intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: category.hiddenPreviewsBodyPlaceholder,
                options: [])
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set(unCategories))
    }

    func post(_ notification: FleetLocalNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = notification.threadID
        content.categoryIdentifier = notification.categoryID
        content.userInfo = notification.userInfo
        content.sound = .default
        content.interruptionLevel = .active
        // Same identifier replaces a delivered notification.
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func withdraw(ids: [String]) async {
        guard !ids.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
