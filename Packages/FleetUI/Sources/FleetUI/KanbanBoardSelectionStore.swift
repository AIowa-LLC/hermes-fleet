import Foundation

/// t_624b81cd (B1) — per-device kanban board selection (UserDefaults).
///
/// Deliberately NOT synced (like the accent choice): which board a given
/// phone shows is a device-local preference; the gateway operator's
/// active-board pointer is a DIFFERENT thing and is never written by the
/// app (client-side selection only — no `POST /boards/{slug}/switch`).
///
/// `@unchecked Sendable`: UserDefaults itself is thread-safe (documented),
/// and this class holds no other mutable state.
public final class KanbanBoardSelectionStore: @unchecked Sendable {
    /// UserDefaults key for the persisted board slug.
    public static let key = "fleet.kanban.selectedBoard"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The persisted board slug, or nil when following the active board.
    public func loadSelectedBoard() -> String? {
        defaults.string(forKey: Self.key)
    }

    /// Persist (nil clears — back to the gateway's active board).
    public func saveSelectedBoard(_ slug: String?) {
        if let slug {
            defaults.set(slug, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }
}
