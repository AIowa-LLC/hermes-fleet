import Foundation
import FleetCore

#if DEBUG && targetEnvironment(simulator)

/// R8 (#95): deterministic stand-in for `SystemLocalNotifier` in the scripted
/// simulator fleet, so the Settings toggle and the explain-first card are
/// walkable in UI tests without a system permission dialog.
///
/// `HERMES_FLEET_NOTIFICATION_AUTH` selects the initial permission:
/// `authorized` (default — the toggle flips without a prompt), `notDetermined`
/// (asking grants), or `denied` (asking is refused).
final class ScriptedLocalNotifier: FleetLocalNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var status: FleetNotificationAuthorization
    private var posted: [FleetLocalNotification] = []

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        switch environment["HERMES_FLEET_NOTIFICATION_AUTH"] {
        case "notDetermined": status = .notDetermined
        case "denied": status = .denied
        default: status = .authorized
        }
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

    func post(_ notification: FleetLocalNotification) async {
        lock.withLock {
            posted.removeAll { $0.id == notification.id }
            posted.append(notification)
        }
    }

    func withdraw(ids: [String]) async {
        lock.withLock { posted.removeAll { ids.contains($0.id) } }
    }

    func withdraw(threadID: String) async {
        lock.withLock { posted.removeAll { $0.threadID == threadID } }
    }
}

#endif
