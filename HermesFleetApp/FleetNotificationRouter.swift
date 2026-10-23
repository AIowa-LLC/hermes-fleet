import Foundation
import UIKit
import UserNotifications
import FleetCore
import FleetUI

/// Routes notification taps and actions to `InboxNotificationCoordinator`, and
/// decides foreground presentation. Installed as the notification center
/// delegate at app init so a cold-launch tap is seen. A response that arrives
/// before the coordinator is attached is buffered and replayed on attach.
@MainActor
final class FleetNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FleetNotificationRouter()

    private weak var coordinator: InboxNotificationCoordinator?
    private var buffered: [(action: String, itemID: String)] = []

    /// Install as the delegate. Does not request permission.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Attach the app's coordinator: it opens deep links through UIKit and
    /// receives every buffered response.
    func attach(_ coordinator: InboxNotificationCoordinator) {
        coordinator.openURL = { url in
            Task { @MainActor in _ = await UIApplication.shared.open(url) }
        }
        self.coordinator = coordinator
        let pending = buffered
        buffered = []
        for response in pending {
            route(action: response.action, itemID: response.itemID)
        }
    }

    private func route(action: String, itemID: String) {
        guard let coordinator else {
            buffered.append((action, itemID))
            return
        }
        Task { @MainActor in
            await coordinator.handleResponse(actionID: action, itemIDRaw: itemID)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let itemID = info[InboxNotificationCatalog.itemIDKey] as? String else { return }
        // A tap on the notification body is the Review action.
        let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? InboxNotificationCatalog.reviewActionID
            : response.actionIdentifier
        await MainActor.run { route(action: action, itemID: itemID) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        guard let itemID = info[InboxNotificationCatalog.itemIDKey] as? String else {
            return [.banner, .list, .sound]
        }
        let show = await MainActor.run {
            coordinator?.presentsInForeground(itemIDRaw: itemID) ?? true
        }
        return show ? [.banner, .list, .sound] : []
    }
}
