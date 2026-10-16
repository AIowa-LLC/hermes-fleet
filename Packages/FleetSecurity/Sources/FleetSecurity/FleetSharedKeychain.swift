import Foundation
import Security

/// The closed set of secrets that may live in the SHARED keychain access group.
///
/// F3 (extension kit): the shared group exists for one reason — a
/// Notification Service Extension running on a locked-after-first-unlock device
/// must be able to read the per-install push private key so it can open the
/// sealed payload. Nothing else belongs here. Gateway credentials, tokens, and
/// TLS pins stay in their app-private stores (`KeychainCredentialStore`,
/// `KeychainTokenStore`, `KeychainPinStore`), which never set an access group.
///
/// The set is a closed enum on purpose: `FleetSharedKeychain` cannot be asked to
/// store an arbitrary account name, so a gateway secret cannot be moved into the
/// shared group by accident.
public enum FleetSharedKeychainItem: String, Sendable, CaseIterable {
    /// The X25519 private key for sealed push payloads (created by the app,
    /// read by the Notification Service Extension).
    case pushPrivateKey = "push-private-key"
}

/// Errors a `FleetSharedKeychain` surfaces. None carry secret material.
public enum FleetSharedKeychainError: Error, Sendable, Equatable, LocalizedError {
    /// The binary is not entitled to the requested keychain access group
    /// (`errSecMissingEntitlement`). The app resolves this at launch: when the
    /// shared groups are not enabled for this build it never asks for a group.
    case missingEntitlement
    /// The stored item exists but is empty / not data.
    case malformedData
    /// An empty access-group string was supplied (would silently mean "none").
    case invalidAccessGroup
    /// The underlying Security call failed (OSStatus numeric only).
    case unexpectedStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .missingEntitlement: return "shared keychain access group is not enabled for this build"
        case .malformedData: return "stored shared keychain item is malformed"
        case .invalidAccessGroup: return "shared keychain access group is invalid"
        case .unexpectedStatus(let code): return "shared keychain error (status \(code))"
        }
    }
}

/// Keychain storage for the push key, in a keychain access group shared between
/// the app and its extensions.
///
/// Safety invariants:
/// - Only `FleetSharedKeychainItem` accounts can be stored (push key only).
/// - Accessibility is `AfterFirstUnlockThisDeviceOnly`: a locked-device NSE can
///   read it after the first unlock following boot, it is excluded from
///   backups/device migration, and it is not synchronizable to iCloud.
///   (Contrast: the app-private stores use `WhenUnlockedThisDeviceOnly`.)
/// - `accessGroup == nil` means "no shared group for this build": the item is
///   then stored in the app's own default keychain group with the same
///   accessibility. That is the fallback used while the shared-group
///   entitlement is not enabled (see `docs/extension-kit.md`); extensions do
///   not exist in that configuration, so nothing is lost.
/// - Atomic upsert: `SecItemUpdate` when present, `SecItemAdd` only when not
///   found; never delete-then-add.
/// - Errors are numeric/typed; values never reach logs or descriptions.
public struct FleetSharedKeychain: Sendable {
    /// Keychain service name — a dedicated namespace distinct from the
    /// credential, token, and pin services.
    public static let serviceName = "com.aiowa.hermesfleet.shared.push"

    public let accessGroup: String?
    private let keychain: any KeychainSession

    /// Production initializer. Pass the resolved access group, or nil when the
    /// shared group is not enabled for this build.
    public init(accessGroup: String?) {
        self.accessGroup = accessGroup
        self.keychain = LiveKeychainSession()
    }

    /// Injectable `KeychainSession` (tests only — CI hermetic).
    init(accessGroup: String?, keychain: any KeychainSession) {
        self.accessGroup = accessGroup
        self.keychain = keychain
    }

    public func save(_ data: Data, item: FleetSharedKeychainItem) throws {
        let match = try baseAttributes(for: item)
        let updateStatus = keychain.update(
            match as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var query = match
            query[kSecValueData as String] = data
            let addStatus = keychain.add(query as CFDictionary)
            guard addStatus == errSecSuccess else { throw Self.map(addStatus) }
            return
        }
        guard updateStatus == errSecSuccess else { throw Self.map(updateStatus) }
    }

    public func load(item: FleetSharedKeychainItem) throws -> Data? {
        var query = try baseAttributes(for: item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = keychain.copyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else {
                throw FleetSharedKeychainError.malformedData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw Self.map(status)
        }
    }

    public func delete(item: FleetSharedKeychainItem) throws {
        let status = keychain.delete(try baseAttributes(for: item) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw Self.map(status)
        }
    }

    // MARK: query building (exposed for tests; no secret material)

    /// The Keychain base attributes for a shared item. `accessGroup` adds
    /// `kSecAttrAccessGroup`; nil omits it (app-private fallback).
    public static func baseAttributes(
        item: FleetSharedKeychainItem,
        accessGroup: String?
    ) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: item.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            attributes[kSecAttrAccessGroup as String] = accessGroup
        }
        return attributes
    }

    private func baseAttributes(for item: FleetSharedKeychainItem) throws -> [String: Any] {
        if let accessGroup, accessGroup.isEmpty {
            throw FleetSharedKeychainError.invalidAccessGroup
        }
        return Self.baseAttributes(item: item, accessGroup: accessGroup)
    }

    private static func map(_ status: OSStatus) -> FleetSharedKeychainError {
        status == errSecMissingEntitlement
            ? .missingEntitlement
            : .unexpectedStatus(Int(status))
    }
}
