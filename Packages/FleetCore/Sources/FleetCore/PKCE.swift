import Foundation
import CryptoKit

/// RFC 7636 PKCE (Proof Key for Code Exchange) for the gateway-brokered
/// native OAuth flow (RFC 8252). Only S256 is supported — the gateway
/// rejects any other `code_challenge_method`.
///
/// The verifier is high-entropy and never logged. The challenge is
/// derived deterministically from the verifier.
public enum PKCE {
    /// Cryptographically random code verifier (43–128 chars, base64url
    /// no-pad). 96 bytes → 128 chars is 768 bits of entropy.
    public static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 96)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fallback that still produces high-entropy bytes if the CSPRNG
            // call fails (should not happen on a supported OS).
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return Data(bytes).base64URLEncodedString()
    }

    /// S256 code challenge: `BASE64URL(SHA256(verifier))`.
    public static func codeChallengeS256(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

extension Data {
    /// Base64URL encode without padding (RFC 4648 §5).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
