import Foundation

/// What happened when the on-device cache store could not be opened normally
/// and the app recovered (P0.4b). Produced by `FleetPersistence`, consumed by
/// the composition root and UI, so it lives in `FleetCore` (the UI must not
/// import persistence).
///
/// **Type-only by construction.** No path, hostname, gateway name or error
/// message is carried: `failureType` is a Swift type name and everything else
/// is a closed enum or a count. That makes `diagnosticsDetail` safe to hand to
/// the redacted diagnostics ring verbatim.
public struct LocalCacheRecoveryReport: Sendable, Equatable {
    /// How the session ended up with a usable store.
    public enum Outcome: String, Sendable, Equatable {
        /// The old store files were moved into the protected `Quarantine/`
        /// directory and a fresh file-backed store was created.
        case quarantinedAndRebuilt
        /// The old files could not be quarantined (or there were none) and
        /// were discarded before a fresh file-backed store was created.
        case discardedAndRebuilt
        /// No file-backed store could be created; this session runs from an
        /// in-memory store and nothing is persisted.
        case inMemoryFallback
        /// The store files exist but are not readable right now (device
        /// locked / protected data unavailable). They were left untouched and
        /// this session runs in memory.
        case storeLockedInMemory
    }

    /// What became of the saved-gateway registry rows.
    public enum RegistryOutcome: Sendable, Equatable {
        /// No rows to carry over (nothing was in the old store, or the store
        /// was not touched).
        case nothingToRestore
        /// Rows were read from the old store and re-inserted.
        case salvaged(count: Int)
        /// The registry rows could not be read from the old store.
        case lost
    }

    /// User-facing, non-blocking notices this recovery implies.
    public enum Notice: Sendable, Equatable {
        /// Saved gateways could not be restored; the user re-adds them and
        /// re-enters credentials. One-time and dismissible.
        case savedGatewaysNeedReadding
        /// This session has no persistent local cache. Persistent while true.
        case runningWithoutLocalCache
    }

    public let outcome: Outcome
    public let registry: RegistryOutcome
    /// Swift type name of the error that made the normal open fail
    /// (e.g. `"NSError"`); never the error's message.
    public let failureType: String

    public init(outcome: Outcome, registry: RegistryOutcome, failureType: String) {
        self.outcome = outcome
        self.registry = registry
        self.failureType = failureType
    }

    public var notices: [Notice] {
        var result: [Notice] = []
        if registry == .lost { result.append(.savedGatewaysNeedReadding) }
        switch outcome {
        case .inMemoryFallback, .storeLockedInMemory:
            result.append(.runningWithoutLocalCache)
        case .quarantinedAndRebuilt, .discardedAndRebuilt:
            break
        }
        return result
    }

    /// One-line, type-only description for the diagnostics ring.
    public var diagnosticsDetail: String {
        let outcomeText: String
        switch outcome {
        case .quarantinedAndRebuilt: outcomeText = "old store quarantined, fresh store created"
        case .discardedAndRebuilt: outcomeText = "old store discarded, fresh store created"
        case .inMemoryFallback: outcomeText = "no file-backed store available, running in memory"
        case .storeLockedInMemory: outcomeText = "store unreadable (protected data), left untouched, running in memory"
        }
        let registryText: String
        switch registry {
        case .nothingToRestore: registryText = "no saved gateways to restore"
        case .salvaged(let count): registryText = "saved gateways restored (\(count))"
        case .lost: registryText = "saved gateways lost"
        }
        return "local cache store could not be opened (\(failureType)); \(outcomeText); \(registryText)"
    }
}
