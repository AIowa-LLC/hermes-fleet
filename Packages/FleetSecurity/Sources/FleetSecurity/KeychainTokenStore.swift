import Foundation
import Security
import FleetCore

/// Keychain-backed `TokenStoring` (spec §16: "Secrets belong in Keychain";
/// synthesis §12: tokens/tickets are GenericPassword, per-peer, accessibility
/// `WhenUnlockedThisDeviceOnly`, no iCloud sync).
///
/// Safety invariants (mirrors `KeychainCredentialStore`, M7):
/// - The token is stored only in the Keychain (GenericPassword, service
///   scoped per peer gateway). It is never written to files, logs, or user
///   defaults, and never surfaced in `description`/errors.
/// - Accessibility is `WhenUnlockedThisDeviceOnly` (no backup, no sync).
/// - The account name is the peer gateway ID; the service name is the
///   app-scoped Keychain service, so peers from different profiles never
///   collide.
public struct KeychainTokenStore: TokenStoring {
    /// Keychain service name — scoped to this app's token/ticket store.
    public static let serviceName = "<legacy-personal-bundle-id>.tokens"

    public init() {}

    // MARK: TokenStoring

    public func saveToken(_ token: StoredToken, for gatewayID: GatewayID) async throws {
        let account = gatewayID.rawValue
        // Delete any existing item first (idempotent upsert).
        deleteItem(account: account)
        let data = Data(token.rawValue.utf8)
        var query = Self.baseAttributes(account: account)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TokenStoreError.unexpectedStatus(Int(status))
        }
    }

    public func loadToken(for gatewayID: GatewayID) async throws -> StoredToken? {
        let account = gatewayID.rawValue
        var query = Self.baseAttributes(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty else {
                throw TokenStoreError.malformedData
            }
            return StoredToken(rawValue: value)
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStoreError.unexpectedStatus(Int(status))
        }
    }

    public func deleteToken(for gatewayID: GatewayID) async throws {
        deleteItem(account: gatewayID.rawValue)
    }

    // MARK: query building (exposed for tests; no secret material)

    /// The Keychain base attributes for a peer token. Public so the
    /// app-level boundary test can assert the exact security attributes
    /// (WhenUnlockedThisDeviceOnly, no sync) without touching a live keychain.
    public static func baseAttributes(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func deleteItem(account: String) {
        SecItemDelete(Self.baseAttributes(account: account) as CFDictionary)
    }
}
