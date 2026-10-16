import Foundation
import Security
import FleetCore

/// Stores the temporary phone identity needed to safely retry an interrupted
/// owner enrollment. Items are device-only Keychain values and are removed
/// after the normal gateway credential has been committed.
public struct KeychainOwnerEnrollmentIdentityStore: OwnerEnrollmentIdentityStoring {
    public static let serviceName = FleetAppIdentity.keychainNamespace + ".owner-enrollment-pending"

    private let keychain: any KeychainSession

    public init() { keychain = LiveKeychainSession() }
    public init(keychain: any KeychainSession) { self.keychain = keychain }

    public func loadIdentity(for endpointID: GatewayID) async throws -> PendingOwnerDeviceIdentity? {
        var query = Self.baseAttributes(account: endpointID.rawValue)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch keychain.copyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data,
                  let raw = String(data: data, encoding: .utf8),
                  let identity = Self.decode(raw) else { throw CredentialStoreError.malformedData }
            return identity
        case errSecItemNotFound: return nil
        case let status: throw CredentialStoreError.unexpectedStatus(Int(status))
        }
    }

    public func saveIdentity(_ identity: PendingOwnerDeviceIdentity, for endpointID: GatewayID) async throws {
        let data = Data("\(identity.deviceID).\(identity.secret)".utf8)
        let match = Self.baseAttributes(account: endpointID.rawValue)
        let update = keychain.update(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            let status = keychain.add(add as CFDictionary)
            guard status == errSecSuccess else { throw CredentialStoreError.unexpectedStatus(Int(status)) }
        } else if update != errSecSuccess {
            throw CredentialStoreError.unexpectedStatus(Int(update))
        }
    }

    public func deleteIdentity(for endpointID: GatewayID) async throws {
        let status = keychain.delete(Self.baseAttributes(account: endpointID.rawValue) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(Int(status))
        }
    }

    public static func baseAttributes(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static func decode(_ raw: String) -> PendingOwnerDeviceIdentity? {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 32,
              parts[0].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              parts[1].count == 43,
              parts[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return PendingOwnerDeviceIdentity(deviceID: String(parts[0]), secret: String(parts[1]))
    }
}
