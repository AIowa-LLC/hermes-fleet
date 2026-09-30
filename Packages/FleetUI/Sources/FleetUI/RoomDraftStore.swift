import Foundation
import FleetCore

/// Group-room composer drafts (P0.3c).
///
/// Drafts are half-written messages and can be sensitive, so they live in a
/// single JSON file written with `NSFileProtectionComplete` and excluded from
/// device/iCloud backup (`LocalFileProtection`) — the same pattern as the 1:1
/// `ConversationDraftStore`. They previously lived in `UserDefaults`, which
/// has neither property; `migrateLegacyDraftsIfNeeded` moves any such drafts
/// into the file once and then deletes the `UserDefaults` keys.
///
/// Contract:
/// - Entries are keyed by `FleetRoomID.storageKey`
///   (`<provenance>:<gatewayID>:<roomKey>`), exactly as the legacy keys were
///   (minus the `fleet.room.draft.v1.` prefix).
/// - An unreadable file (device locked, `.complete`) is never overwritten:
///   nothing is persisted until it has been read successfully.
/// - A failed attribute application never blocks a draft; it reports one
///   type-only failure and the next write retries.
/// - Legacy keys are deleted only after the migrated drafts are durably
///   written, so a failed migration loses nothing and retries on next access.
final class RoomDraftFileStore: @unchecked Sendable {
    static let legacyKeyPrefix = "fleet.room.draft.v1."

    private let url: URL
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var entries: [String: String] = [:]
    private var loaded = false
    private var legacyMigrated = false
    private var reporter: (@Sendable (LocalFileProtection.Failure) -> Void)?

    init(
        url: URL,
        defaults: UserDefaults = .standard,
        reporter: (@Sendable (LocalFileProtection.Failure) -> Void)? = nil
    ) {
        self.url = url
        self.defaults = defaults
        self.reporter = reporter
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("fleet-room-drafts.json")
    }

