import Foundation
import Security

/// The per-gateway `relay_key_id` the app generates for push registration.
///
/// Contract (relay + gateway plugin, see the push registration design, #89):
/// - random with at least 128 bits, rendered as unpadded base64url, 22...64
///   characters; a different value for every gateway;
/// - the app registers the device token with the relay using it, then sends the
///   same value to the gateway plugin as `key_id`;
/// - it is a secret shared only with that gateway (the relay uses it as a
///   possession check): never log it, never put it in a snapshot, never share
///   it across gateways, and keep it in app-private storage (not the shared
///   keychain group).
///
/// 32 random bytes (256 bits, 43 characters) are generated; `isValid` accepts
/// anything the contract allows.
public enum RelayKeyID {
    public static let minimumLength = 22
    public static let maximumLength = 64
    private static let randomByteCount = 32

    /// A fresh random key id. Fails closed (returns nil) only if the system
    /// random source fails.
    public static func generate() -> String? {
        var bytes = [UInt8](repeating: 0, count: randomByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }
        return encode(Data(bytes))
    }

    /// True when `value` is an unpadded base64url string within the contract
    /// length bounds.
    public static func isValid(_ value: String) -> Bool {
        guard (minimumLength...maximumLength).contains(value.count) else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"):
                return true
            default:
                return false
            }
        }
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
