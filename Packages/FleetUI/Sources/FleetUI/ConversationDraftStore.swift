import Foundation
import FleetCore
import FleetPersistence

/// P0.4a: device-local persistence for unsent 1:1 conversation composer text.
///
/// A conversation view is torn down by navigation, App Lock, and scene-phase
/// changes; without this store a half-written message is silently lost.
///
/// Contract:
/// - Keys are source-qualified: `gateway#profile` route plus the durable
///   session id (canonical Bot Chat sessions are ordinary session ids and are
///   covered identically). A same-named session on another gateway/profile is
///   a different draft.
/// - Drafts are non-secret but can contain sensitive text, so the single
///   backing file is written with `NSFileProtectionComplete` and excluded from
///   device/iCloud backup (`CacheStoreProtection`). This is stronger than the
///   UserDefaults-backed `RoomDraftStore`, which has neither property.
/// - Bounded: at most `maxEntries` drafts, each at most `maxCharacters`, and
///   drafts untouched for `retentionInterval` (30 days) are dropped.
/// - Pruned when a gateway is removed and on "Clear local cache".
/// - Writes are debounced (`scheduleSave`); `flush()` forces pending writes
///   out (scene phase change / view disappearance). `clear` cancels a pending
///   write so a stale debounce can never resurrect a sent draft.
/// - Fails closed on an unreadable file: if a file exists but cannot be read
///   (e.g. device locked, `.complete`), nothing is persisted until it has been
///   read successfully, so existing drafts are never overwritten with a
///   partial view.
public final class ConversationDraftStore: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        let gatewayIDRaw: String
        var text: String
        var updatedAt: Date
    }

    public static let maxEntries = 50
    public static let maxCharacters = 20_000
    public static let retentionInterval: TimeInterval = 30 * 24 * 3600
    public static let defaultDebounce: TimeInterval = 0.5

    private struct Pending {
        let gatewayIDRaw: String
        let text: String
        let token: UInt64
        let task: Task<Void, Never>
    }

    private let url: URL
    private let now: @Sendable () -> Date
    private let debounce: TimeInterval
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var pending: [String: Pending] = [:]
    private var nextToken: UInt64 = 0

    /// - Parameters:
    ///   - url: backing JSON file. Production: Application Support; tests: a
    ///     unique temp file.
    ///   - now: injected clock for deterministic retention tests.
    ///   - debounce: quiet interval before a scheduled save is written.
    public init(
        url: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        debounce: TimeInterval = ConversationDraftStore.defaultDebounce
    ) {
        self.url = url
        self.now = now
        self.debounce = debounce
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("fleet-conversation-drafts.json")
    }

    /// Source-qualified identity for one conversation.
    public static func key(route: Route, sessionID: String) -> String {
        "conv|\(route.gatewayID.rawValue)#\(route.profileSlug.rawValue)|\(sessionID)"
    }

    // MARK: reads

    /// The saved draft for this exact conversation ("" when none). Sees
    /// not-yet-flushed text so a re-open within the debounce window restores
    /// the latest keystrokes.
    public func draft(route: Route, sessionID: String) -> String {
        let key = Self.key(route: route, sessionID: sessionID)
        lock.lock(); defer { lock.unlock() }
        if let item = pending[key] { return item.text }
        guard loadLocked() else { return "" }
        guard let entry = entries[key],
              entry.updatedAt > now().addingTimeInterval(-Self.retentionInterval) else { return "" }
        return entry.text
    }

    /// Number of stored (non-expired) drafts, including unflushed ones.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        _ = loadLocked()
        let cutoff = now().addingTimeInterval(-Self.retentionInterval)
        var keys = Set(entries.filter { $0.value.updatedAt > cutoff }.keys)
        for (key, item) in pending {
            if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                keys.remove(key)
            } else {
                keys.insert(key)
            }
        }
        return keys.count
    }

    // MARK: writes

    /// Debounced save. An empty (or whitespace-only) draft removes the entry.
    public func scheduleSave(_ text: String, route: Route, sessionID: String) {
        let key = Self.key(route: route, sessionID: sessionID)
        lock.lock(); defer { lock.unlock() }
        pending[key]?.task.cancel()
        nextToken &+= 1
        let token = nextToken
        let delay = debounce
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.commit(key: key, token: token)
        }
        pending[key] = Pending(
            gatewayIDRaw: route.gatewayID.rawValue, text: text, token: token, task: task)
    }

    /// Write every pending draft now (call on scene-phase change and when the
    /// conversation disappears; the debounce timer may not get to run).
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return }
        let drained = pending
        pending = [:]
        for (key, item) in drained {
            item.task.cancel()
            applyLocked(key: key, gatewayIDRaw: item.gatewayIDRaw, text: item.text)
        }
        persistLocked()
    }

    /// Remove the draft for one conversation (successful send). Cancels any
    /// pending debounced write for it.
    public func clear(route: Route, sessionID: String) {
        let key = Self.key(route: route, sessionID: sessionID)
        lock.lock(); defer { lock.unlock() }
        pending[key]?.task.cancel()
        pending[key] = nil
        guard loadLocked(), entries.removeValue(forKey: key) != nil else { return }
        persistLocked()
    }

    /// Drop every draft that belongs to a removed gateway.
    public func prune(gatewayID: GatewayID) {
        let raw = gatewayID.rawValue
        lock.lock(); defer { lock.unlock() }
        for (key, item) in pending where item.gatewayIDRaw == raw {
            item.task.cancel()
            pending[key] = nil
        }
        guard loadLocked() else { return }
        entries = entries.filter { $0.value.gatewayIDRaw != raw }
        persistLocked()
    }

    /// Drop drafts whose owning gateway is no longer registered.
    public func pruneToRegisteredGateways(_ rawIDs: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        for (key, item) in pending where !rawIDs.contains(item.gatewayIDRaw) {
            item.task.cancel()
            pending[key] = nil
        }
        guard loadLocked() else { return }
        entries = entries.filter { rawIDs.contains($0.value.gatewayIDRaw) }
        persistLocked()
    }

    /// Remove every device-local draft (Clear local cache).
    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        for item in pending.values { item.task.cancel() }
        pending = [:]
        entries = [:]
        loaded = true
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: internals

    private func commit(key: String, token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let item = pending[key], item.token == token else { return }
        pending[key] = nil
        applyLocked(key: key, gatewayIDRaw: item.gatewayIDRaw, text: item.text)
        persistLocked()
    }

    private func applyLocked(key: String, gatewayIDRaw: String, text: String) {
        guard loadLocked() else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries[key] = nil
        } else {
            entries[key] = Entry(
                gatewayIDRaw: gatewayIDRaw,
                text: String(text.prefix(Self.maxCharacters)),
                updatedAt: now())
        }
    }

    /// Lazy load. Returns false only when a file exists but could not be read
    /// (nothing must be persisted over it). A missing or corrupt file loads as
    /// empty.
    private func loadLocked() -> Bool {
        if loaded { return true }
        guard FileManager.default.fileExists(atPath: url.path) else {
            loaded = true
            return true
        }
        guard let data = try? Data(contentsOf: url) else { return false }
        entries = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        loaded = true
        return true
    }

    private func pruneExpiredAndCapLocked() {
        let cutoff = now().addingTimeInterval(-Self.retentionInterval)
        entries = entries.filter { $0.value.updatedAt > cutoff }
        if entries.count > Self.maxEntries {
            let keep = entries.sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(Self.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    private func persistLocked() {
        guard loaded else { return }
        pruneExpiredAndCapLocked()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            // Atomic replace creates a new inode, so re-assert backup
            // exclusion (and protection class) after every write.
            try CacheStoreProtection.apply(to: url)
        } catch {
            // Best-effort: the in-memory copy stays authoritative and the next
            // save retries (e.g. a `.complete` write while the device is locked).
        }
    }
}
