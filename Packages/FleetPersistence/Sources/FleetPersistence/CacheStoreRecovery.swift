import Foundation
import SwiftData
import FleetCore

/// The result of opening the file-backed cache with a recovery policy.
public struct CacheOpenResult: Sendable {
    public let store: SwiftDataCacheStore
    /// nil when the store opened normally (no recovery happened).
    public let recovery: LocalCacheRecoveryReport?
}

/// The only way `openWithRecovery` can fail: not even an in-memory store could
/// be built. Carries the report so the caller can still record diagnostics.
public struct CacheOpenError: Error, Sendable {
    public let report: LocalCacheRecoveryReport
}

/// Test hook that simulates cache-open failures without needing a genuinely
/// corrupt file. Production passes `[]`.
public struct CacheOpenFaultInjection: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The normal container open throws (simulated unreadable/corrupt store),
    /// while the files on disk stay intact.
    public static let unreadablePrimaryStore = CacheOpenFaultInjection(rawValue: 1 << 0)
    /// Creating the fresh file-backed store after quarantine throws.
    public static let freshFileBackedStore = CacheOpenFaultInjection(rawValue: 1 << 1)
    /// Building an in-memory store throws (the unrecoverable case).
    public static let inMemoryStore = CacheOpenFaultInjection(rawValue: 1 << 2)
    /// The store files read as unavailable (device locked).
    public static let protectedDataUnavailable = CacheOpenFaultInjection(rawValue: 1 << 3)
}

/// Stand-in error for injected faults (type name only ever surfaces).
struct InjectedCacheOpenFault: Error {}

/// A saved-gateway registry row copied out of an old store (plain values, so
/// it can cross the container boundary).
private struct SalvagedGatewayRow: Sendable {
    let gatewayID: String
    let displayName: String
    let endpoint: String
    let authStrategyRaw: String
    let credentialStored: Bool
    let authConfigured: Bool
}

public extension SwiftDataCacheStore {
    /// Name of the quarantine directory, a child of the store's own directory.
    /// The store directory itself is never removed or renamed (fresh-install
    /// detection relies on it existing); only files inside it move.
    static let quarantineDirectoryName = "Quarantine"

    /// Where quarantined store generations live for a store at `storeURL`.
    static func quarantineDirectory(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appendingPathComponent(quarantineDirectoryName, isDirectory: true)
    }

    /// Opens the file-backed cache, recovering instead of trapping or silently
    /// running unpersisted when it cannot be opened (P0.4b):
    ///
    /// 1. If the store files exist but are unreadable right now (device
    ///    locked), leave them untouched and run in memory. A locked device is
    ///    not corruption and must never cost the user their data.
    /// 2. Otherwise copy the saved-gateway registry rows out of the old files
    ///    (minimal-schema container over a scratch copy), then move the old
    ///    `.store` / `-wal` / `-shm` files into a protected, backup-excluded
    ///    `Quarantine/<timestamp>/` directory (one generation kept), create a
    ///    fresh store, and re-insert the salvaged rows.
    /// 3. If a fresh file-backed store cannot be created, fall back to an
    ///    in-memory store through a throwing path (no `try!`).
    ///
    /// Throws `CacheOpenError` only when not even an in-memory store can be
    /// built.
    static func openWithRecovery(
        storeURL: URL,
        faults: CacheOpenFaultInjection = [],
        now: Date = Date()
    ) throws -> CacheOpenResult {
        let container: ModelContainer
        do {
            if faults.contains(.unreadablePrimaryStore) { throw InjectedCacheOpenFault() }
            container = try openFileBackedContainer(storeURL: storeURL)
        } catch {
            return try recover(from: error, storeURL: storeURL, faults: faults, now: now)
        }
        let protectionFailures: [LocalFileProtection.Failure]
        do {
            try CacheStoreProtection.apply(to: storeURL)
            protectionFailures = CacheStoreProtection.protect(storeURL: storeURL)
        } catch {
            // The store is healthy but protection could not be applied. Never
            // run an unprotected transcript cache, and never quarantine a good
            // store for it: leave the files alone and run in memory.
            return try inMemoryResult(
                outcome: .inMemoryFallback, registry: .nothingToRestore, salvaged: [],
                failureType: typeName(error), faults: faults)
        }
        return CacheOpenResult(
            store: SwiftDataCacheStore(
                container: container, storeURL: storeURL, protectionFailures: protectionFailures),
            recovery: nil)
    }
}

