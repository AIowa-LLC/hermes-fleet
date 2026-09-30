import Foundation
import Security
import os

/// First-launch Keychain hygiene (P0.3d).
///
/// Keychain items outlive app deletion, but `UserDefaults` and the app sandbox
/// do not. Without intervention a reinstalled app silently inherits the gateway
/// credentials, tokens, TLS pins and first-use approvals of the deleted
/// install, which contradicts the privacy statement that deleting the app
/// removes its local data.
///
/// The purge must NOT run on an ordinary app update, which also has no marker
/// the first time a build containing this code launches. The two cases are told
/// apart by sandbox evidence supplied by the composition root:
///
/// - **Fresh install / reinstall**: the sandbox is empty, so there is no marker
///   and no prior local state. Keychain items in the app's service namespaces
///   can only be leftovers, so they are deleted and the marker is set.
/// - **Upgrade from a build without this feature**: there is no marker, but the
///   sandbox already holds state written by earlier launches (the composition
///   root passes `hasPriorInstallEvidence: true`). Nothing is deleted; the
///   marker is simply adopted so later launches take the fast path.
///
/// Decision order (first match wins):
/// 1. marker present -> skip;
/// 2. a previous purge failed part-way (`purgePending`) -> purge again, even if
///    the sandbox now looks used, because the failed attempt's own launch may
///    have created local state;
/// 3. prior-install evidence present -> adopt marker, skip;
/// 4. otherwise -> purge, then set the marker.
///
/// The marker is only written after every delete succeeded (or found nothing),
/// so a failed purge is retried on the next launch. Nothing that identifies an
/// account, gateway or host is ever logged; only the number of removed items.
public struct KeychainInstallHygiene {
    public enum Outcome: Equatable, Sendable {
        /// The marker was already present; nothing was touched.
        case skippedMarkerPresent
        /// Existing install upgraded in place; marker adopted, Keychain untouched.
        case adoptedExistingInstall
        /// Fresh install: `count` leftover items were deleted, marker set.
        case purged(count: Int)
        /// A Keychain call failed; the marker is NOT set and the purge retries next launch.
        case purgeFailed(status: Int32)
    }

    /// Keychain service namespaces owned by the app. First-use approvals live
    /// in the TLS pin namespace (`approval:<gateway>` accounts).
    public static let defaultServices: [String] = [
        KeychainCredentialStore.serviceName,
        KeychainTokenStore.serviceName,
        KeychainPinStore.serviceName,
    ]

    /// `UserDefaults` key recording that this install has been reconciled with
    /// the Keychain. Deleted together with the app.
    public static let markerFlagName = "com.aiowa.hermesfleet.keychain-install-marker.v1"
    /// Set before a purge and cleared on success; survives a failed attempt.
    public static let purgePendingFlagName = "com.aiowa.hermesfleet.keychain-purge-pending.v1"

    private static let log = Logger(subsystem: "com.aiowa.hermesfleet", category: "keychain-hygiene")

    private let keychain: any KeychainSession
    private let defaults: UserDefaults
    private let services: [String]

    public init(
        keychain: any KeychainSession = LiveKeychainSession(),
        defaults: UserDefaults = .standard,
        services: [String] = KeychainInstallHygiene.defaultServices
    ) {
        self.keychain = keychain
        self.defaults = defaults
        self.services = services
    }

    /// Runs the check. Idempotent; call once at launch, before any code reads
    /// a credential, token or pin.
    ///
    /// - Parameter hasPriorInstallEvidence: true when the app sandbox already
    ///   contains state created by an earlier launch of this app (see the type
    ///   documentation). Must be computed BEFORE this launch creates its own
    ///   local state.
    @discardableResult
    public func runIfNeeded(hasPriorInstallEvidence: Bool) -> Outcome {
        if defaults.bool(forKey: Self.markerFlagName) {
            return .skippedMarkerPresent
        }
        if !defaults.bool(forKey: Self.purgePendingFlagName), hasPriorInstallEvidence {
            defaults.set(true, forKey: Self.markerFlagName)
            Self.log.info("keychain hygiene: existing install adopted, no purge")
            return .adoptedExistingInstall
        }

        defaults.set(true, forKey: Self.purgePendingFlagName)
        var removed = 0
        for service in services {
            switch purge(service: service) {
            case .success(let count):
                removed += count
            case .failure(let failure):
                Self.log.error("keychain hygiene: purge failed status=\(failure.status, privacy: .public)")
                return .purgeFailed(status: failure.status)
            }
        }
        defaults.set(true, forKey: Self.markerFlagName)
        defaults.removeObject(forKey: Self.purgePendingFlagName)
        Self.log.info("keychain hygiene: fresh install purge removed \(removed, privacy: .public) item(s)")
        return .purged(count: removed)
    }

    private struct PurgeFailure: Error { let status: Int32 }

    private func purge(service: String) -> Result<Int, PurgeFailure> {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]

        // Count first (attributes only, never secret data) so the log can
        // report how much was removed without naming anything.
        var listQuery = match
        listQuery[kSecReturnAttributes as String] = true
        listQuery[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let listStatus = keychain.copyMatching(listQuery as CFDictionary, &result)
        let count: Int
        switch listStatus {
        case errSecSuccess:
            count = (result as? [Any])?.count ?? 0
        case errSecItemNotFound:
            return .success(0)
        default:
            return .failure(PurgeFailure(status: listStatus))
        }

        let deleteStatus = keychain.delete(match as CFDictionary)
        switch deleteStatus {
        case errSecSuccess, errSecItemNotFound:
            return .success(count)
        default:
            return .failure(PurgeFailure(status: deleteStatus))
        }
    }
}

/// Keeps a failed first-launch purge from accepting new credentials that the
/// next purge would erase. Every store in the production graph shares this
/// session; the first operation after Keychain becomes available retries the
/// reconciliation before reading or writing. The lock also prevents another
/// store from adding an item between namespace deletion and marker creation.
public final class InstallReconciledKeychainSession: KeychainSession, @unchecked Sendable {
    private let keychain: any KeychainSession
    private let hygiene: KeychainInstallHygiene
    private let hasPriorInstallEvidence: Bool
    private let lock = NSLock()

    public init(
        keychain: any KeychainSession = LiveKeychainSession(),
        defaults: UserDefaults = .standard,
        hasPriorInstallEvidence: Bool
    ) {
        self.keychain = keychain
        self.hygiene = KeychainInstallHygiene(keychain: keychain, defaults: defaults)
        self.hasPriorInstallEvidence = hasPriorInstallEvidence
    }

    @discardableResult
    public func reconcile() -> KeychainInstallHygiene.Outcome {
        lock.withLock { hygiene.runIfNeeded(hasPriorInstallEvidence: hasPriorInstallEvidence) }
    }

    private func access(_ operation: () -> OSStatus) -> OSStatus {
        lock.withLock {
            if case .purgeFailed(let status) = hygiene.runIfNeeded(hasPriorInstallEvidence: hasPriorInstallEvidence) {
                return status
            }
            return operation()
        }
    }

    public func add(_ query: CFDictionary) -> OSStatus {
        access { keychain.add(query) }
    }

    public func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        access { keychain.update(query, attributesToUpdate) }
    }

    public func delete(_ query: CFDictionary) -> OSStatus {
        access { keychain.delete(query) }
    }

    public func copyMatching(_ query: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus {
        result = nil
        return access { keychain.copyMatching(query, &result) }
    }
}
