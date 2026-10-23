import Foundation

// Build 99 (B3) — local notifications for the approvals inbox.
//
// Local-only and best-effort. A notification is a HINT that the inbox has a
// pending item; the inbox stays authoritative and every decision goes through
// `InboxStore`. Nothing here is remote push (no APNs, no relay, no background
// mode). FleetCore owns the vocabulary, the pure policy and the platform seam;
// the `UNUserNotificationCenter` implementation lives in the app target.
//
// Salvaged from the R8 interim work (#168): the authorization vocabulary, the
// seam shape, and the fail-closed `UnavailableLocalNotifier`. The conversation
// attention policy and the background grace window from that PR are NOT here.

/// Notification permission as the UI needs to see it.
public enum FleetNotificationAuthorization: Sendable, Equatable {
    /// The system has not been asked yet. Only in this state can asking show
    /// the system prompt.
    case notDetermined
    /// The user declined, or turned notifications off in system Settings.
    case denied
    /// Alerts may be delivered (includes provisional delivery).
    case authorized
    /// This build or runtime cannot post notifications.
    case unavailable
}

/// One local notification request.
///
/// `id` is the delivery identifier: posting the same id again REPLACES the
/// delivered notification, and withdrawing the id removes it. `userInfo` holds
/// only identifiers needed to route a tap or a notification action back to the
/// inbox item; it never holds command text, answers, or secrets.
public struct FleetLocalNotification: Sendable, Equatable {
    public let id: String
    public let threadID: String
    public let categoryID: String
    public let title: String
    public let body: String
    public let userInfo: [String: String]

    public init(
        id: String,
        threadID: String,
        categoryID: String,
        title: String,
        body: String,
        userInfo: [String: String] = [:]
    ) {
        self.id = id
        self.threadID = threadID
        self.categoryID = categoryID
        self.title = title
        self.body = body
        self.userInfo = userInfo
    }
}

/// The local notification seam. `UNUserNotificationCenter` implements it in the
/// app target; tests and the scripted simulator fleet use other conformers.
/// Implementations must never log notification content.
public protocol FleetLocalNotifier: Sendable {
    /// Current permission. Never prompts.
    func authorizationStatus() async -> FleetNotificationAuthorization
    /// Ask the system for permission. Call only from an explicit user action
    /// (the Settings toggle), never at launch.
    func requestAuthorization() async -> Bool
    /// Install the notification categories (actions) the inbox posts with.
    func registerCategories(_ categories: [FleetNotificationCategory]) async
    func post(_ notification: FleetLocalNotification) async
    /// Remove delivered and pending notifications by delivery id.
    func withdraw(ids: [String]) async
}

/// Fail-closed default: nothing can be posted and permission is never granted.
public struct UnavailableLocalNotifier: FleetLocalNotifier {
    public init() {}
    public func authorizationStatus() async -> FleetNotificationAuthorization { .unavailable }
    public func requestAuthorization() async -> Bool { false }
    public func registerCategories(_ categories: [FleetNotificationCategory]) async {}
    public func post(_ notification: FleetLocalNotification) async {}
    public func withdraw(ids: [String]) async {}
}
