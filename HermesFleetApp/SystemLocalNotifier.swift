import Foundation
import UIKit
import UserNotifications
import FleetCore

/// R8 (#95): the production `FleetLocalNotifier` over
/// `UNUserNotificationCenter`. Local notifications only — no APNs, no remote
/// registration, no extension. Never logs notification content.
///
/// `requestAuthorization()` is called only from an explicit user action
/// (Settings toggle or the explain-first card), never at launch.
struct SystemLocalNotifier: FleetLocalNotifier {
    /// userInfo key carrying the `hermes-fleet://conversation` deep link.
    static let deepLinkKey = "fleet.deepLink"

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
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ notification: FleetLocalNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = notification.threadID
        content.sound = .default
        content.interruptionLevel = .active
        if let target = notification.target {
            content.userInfo[Self.deepLinkKey] = FleetConversationDeepLink.url(
                route: target.route, sessionID: target.sessionID, canonical: target.canonical
            ).absoluteString
        }
        // Same identifier replaces the delivered notification (coalescing).
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func withdraw(ids: [String]) async {
        guard !ids.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func withdraw(threadID: String) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let ids = delivered
            .filter { $0.request.content.threadIdentifier == threadID }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// Routes a notification tap to the existing conversation deep link. Buffers a
/// tap that arrives (cold launch) before the app root attached its handler.
/// The URL is re-validated by `FleetConversationDeepLink.target(from:)` at the
/// consumer; a notification is a hint, never authoritative state — opening the
/// conversation re-reads pending approvals from the gateway.
@MainActor
final class FleetNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FleetNotificationRouter()

    private var handler: ((URL) -> Void)?
    private var bufferedURL: URL?

    /// Install as the notification center delegate. Does not request
    /// permission. Call as early as possible so a cold-launch tap is seen.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func attach(handler: @escaping (URL) -> Void) {
        self.handler = handler
        if let url = bufferedURL {
            bufferedURL = nil
            handler(url)
        }
    }

    private func route(_ url: URL) {
        if let handler {
            handler(url)
        } else {
            bufferedURL = url
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content.userInfo[SystemLocalNotifier.deepLinkKey] as? String,
              let url = URL(string: raw) else { return }
        await MainActor.run { route(url) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The coordinator only posts while the app is inactive or the user is
        // looking at another conversation; show it in-app in the latter case.
        [.banner, .list, .sound]
    }
}

/// `UIApplication.beginBackgroundTask` adapter for the grace window. No
/// background modes are involved.
@MainActor
final class UIKitBackgroundTasks: FleetBackgroundTaskProviding {
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int? {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { expiration() }
        }
        return identifier == .invalid ? nil : identifier.rawValue
    }

    func end(_ identifier: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: identifier))
    }
}
