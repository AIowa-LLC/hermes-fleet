import Foundation
import FleetCore

/// Dogfood r4 (ChatGPT parity): device-local last-read watermarks for
/// conversation sessions. A session is UNREAD when the gateway's
/// `lastActive` stamp (epoch seconds) is strictly newer than the stored
/// watermark. `lastActive == 0` means the source did not supply one — it
/// can never light the dot (no invented signal).
///
/// Watermark identity = `FleetChatEntry.id` (route.id + "/" + session.id),
/// the same stable key the archive store uses. Opening a conversation
/// stamps read (decision 1).
enum FleetUnreadStore {
    private static let key = "fleet.chats.readwatermarks.v1"

    static func watermarks(defaults: UserDefaults = .standard) -> [String: Double] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func isUnread(route: Route, session: SessionSummary,
                         defaults: UserDefaults = .standard) -> Bool {
        guard session.lastActive > 0 else { return false }
        let id = "\(route.id)/\(session.id)"
        let mark = watermarks(defaults: defaults)[id] ?? 0
        return session.lastActive > mark
    }

    /// Decision 1: opening the conversation marks it read — stamp the
    /// gateway's CURRENT lastActive for the session (never a local clock:
    /// device clock skew must not fabricate or mask unread state).
    static func markRead(route: Route, sessionID: String, lastActive: Double,
                         defaults: UserDefaults = .standard) {
        guard lastActive > 0 else { return }
        var marks = watermarks(defaults: defaults)
        marks["\(route.id)/\(sessionID)"] = lastActive
        if let data = try? JSONEncoder().encode(marks) {
            defaults.set(data, forKey: key)
        }
    }

    /// UI-test hygiene (HERMES_FLEET_NAV_RESET): watermarks must not leak
    /// across suite runs (the pin-store leak lesson).
    static func resetForUITests(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
