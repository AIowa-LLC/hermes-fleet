import Foundation
import Security
import FleetCore

/// Keychain-backed `CredentialStoring` (spec §16: "Secrets belong in
/// Keychain"; synthesis §12: GenericPassword, per-gateway, accessibility
/// `WhenUnlockedThisDeviceOnly`, no iCloud sync).
///
/// Safety invariants:
/// - The secret is stored only in the Keychain (GenericPassword, service
///   scoped per gateway). It is never written to files, logs, or user
///   defaults, and never surfaced in `description`/errors.
/// - Accessibility is `WhenUnlockedThisDeviceOnly` (no backup, no sync).
/// - The account name is the gateway ID; the service name is the app-scoped
///   Keychain service, so gateways from different profiles never collide.
public struct KeychainCredentialStore: CredentialStoring {
    /// Keychain service name — scoped to this app's gateway credentials.
    public static let serviceName = "<legacy-personal-bundle-id>.gateway-credentials"

    public init() {}

    // MARK: CredentialStoring

    public func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
        let account = gatewayID.rawValue
        // Delete any existing item first (idempotent upsert).
        deleteItem(account: account)
        let data = CredentialEncoding.encode(credential)
        var query = Self.baseAttributes(account: account)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(Int(status))
        }
    }

    public func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
        let account = gatewayID.rawValue
        var query = Self.baseAttributes(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw CredentialStoreError.malformedData
            }
            return try CredentialEncoding.decode(data)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.unexpectedStatus(Int(status))
        }
    }

    public func deleteCredential(for gatewayID: GatewayID) async throws {
        deleteItem(account: gatewayID.rawValue)
    }

    // MARK: query building (exposed for tests; no secret material)

    /// The Keychain base attributes for a gateway credential. Public so the
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
