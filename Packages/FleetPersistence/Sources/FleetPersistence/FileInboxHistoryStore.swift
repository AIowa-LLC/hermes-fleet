import Foundation
import FleetCore

/// File-backed approvals-inbox history: last-known items and the decision
/// audit trail.
///
/// Stored in a protected, backup-excluded Application Support file, like the
/// conversation pins (`CacheStoreProtection`). The file holds command previews
/// (already redacted client-side) and audit lines. It never holds a sudo,
/// secret, or clarify ANSWER value: those types have no such field.
///
/// Caps are enforced on every save and on load, so the file cannot grow past
/// `InboxLedger.maxAuditRecords` audit lines or `InboxLedger.auditRetention`
/// of history, and terminal items are bounded by `InboxLedger.maxTerminalItems`.
///
/// Load is fail-soft: a missing or undecodable file yields `.empty`, so a
/// damaged inbox file never blocks the app from starting.
public actor FileInboxHistoryStore: InboxHistoryStoring {
    public static let fileName = "fleet-approval-inbox.json"

    private let url: URL
    private let now: @Sendable () -> Date

    public init(url: URL = FileInboxHistoryStore.defaultURL(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(fileName)
    }

    public func load() async -> InboxPersistedState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        BackupExclusion.apply(to: url) // files written before exclusion existed
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(InboxPersistedState.self, from: data) else {
            return .empty
        }
        return bounded(decoded)
    }

    public func save(_ state: InboxPersistedState) async throws {
        let data = try JSONEncoder().encode(bounded(state))
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

    /// Apply the retention rules: audit by count and age, history by count.
    private func bounded(_ state: InboxPersistedState) -> InboxPersistedState {
        let current = now()
        let audit = InboxLedger.retainedAudit(state.audit, now: current)
        let ledger = InboxLedger(items: state.items)
        let items = ledger.ordered.filter { item in
            // Terminal items older than the audit window are not worth keeping.
            item.status == .pending || current.timeIntervalSince(item.updatedAt) <= InboxLedger.auditRetention
        }
        return InboxPersistedState(items: items, audit: audit)
    }
}