// MARK: - Recovery implementation

private extension SwiftDataCacheStore {
    static func typeName(_ error: Error) -> String {
        String(describing: type(of: error))
    }

    static func storeFiles(_ storeURL: URL) -> [URL] {
        let base = storeURL.path
        let candidates = [storeURL, URL(fileURLWithPath: base + "-wal"), URL(fileURLWithPath: base + "-shm")]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func isReadable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    static func recover(
        from cause: Error,
        storeURL: URL,
        faults: CacheOpenFaultInjection,
        now: Date
    ) throws -> CacheOpenResult {
        let failureType = typeName(cause)
        let fm = FileManager.default
        let members = storeFiles(storeURL)

        // 1. Locked device: not corruption. Touch nothing.
        if faults.contains(.protectedDataUnavailable) || !members.allSatisfy(isReadable) {
            return try inMemoryResult(
                outcome: .storeLockedInMemory, registry: .nothingToRestore, salvaged: [],
                failureType: failureType, faults: faults)
        }

        let quarantineRoot = quarantineDirectory(for: storeURL)
        // Keep at most one quarantine generation. Clearing happens before the
        // new generation is created, and only inside `Quarantine/`.
        try? fm.removeItem(at: quarantineRoot)
        let quarantineReady = prepareProtectedDirectory(quarantineRoot)

        // 2a. Salvage the registry rows from a scratch copy so the original
        // files are never modified by the minimal-schema open.
        var salvage: [SalvagedGatewayRow]?
        if members.isEmpty {
            salvage = []
        } else if quarantineReady {
            salvage = salvageGatewayRows(members: members, storeURL: storeURL, quarantineRoot: quarantineRoot)
        }

        // 2b. Move (or, failing that, discard) the old files.
        var outcome: LocalCacheRecoveryReport.Outcome = .discardedAndRebuilt
        if quarantineReady, !members.isEmpty, quarantine(members: members, root: quarantineRoot, now: now) {
            outcome = .quarantinedAndRebuilt
        } else {
            for file in members { try? fm.removeItem(at: file) }
        }
        let leftovers = storeFiles(storeURL)

        // 3. Fresh file-backed store; else in-memory.
        let salvagedRows = salvage ?? []
        let registry: LocalCacheRecoveryReport.RegistryOutcome
        if salvage == nil {
            registry = .lost
        } else {
            registry = salvagedRows.isEmpty ? .nothingToRestore : .salvaged(count: salvagedRows.count)
        }

        if leftovers.isEmpty, !faults.contains(.freshFileBackedStore) {
            do {
                let container = try openFileBackedContainer(storeURL: storeURL)
                try CacheStoreProtection.apply(to: storeURL)
                let protectionFailures = CacheStoreProtection.protect(storeURL: storeURL)
                do {
                    try insert(salvagedRows, into: container)
                } catch {
                    return CacheOpenResult(
                        store: SwiftDataCacheStore(
                            container: container, storeURL: storeURL, protectionFailures: protectionFailures),
                        recovery: LocalCacheRecoveryReport(
                            outcome: outcome, registry: .lost, failureType: failureType))
                }
                return CacheOpenResult(
                    store: SwiftDataCacheStore(
                        container: container, storeURL: storeURL, protectionFailures: protectionFailures),
                    recovery: LocalCacheRecoveryReport(
                        outcome: outcome, registry: registry, failureType: failureType))
            } catch {
                // Fall through to in-memory.
            }
        }
        return try inMemoryResult(
            outcome: .inMemoryFallback, registry: registry, salvaged: salvagedRows,
            failureType: failureType, faults: faults)
    }

    /// Builds the in-memory fallback through a throwing path. Two attempts
    /// (the second with a uniquely named configuration); if both fail,
    /// throws `CacheOpenError` rather than trapping.
    static func inMemoryResult(
        outcome: LocalCacheRecoveryReport.Outcome,
        registry: LocalCacheRecoveryReport.RegistryOutcome,
        salvaged: [SalvagedGatewayRow],
        failureType: String,
        faults: CacheOpenFaultInjection
    ) throws -> CacheOpenResult {
        let report = LocalCacheRecoveryReport(outcome: outcome, registry: registry, failureType: failureType)
        guard !faults.contains(.inMemoryStore) else { throw CacheOpenError(report: report) }
        let attempts = [
            ModelConfiguration(isStoredInMemoryOnly: true),
            ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true),
        ]
        for configuration in attempts {
            guard let container = try? ModelContainer.fleetCache(configuration: configuration) else { continue }
            // Carry salvaged registry rows into the session; if that fails the
            // registry is reported lost rather than silently dropped.
            var finalRegistry = registry
            if (try? insert(salvaged, into: container)) == nil { finalRegistry = .lost }
            return CacheOpenResult(
                store: SwiftDataCacheStore(container: container),
                recovery: LocalCacheRecoveryReport(
                    outcome: outcome, registry: finalRegistry, failureType: failureType))
        }
        throw CacheOpenError(report: report)
    }

