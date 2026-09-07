import Foundation

/// Wire constants and shared value types for the Bot Mode contracts.
///
/// Ground truth: upstream hermes-agent `08b140d14e6c1d49f9b7ad02c9437fe940d54d65`.
/// - Canonical chat title `Bot Chat` — apps/desktop/src/plugins/hermes-bots/canonical-chat.ts:48.
/// - `canonical_session {id, resolved_id, root_title, ...}` — tui_gateway/methods_profiles.py:138-172.
/// - `worker_session {id, source, title, last_active}` — methods_profiles.py:191-194.
/// - `bot_mode_protocol: true` (top-level profiles.list flag; clients must NOT
///   append the Bot Mode protocol to SOUL.md) — methods_profiles.py:252-254.
/// - Legacy group projection under ui_meta key `hermes-bots-groups` (v3) —
///   apps/desktop group-chat.ts:67-74.
public enum BotModeContract {
    /// EXACT title identifying the canonical forever Bot Chat. Identity is
    /// (profile, "Bot Chat") — never a stored session-id pointer.
    public static let canonicalChatTitle = "Bot Chat"

    /// ui_meta key holding the Desktop Bots plugin's per-bot metadata.
    public static let botsMetaKey = "hermes-bots"

    /// ui_meta key holding the Desktop legacy group-room display projection.
    public static let legacyGroupsMetaKey = "hermes-bots-groups"

    /// Canonical hidden session title pattern the hosted driver uses:
    /// `"Group: <room_id>"` — tui_gateway/hosted_room_driver.py:904-906.
    public static func hostedRoomSessionTitle(roomID: String) -> String {
        "Group: \(roomID)"
    }
}

/// The canonical Bot Chat reference resolved by `profiles.list`.
///
/// `id` is the durable registry row; `resolvedID` is the live compression-tip
/// id (`db.get_compression_tip` walks proven compression edges only —
/// hermes_state_compression.py:620-631). Opening uses the tip when present:
/// `existing.resolved_id || existing.id` (canonical-chat.ts:342,496-497).
public struct CanonicalSessionRef: Hashable, Sendable, Codable {
    public let id: String
    public let resolvedID: String?
    /// Root title of the compression lineage (present on exact-lookup rows).
    public let rootTitle: String?
    public let title: String?
    public let preview: String?
    public let startedAt: Double?
    public let lastActive: Double?
    public let messageCount: Int?

    public init(
        id: String,
        resolvedID: String? = nil,
        rootTitle: String? = nil,
        title: String? = nil,
        preview: String? = nil,
        startedAt: Double? = nil,
        lastActive: Double? = nil,
        messageCount: Int? = nil
    ) {
        self.id = id
        self.resolvedID = resolvedID
        self.rootTitle = rootTitle
        self.title = title
        self.preview = preview
        self.startedAt = startedAt
        self.lastActive = lastActive
        self.messageCount = messageCount
    }

    /// The session id to open: the compression tip when the lineage has
    /// rotated, else the durable registry row id. BOTH ids identify the same
    /// canonical chat — this never forks a new session.
    ///
    /// QA hardening: an empty/whitespace `resolvedID` is rejected here
    /// (treated as absent) so a malformed decode can never route an empty
    /// session id into navigation. `id` is likewise validated; a malformed
    /// pair yields nil and the caller fails closed.
    public var openID: String? {
        let trimmedTip = resolvedID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTip.isEmpty { return trimmedTip }
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedID.isEmpty ? nil : trimmedID
    }

    /// Unconditional id for callers that have already validated shape.
    public var requiredID: String { id }
}

/// The newest denied-source (kanban/tool) worker session — a liveness signal
/// for bot worker activity, not a human conversation.
public struct WorkerSessionRef: Hashable, Sendable, Codable {
    public let id: String
    public let source: String
    public let title: String?
    public let lastActive: Double

    public init(id: String, source: String, title: String? = nil, lastActive: Double) {
        self.id = id
        self.source = source
        self.title = title
        self.lastActive = lastActive
    }
}

/// Reachability of a bot's OWNING GATEWAY source.
///
/// When a gateway is unreachable, its bots remain in the roster as offline
/// ghosts: their `Route` identity, metadata, and cached presentation are
/// retained (never silently substituted by a same-named profile on another
/// gateway). Presence is derived from the roster snapshot's per-gateway
/// outcome — never fabricated.
public enum BotOwnerStatus: Hashable, Sendable, Codable {
    /// The owning gateway answered the latest roster refresh.
    case online
    /// The owning gateway failed to answer; identity retained as a ghost.
    case offlineGhost
    /// No roster outcome yet (cold start).
    case unknown

    public var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    public var isGhost: Bool {
        if case .offlineGhost = self { return true }
        return false
    }
}
