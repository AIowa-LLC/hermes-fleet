import Foundation
import Security
import FleetCore

/// Keychain-backed `TLSPinStoring` (T3: trust-on-first-use SPKI pinning).
///
/// Stores the expected SPKI SHA-256 pin per peer gateway as a GenericPassword
/// in a DEDICATED service namespace (`com.aiowa.hermesfleet.tlspins`),
/// mirroring `KeychainTokenStore`'s safety invariants:
/// - accessibility `WhenUnlockedThisDeviceOnly`, no iCloud sync;
/// - atomic upsert — `SecItemUpdate` when present, `SecItemAdd` only when
///   not found; NEVER delete-then-add (a failed replacement must not lose
///   the working pin);
/// - delete failures propagate; a missing item is a no-op;
/// - errors carry no secret material (the pin is public key material
///   anyway, but store errors stay typed/numeric).
public struct KeychainPinStore: TLSPinStoring, SynchronousPinStoring {
    /// Keychain service name — scoped to this app's TLS pin store (separate
    /// from credentials and tokens so pin lifecycle never collides).
    public static let serviceName = "com.aiowa.hermesfleet.tlspins"

    private let keychain: any KeychainSession

    public init() {
        self.keychain = LiveKeychainSession()
    }

    /// Injectable `KeychainSession` (tests only — CI hermetic, no live
    /// keychain). Production callers use `init()`.
    init(keychain: any KeychainSession) {
        self.keychain = keychain
    }

    // MARK: TLSPinStoring

    public func savePin(_ pin: SPKIFingerprint, for gatewayID: GatewayID) async throws {
        try syncSavePin(pin, for: gatewayID)
    }

    public func loadPin(for gatewayID: GatewayID) async throws -> SPKIFingerprint? {
        try syncLoadPin(for: gatewayID)
    }

    public func deletePin(for gatewayID: GatewayID) async throws {
        try syncDeletePin(for: gatewayID)
    }

    // MARK: SynchronousPinStoring (URLSession challenge callback bridge)

    public func syncSavePin(_ pin: SPKIFingerprint, for gatewayID: GatewayID) throws {
        let account = gatewayID.rawValue
        let data = Data(pin.base64String.utf8)
        // Atomic upsert: update when present, add only when not found.
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
                throw PinStoreError.unexpectedStatus(Int(addStatus))
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw PinStoreError.unexpectedStatus(Int(updateStatus))
        }
    }

    public func syncLoadPin(for gatewayID: GatewayID) throws -> SPKIFingerprint? {
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
                  let pin = SPKIFingerprint(base64: value) else {
                throw PinStoreError.malformedData
            }
            return pin
        case errSecItemNotFound:
            return nil
        default:
            throw PinStoreError.unexpectedStatus(Int(status))
        }
    }

    public func syncDeletePin(for gatewayID: GatewayID) throws {
        let status = keychain.delete(Self.baseAttributes(account: gatewayID.rawValue) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw PinStoreError.unexpectedStatus(Int(status))
        }
    }

    // MARK: query building (exposed for tests; no secret material)

    /// The Keychain base attributes for a peer TLS pin. Public so the
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