    static func insert(_ rows: [SalvagedGatewayRow], into container: ModelContainer) throws {
        guard !rows.isEmpty else { return }
        let ctx = ModelContext(container)
        for row in rows {
            ctx.insert(CachedGatewayRow(
                gatewayID: row.gatewayID,
                displayName: row.displayName,
                endpoint: row.endpoint,
                authStrategyRaw: row.authStrategyRaw,
                credentialStored: row.credentialStored,
                authConfigured: row.authConfigured))
        }
        try ctx.save()
    }

    /// Creates `url` (if needed) as a backup-excluded, file-protected directory.
    static func prepareProtectedDirectory(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try CacheStoreProtection.apply(to: url)
            return true
        } catch {
            return false
        }
    }

    static func timestampName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// Moves every store file into `Quarantine/<timestamp>/` and applies
    /// protection to the directory and each file. All-or-nothing: on any
    /// failure returns false and the caller discards what is left.
    static func quarantine(members: [URL], root: URL, now: Date) -> Bool {
        let generation = root.appendingPathComponent(timestampName(now), isDirectory: true)
        guard prepareProtectedDirectory(generation) else { return false }
        for file in members {
            let destination = generation.appendingPathComponent(file.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: file, to: destination)
                try CacheStoreProtection.apply(to: destination)
            } catch {
                return false
            }
        }
        return true
    }

    /// Reads `CachedGatewayRow`s from a scratch copy of the old files through
    /// a minimal-schema container. nil = the registry could not be read.
    static func salvageGatewayRows(
        members: [URL], storeURL: URL, quarantineRoot: URL
    ) -> [SalvagedGatewayRow]? {
        let fm = FileManager.default
        let scratch = quarantineRoot.appendingPathComponent("salvage-scratch", isDirectory: true)
        guard prepareProtectedDirectory(scratch) else { return nil }
        defer { try? fm.removeItem(at: scratch) }
        for file in members {
            let destination = scratch.appendingPathComponent(file.lastPathComponent)
            guard (try? fm.copyItem(at: file, to: destination)) != nil else { return nil }
            _ = try? CacheStoreProtection.apply(to: destination)
        }
        let scratchStore = scratch.appendingPathComponent(storeURL.lastPathComponent)
        // Scope the container so the store is closed before scratch removal.
        return {
            do {
                let container = try ModelContainer(
                    for: Schema([CachedGatewayRow.self]),
                    configurations: ModelConfiguration(url: scratchStore))
                let ctx = ModelContext(container)
                return try ctx.fetch(FetchDescriptor<CachedGatewayRow>()).map {
                    SalvagedGatewayRow(
                        gatewayID: $0.gatewayID, displayName: $0.displayName,
                        endpoint: $0.endpoint, authStrategyRaw: $0.authStrategyRaw,
                        credentialStored: $0.credentialStored, authConfigured: $0.authConfigured)
                }
            } catch {
                return nil
            }
        }()
    }
}
