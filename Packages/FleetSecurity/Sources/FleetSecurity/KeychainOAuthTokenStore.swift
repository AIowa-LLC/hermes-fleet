import Foundation
import Security
import FleetCore

/// Keychain-backed `OAuthTokenStoring` (spec §16; synthesis §12:
/// GenericPassword, per-gateway, `WhenUnlockedThisDeviceOnly`, no iCloud
/// sync).
///
/// Persistence uses a private JSON envelope — `OAuthTokenPair` itself is
/// not `Codable`, so it cannot leak into SwiftData / files / logs.
public struct KeychainOAuthTokenStore: OAuthTokenStoring {
    public static let serviceName = "com.aiowa.hermesfleet.oauth-tokens"

    private let keychain: any KeychainSession

    public init() {
        self.keychain = LiveKeychainSession()
    }

    /// Injectable `KeychainSession` (tests only — CI hermetic, no live
    /// keychain). Production callers use `init()`.
    init(keychain: any KeychainSession) {
        self.keychain = keychain
    }

    public func saveTokenPair(_ pair: OAuthTokenPair, for gatewayID: GatewayID) async throws {
        let data = try Envelope.encode(pair)
        let match = Self.baseAttributes(account: gatewayID.rawValue)
        let updateStatus = keychain.update(
            match as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var query = Self.baseAttributes(account: gatewayID.rawValue)
            query[kSecValueData as String] = data
            let addStatus = keychain.add(query as CFDictionary)
            guard addStatus == errSecSuccess else {
                throw OAuthTokenStoreError.unexpectedStatus(Int(addStatus))
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw OAuthTokenStoreError.unexpectedStatus(Int(updateStatus))
        }
    }

    public func loadTokenPair(for gatewayID: GatewayID) async throws -> OAuthTokenPair? {
        var query = Self.baseAttributes(account: gatewayID.rawValue)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = keychain.copyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw OAuthTokenStoreError.malformedData
            }
            return try Envelope.decode(data)
        case errSecItemNotFound:
            return nil
        default:
            throw OAuthTokenStoreError.unexpectedStatus(Int(status))
        }
    }

    public func deleteTokenPair(for gatewayID: GatewayID) async throws {
        let status = keychain.delete(Self.baseAttributes(account: gatewayID.rawValue) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw OAuthTokenStoreError.unexpectedStatus(Int(status))
        }
    }

    /// Public so the app-level boundary test can assert the exact security
    /// attributes without touching a live keychain.
    public static func baseAttributes(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// Private JSON envelope — never a public Codable on `OAuthTokenPair`.
    private struct Envelope: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Int
        let provider: String
        let userId: String

        static func encode(_ pair: OAuthTokenPair) throws -> Data {
            try JSONEncoder().encode(Envelope(
                accessToken: pair.accessToken,
                refreshToken: pair.refreshToken,
                expiresAt: pair.expiresAt,
                provider: pair.provider,
                userId: pair.userId
            ))
        }

        static func decode(_ data: Data) throws -> OAuthTokenPair {
            let envelope: Envelope
            do {
                envelope = try JSONDecoder().decode(Envelope.self, from: data)
            } catch {
                throw OAuthTokenStoreError.malformedData
            }
            return OAuthTokenPair(
                accessToken: envelope.accessToken,
                refreshToken: envelope.refreshToken,
                expiresAt: envelope.expiresAt,
                provider: envelope.provider,
                userId: envelope.userId
            )
        }
    }
}