    func setReporter(_ reporter: (@Sendable (LocalFileProtection.Failure) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.reporter = reporter
    }

    /// Read back the draft file's protection attributes (tests, diagnostics).
    func protectionAttributes() -> LocalFileProtection.Attributes {
        LocalFileProtection.read(from: url)
    }

    // MARK: reads / writes

    func load(for id: FleetRoomID) -> String {
        lock.lock(); defer { lock.unlock() }
        guard ensureReadyLocked() else { return "" }
        return entries[id.storageKey] ?? ""
    }

    func save(_ draft: String, for id: FleetRoomID) {
        lock.lock(); defer { lock.unlock() }
        guard ensureReadyLocked() else { return }
        let key = id.storageKey
        if draft.isEmpty {
            guard entries.removeValue(forKey: key) != nil else { return }
        } else {
            guard entries[key] != draft else { return }
            entries[key] = draft
        }
        _ = persistLocked()
    }

    func clear(for id: FleetRoomID) {
        save("", for: id)
    }

    /// Remove every saved draft that belongs to `gatewayID`'s rooms (gateway
    /// removal). Keys are `<provenance>:<gatewayID>:<roomKey>` and gateway ids
    /// may themselves contain `:` (`host:port`), so a bare prefix match could
    /// also hit a different gateway whose id extends this one.
    /// `otherGatewayIDs` (the gateways that remain) disambiguates: a key that
    /// begins with another gateway's own `<provenance>:<id>:` is left alone.
    func clearAll(forGateway gatewayID: GatewayID, otherGatewayIDs: [GatewayID]) {
        let own = [RoomProvenance.hosted, .desktopLegacy].map { "\($0.rawValue):\(gatewayID.rawValue):" }
        let others = [RoomProvenance.hosted, .desktopLegacy].flatMap { provenance in
            otherGatewayIDs.filter { $0 != gatewayID }.map { "\(provenance.rawValue):\($0.rawValue):" }
        }
        lock.lock(); defer { lock.unlock() }
        guard ensureReadyLocked() else { return }
        let doomed = entries.keys.filter { key in
            own.contains(where: key.hasPrefix) && !others.contains(where: key.hasPrefix)
        }
        guard !doomed.isEmpty else { return }
        for key in doomed { entries[key] = nil }
        _ = persistLocked()
    }

    /// Remove every draft, in the file and any legacy `UserDefaults` key
    /// (UI-test hygiene; normal launches never call this).
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]
        loaded = true
        legacyMigrated = true
        try? FileManager.default.removeItem(at: url)
        for key in legacyKeysLocked() { defaults.removeObject(forKey: key) }
    }

    // MARK: migration

    /// One-time move of `UserDefaults` drafts into the protected file. Drafts
    /// already in the file win (they are newer by construction). Legacy keys
    /// are removed only after the write succeeded. Returns false when the move
    /// could not complete (unreadable file / failed write) and will retry.
    @discardableResult
    func migrateLegacyDraftsIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return migrateLegacyLocked()
    }

    private func legacyKeysLocked() -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.legacyKeyPrefix) }
    }

    private func migrateLegacyLocked() -> Bool {
        if legacyMigrated { return true }
        guard loadLocked() else { return false }
        let keys = legacyKeysLocked()
        if keys.isEmpty {
            legacyMigrated = true
            return true
        }
        for key in keys {
            guard let text = defaults.string(forKey: key), !text.isEmpty else { continue }
            let storageKey = String(key.dropFirst(Self.legacyKeyPrefix.count))
            if entries[storageKey] == nil { entries[storageKey] = text }
        }
        guard persistLocked() else { return false }
        for key in keys { defaults.removeObject(forKey: key) }
        legacyMigrated = true
        return true
    }

    // MARK: internals

    /// Load + migrate. False means the file exists but is unreadable right
    /// now; callers must not persist over it.
    private func ensureReadyLocked() -> Bool {
        migrateLegacyLocked()
        return loaded
    }

    private func loadLocked() -> Bool {
        if loaded { return true }
        guard FileManager.default.fileExists(atPath: url.path) else {
            loaded = true
            return true
        }
        guard let data = try? Data(contentsOf: url) else { return false }
        entries = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        loaded = true
        // A file written before its directory/attributes were right is
        // re-protected in place on first successful read.
        for failure in LocalFileProtection.applyBestEffort(to: [("drafts", url)]) {
            reporter?(failure)
        }
        return true
    }

    /// Returns true when the bytes are on disk (attribute-only failures are
    /// reported, not fatal).
    private func persistLocked() -> Bool {
        guard loaded else { return false }
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        do {
            try LocalFileProtection.write(data, to: url, role: "drafts")
            return true
        } catch let failure as LocalFileProtection.Failure {
            reporter?(failure)
            return true
        } catch {
            // In-memory copy stays authoritative; the next save retries (e.g.
            // a `.complete` write while the device is locked).
            return false
        }
    }
}

/// Static facade over the process-wide protected draft store, so call sites
/// (`RoomChatView`, `AppEnvironment`) keep the same shape they had when the
/// drafts lived in `UserDefaults`.
enum RoomDraftStore {
    static let shared = RoomDraftFileStore(url: RoomDraftFileStore.defaultURL())

    /// UI-test hygiene: clear every draft (protected file and any legacy
    /// `UserDefaults` key). `defaults` is injectable for tests.
    static func resetForUITests(defaults: UserDefaults = .standard) {
        if defaults === UserDefaults.standard {
            shared.removeAll()
        } else {
            RoomDraftFileStore.removeLegacyKeys(in: defaults)
        }
    }

    static func load(for id: FleetRoomID) -> String { shared.load(for: id) }

    static func save(_ draft: String, for id: FleetRoomID) { shared.save(draft, for: id) }

    static func clear(for id: FleetRoomID) { shared.clear(for: id) }

    static func clearAll(forGateway gatewayID: GatewayID, otherGatewayIDs: [GatewayID]) {
        shared.clearAll(forGateway: gatewayID, otherGatewayIDs: otherGatewayIDs)
    }
}

extension RoomDraftFileStore {
    /// Remove every legacy draft key from `defaults` without touching the file.
    static func removeLegacyKeys(in defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(legacyKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
