import Foundation
import FleetCore

/// File-backed conversation pin store.
///
/// A pin keeps the conversation title and a transcript preview so an offline
/// gateway still has a stable row. That is private message content, so it lives
/// in a protected, backup-excluded file in Application Support
/// (`NSFileProtectionComplete`, `CacheStoreProtection`) rather than in
/// `UserDefaults` (unprotected plist, included in backups).
///
/// Pins saved by the old `UserDefaultsConversationPinStore` are migrated on
/// first load and removed from `UserDefaults` once the protected copy is
/// durable.
public actor FileConversationPinStore: ConversationPinStoring {
    public static let fileName = "fleet-conversation-pins.json"

    /// Where pins written by the old `UserDefaults` store live. Named by value
    /// (not a `UserDefaults` instance) so it can cross the actor boundary.
    public enum LegacySource: Sendable, Equatable {
        case standard
        case suite(String)
        case none
    }

    private let url: URL
    private let legacySource: LegacySource
    private var migrated = false

    public init(url: URL = FileConversationPinStore.defaultURL(), legacy: LegacySource = .standard) {
        self.url = url
        self.legacySource = legacy
    }

    private var legacyDefaults: UserDefaults? {
        switch legacySource {
        case .standard: return .standard
        case .suite(let name): return UserDefaults(suiteName: name)
        case .none: return nil
        }
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(fileName)
    }

    public func loadPins() async throws -> [FleetConversationPin] {
        try migrateLegacyIfNeeded()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        BackupExclusion.apply(to: url) // files written before exclusion existed
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([FleetConversationPin].self, from: data)
    }

    public func savePins(_ pins: [FleetConversationPin]) async throws {
        try migrateLegacyIfNeeded()
        try write(pins)
    }

    private func write(_ pins: [FleetConversationPin]) throws {
        let data = try JSONEncoder().encode(pins)
        // `NSFileProtectionComplete` is an iOS data-protection class; on a macOS
        // host (package tests) it can fail while the machine is locked.
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        // An atomic write replaces the file: re-apply exclusion every time.
        try CacheStoreProtection.apply(to: url)
    }

    private func migrateLegacyIfNeeded() throws {
        guard !migrated else { return }
        guard let defaults = legacyDefaults,
              let legacy = defaults.data(forKey: UserDefaultsConversationPinStore.storageKey) else {
            migrated = true
            return
        }
        // Never overwrite pins already in the protected file with legacy ones.
        if !FileManager.default.fileExists(atPath: url.path) {
            // An undecodable legacy blob can never become a pin; keeping it
            // would break every load and save forever, and it is plaintext.
            // Drop it. Write failures still throw and keep the legacy copy.
            if let pins = try? JSONDecoder().decode([FleetConversationPin].self, from: legacy) {
                try write(pins)
            }
        }
        defaults.removeObject(forKey: UserDefaultsConversationPinStore.storageKey)
        migrated = true
    }

    /// UI-test hygiene (HERMES_FLEET_NAV_RESET), mirroring the legacy store.
    public static func resetForUITests(url: URL = FileConversationPinStore.defaultURL()) {
        try? FileManager.default.removeItem(at: url)
        UserDefaultsConversationPinStore.resetForUITests()
    }
}
