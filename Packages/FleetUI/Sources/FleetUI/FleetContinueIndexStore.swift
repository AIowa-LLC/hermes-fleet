import Foundation
import FleetCore

/// FOS-4 (SPEC §7 Continue / §17 persistence safety) — the device-local
/// recent-open index: at most 50 source-qualified references for 30 days,
/// recording an open ONLY after a real object destination resolved.
///
/// Truth contract:
/// - IDs are source-qualified (Route + sessionID for conversations;
///   FleetRoomID for rooms) — a same-named conversation on another gateway
///   NEVER substitutes (SPEC §7 "Never same-name substitution").
/// - Display metadata is the minimum needed to render a cached row
///   (title + bot/gateway label). No credentials, tokens, grants, or raw
///   secret-bearing endpoints (SPEC §17 persistence safety).
/// - Rows open the EXACT conversation: the Home row navigates by the stored
///   source identity, never by re-searching for a similar title.
/// - Pruned on gateway removal (the app seam calls `prune(gatewayID:)` —
///   a removed source must not resolve to another gateway, SPEC §8).
/// - App-Lock protected: the file lives in the app container, protected by
///   the app's at-rest data protection (same as every other Fleet store);
///   the lock screen gates the UI, this store adds no secondary copy.
public final class FleetContinueIndexStore: @unchecked Sendable {
    /// One persisted recent-open reference.
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case ordinaryConversation
            case canonicalBotChat
            case room
        }

        /// Source-qualified identity, e.g.
        /// `conv|<gatewayID>#<profileSlug>|<sessionID>` or
        /// `room|<gatewayID>|hosted|<key>`.
        public let id: String
        public let kind: Kind
        public let gatewayIDRaw: String
        public let routeProfile: String?
        public let sessionID: String?
        /// Room provenance + key when kind == .room.
        public let roomProvenance: String?
        public let roomKey: String?
        /// Minimal display metadata (no secrets).
        public let title: String
        public let subtitle: String
        public let openedAt: Date

        public init(
            id: String,
            kind: Kind,
            gatewayIDRaw: String,
            routeProfile: String? = nil,
            sessionID: String? = nil,
            roomProvenance: String? = nil,
            roomKey: String? = nil,
            title: String,
            subtitle: String,
            openedAt: Date
        ) {
            self.id = id
            self.kind = kind
            self.gatewayIDRaw = gatewayIDRaw
            self.routeProfile = routeProfile
            self.sessionID = sessionID
            self.roomProvenance = roomProvenance
            self.roomKey = roomKey
            self.title = title
            self.subtitle = subtitle
            self.openedAt = openedAt
        }
    }

    public static let maxEntries = 50
    public static let retentionInterval: TimeInterval = 30 * 24 * 3600

    private let url: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cache: [Entry]

    // MARK: init / load

    /// - Parameters:
    ///   - url: JSON file location. Production: Application Support;
    ///     tests: a temp file (or a fresh URL per test for hermetic runs).
    ///   - now: injected clock for deterministic retention/pruning tests.
    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            cache = decoded
        } else {
            cache = []
        }
    }

    /// Default production location (Application Support, app container).
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("fleet-continue-index.json")
    }

    // MARK: reads

    /// Entries newest-first, already retention-pruned and capped.
    public func entries() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return pruneLocked()
    }

    // MARK: writes

    /// Record an open of an EXACT conversation. Call only after the
    /// destination actually resolved (SPEC §17 — a failed link does not
    /// advance recency). Re-opening moves the existing entry to the front
    /// and refreshes its metadata; identity is never duplicated.
    public func recordConversationOpen(
        route: Route,
        sessionID: String,
        canonical: Bool,
        title: String,
        subtitle: String
    ) {
        let id = Self.conversationID(route: route, sessionID: sessionID)
        record(Entry(
            id: id,
            kind: canonical ? .canonicalBotChat : .ordinaryConversation,
            gatewayIDRaw: route.gatewayID.rawValue,
            routeProfile: route.profileSlug.rawValue,
            sessionID: sessionID,
            title: title,
            subtitle: subtitle,
            openedAt: now()))
    }

    /// Record an open of an EXACT room.
    public func recordRoomOpen(room: FleetRoomID, title: String, subtitle: String) {
        record(Entry(
            id: Self.roomID(room),
            kind: .room,
            gatewayIDRaw: room.gatewayID.rawValue,
            roomProvenance: room.provenance.rawValue,
            roomKey: room.key,
            title: title,
            subtitle: subtitle,
            openedAt: now()))
    }

    /// Shared upsert: dedupe by id, newest-first, cap 50, persist.
    private func record(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll { $0.id == entry.id }
        cache.insert(entry, at: 0)
        persistLocked(pruneLocked())
    }

    /// Prune every entry belonging to a removed gateway (SPEC §8 removal —
    /// saved recent entries must not resolve to another gateway).
    public func prune(gatewayID: GatewayID) {
        lock.lock(); defer { lock.unlock() }
        let raw = gatewayID.rawValue
        persistLocked(pruneLocked().filter { $0.gatewayIDRaw != raw })
    }

    /// Drop entries whose owning gateway is no longer registered.
    public func pruneToRegisteredGateways(_ rawIDs: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        persistLocked(pruneLocked().filter { rawIDs.contains($0.gatewayIDRaw) })
    }

    /// Remove one exact entry (tombstone path).
    public func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        persistLocked(pruneLocked().filter { $0.id != id })
    }

    // MARK: identity

    public static func conversationID(route: Route, sessionID: String) -> String {
        "conv|\(route.gatewayID.rawValue)#\(route.profileSlug.rawValue)|\(sessionID)"
    }

    public static func roomID(_ room: FleetRoomID) -> String {
        "room|\(room.gatewayID.rawValue)|\(room.provenance.rawValue)|\(room.key)"
    }

    // MARK: persistence

    /// Retention + cap, executed under lock; returns the surviving entries.
    private func pruneLocked() -> [Entry] {
        let cutoff = now().addingTimeInterval(-Self.retentionInterval)
        let surviving = cache
            .filter { $0.openedAt > cutoff }
            .sorted { $0.openedAt > $1.openedAt }
            .prefix(Self.maxEntries)
        // Keep the pruned cache in sync so repeated reads are stable.
        if surviving.count != cache.count {
            cache = Array(surviving)
            persistLocked(cache)
        }
        return Array(surviving)
    }

    private func persistLocked(_ entries: [Entry]) {
        cache = entries
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
