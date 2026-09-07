import Foundation
import FleetCore

/// Serialization shared by the credential stores (Keychain + in-memory).
///
/// The stores keep ONE item per gateway (synthesis §12 GenericPassword,
/// per-gateway). Two shapes map onto that single item:
/// - token strategies: the raw token bytes (legacy encoding — unchanged, so
///   previously-stored tokens keep loading).
/// - `.usernamePassword`: a versioned composite (username + password) so the
///   login flow can present both halves without a second store seam.
///
/// The composite prefix never appears in server-minted tokens (opaque
/// base64url/session strings), so legacy decode is unambiguous.
enum CredentialEncoding {
    static let compositePrefix = "hermescredv1:"

    struct Composite: Codable, Sendable {
        let username: String
        let password: String
    }

    /// Encode a credential to the bytes the store persists.
    static func encode(_ credential: GatewayCredential) -> Data {
        guard let username = credential.username else {
            // Legacy token-only shape.
            return Data(credential.rawValue.utf8)
        }
        let composite = Composite(username: username, password: credential.rawValue)
        // Codable payload of two Strings cannot fail; force is safe here.
        // The JSON bytes ride behind the prefix so decode is unambiguous.
        let payload = try! JSONEncoder().encode(composite)
        let utf8 = String(data: payload, encoding: .utf8)!
        return Data((compositePrefix + utf8).utf8)
    }

    /// Decode stored bytes back to a credential. Throws `.malformedData`
    /// when the bytes are not valid UTF-8 / a broken composite.
    static func decode(_ data: Data) throws -> GatewayCredential {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.malformedData
        }
        if text.hasPrefix(compositePrefix) {
            let json = String(text.dropFirst(compositePrefix.count))
            guard let payload = json.data(using: .utf8),
                  let composite = try? JSONDecoder().decode(Composite.self, from: payload),
                  !composite.username.isEmpty else {
                throw CredentialStoreError.malformedData
            }
            return GatewayCredential(rawValue: composite.password, username: composite.username)
        }
        guard !text.isEmpty else {
            throw CredentialStoreError.malformedData
        }
        return GatewayCredential(rawValue: text)
    }
}
