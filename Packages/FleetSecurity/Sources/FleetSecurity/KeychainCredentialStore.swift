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
    public static let serviceName = "com.aiowa.hermesfleet.gateway-credentials"

    private let keychain: any KeychainSession

    public init() {
        self.keychain = LiveKeychainSession()
    }

    /// Injectable `KeychainSession` (tests only — CI hermetic, no live
    /// keychain). Production callers use `init()`.
    init(keychain: any KeychainSession) {
        self.keychain = keychain
    }

    // MARK: CredentialStoring

    public func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
        let account = gatewayID.rawValue
        let data = CredentialEncoding.encode(credential)
        // P2-4: atomic upsert — SecItemUpdate when present, SecItemAdd only
        // when not found. NEVER delete-then-add: a failed replacement must
        // not lose the working credential.
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
                throw CredentialStoreError.unexpectedStatus(Int(addStatus))
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(Int(updateStatus))
        }
    }

    public func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
        let account = gatewayID.rawValue
        var query = Self.baseAttributes(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = keychain.copyMatching(query as CFDictionary, &result)
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
        // P2-4: a failed delete must propagate — never silently ignored
        // (a suppressed failure leaves a secret behind while UI/registry
        // report it absent). Missing item is a no-op.
        let status = keychain.delete(Self.baseAttributes(account: gatewayID.rawValue) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw CredentialStoreError.unexpectedStatus(Int(status))
        }
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
}
