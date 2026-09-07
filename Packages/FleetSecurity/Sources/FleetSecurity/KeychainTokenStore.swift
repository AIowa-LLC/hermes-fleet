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
    public static let serviceName = "com.aiowa.hermesfleet.tokens"

    private let keychain: any KeychainSession

    public init() {
        self.keychain = LiveKeychainSession()
    }

    /// Injectable `KeychainSession` (tests only — CI hermetic, no live
    /// keychain). Production callers use `init()`.
    init(keychain: any KeychainSession) {
        self.keychain = keychain
    }

    // MARK: TokenStoring

    public func saveToken(_ token: StoredToken, for gatewayID: GatewayID) async throws {
        let account = gatewayID.rawValue
        let data = Data(token.rawValue.utf8)
        // P2-4: atomic upsert — SecItemUpdate when present, SecItemAdd only
        // when not found. NEVER delete-then-add: a failed replacement must
        // not lose the working token.
        let match = Self.baseAttributes(account: account)
        let updateStatus = keychain.update(
            match as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var query = Self.baseAttributes(account: account)
            query[kSecValueData as String] = data
            let addStatus = keychain.add(query as CFDictionary)
            guard addStatus == errSecSuccess else {
                throw TokenStoreError.unexpectedStatus(Int(addStatus))
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw TokenStoreError.unexpectedStatus(Int(updateStatus))
        }
    }

    public func loadToken(for gatewayID: GatewayID) async throws -> StoredToken? {
        let account = gatewayID.rawValue
        var query = Self.baseAttributes(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = keychain.copyMatching(query as CFDictionary, &result)
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
        // P2-4: a failed delete must propagate — never silently ignored.
        // Missing item is a no-op.
        let status = keychain.delete(Self.baseAttributes(account: gatewayID.rawValue) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw TokenStoreError.unexpectedStatus(Int(status))
        }
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
}
