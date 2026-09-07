import Foundation
import Security
import CryptoKit
import FleetCore

/// T3 — derives the SPKI SHA-256 fingerprint (the TOFU pin) from a
/// `SecCertificate`.
///
/// The pin is the SHA-256 digest of the certificate's DER-encoded
/// SubjectPublicKeyInfo (RFC 7469 §2.4 pin computation; the same value
/// `openssl x509 -pubkey | openssl pkey -pubin -outform DER | openssl dgst
/// -sha256 -binary | base64` produces). Extracting via `SecCertificateCopyKey`
/// + `SecKeyCopyExternalRepresentation` yields the RAW key bytes for EC
/// (0x04 || X || Y), NOT the SPKI DER — so the DER header is reconstructed
/// per key type (EC P-256/P-384/P-521, RSA). This matches how the reference
/// clients (e.g. TrustKit) compute SPKI pins on Apple platforms.
enum SPKIExtractor {
    /// Compute the SPKI SHA-256 pin for a certificate's public key.
    /// Returns nil when the public key cannot be extracted or its algorithm
    /// is unsupported (fail closed — never pin a key we cannot identify).
    static func fingerprint(from certificate: SecCertificate) -> SPKIFingerprint? {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        return fingerprint(from: key)
    }

    /// Compute the SPKI SHA-256 pin for a public key.
    static func fingerprint(from key: SecKey) -> SPKIFingerprint? {
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            return nil
        }
        guard let algID = Self.algorithmIdentifier(for: key, rawByteCount: raw.count) else {
            return nil
        }
        // SPKI DER = SEQUENCE { AlgorithmIdentifier, BIT STRING { raw key } }.
        var bitString: [UInt8] = [0x03]
        bitString.append(contentsOf: Self.derLen(raw.count + 1))
        bitString.append(0x00) // no unused bits
        bitString.append(contentsOf: raw)

        var spki: [UInt8] = [0x30]
        spki.append(contentsOf: Self.derLen(algID.count + bitString.count))
        spki.append(contentsOf: algID)
        spki.append(contentsOf: bitString)
        return SPKIFingerprint(sha256Digest: Data(SHA256.hash(data: Data(spki))))
    }

    /// The full DER AlgorithmIdentifier for the key's algorithm, validated
    /// against the expected raw-key byte count (a mismatch means an
    /// unexpected key encoding — fail closed). Returns nil for unsupported
    /// key types.
    ///
    /// EC (RFC 5480): SEQUENCE { id-ecPublicKey, namedCurve OID } — the
    /// parameters are the curve OID, NOT NULL. RSA (RFC 3279):
    /// SEQUENCE { rsaEncryption, NULL }.
    private static func algorithmIdentifier(for key: SecKey, rawByteCount: Int) -> [UInt8]? {
        let attrs = SecKeyCopyAttributes(key) as? [String: Any]
        let keyType = attrs?[kSecAttrKeyType as String] as? String
        let keySize = attrs?[kSecAttrKeySizeInBits as String] as? Int ?? 0
        let ecType = kSecAttrKeyTypeECSECPrimeRandom as String
        let rsaType = kSecAttrKeyTypeRSA as String

        // id-ecPublicKey 1.2.840.10045.2.1
        let ecPublicKeyOID: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        // namedCurve OIDs (RFC 5480 §2.1.1.1)
        var namedCurve: [UInt8]? = nil
        switch (keyType, keySize) {
        case (ecType, 256):
            // secp256r1 1.2.840.10045.3.1.7; uncompressed point = 65 bytes
            guard rawByteCount == 65 else { return nil }
            namedCurve = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
        case (ecType, 384):
            // secp384r1 1.3.132.0.34
            guard rawByteCount == 97 else { return nil }
            namedCurve = [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22]
        case (ecType, 521):
            // secp521r1 1.3.132.0.35
            guard rawByteCount == 133 else { return nil }
            namedCurve = [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x23]
        case (rsaType, let bits) where (2048...4096).contains(bits):
            // rsaEncryption 1.2.840.113549.1.1.1 + NULL params
            let rsaOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
            return Self.derSequence(rsaOID + [0x05, 0x00])
        default:
            return nil
        }
        guard let curve = namedCurve else { return nil }
        return Self.derSequence(ecPublicKeyOID + curve)
    }

    /// Wrap content bytes in a DER SEQUENCE header.
    private static func derSequence(_ content: [UInt8]) -> [UInt8] {
        [0x30] + derLen(content.count) + content
    }

    /// DER length encoding (short form < 128, long form otherwise).
    private static func derLen(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [UInt8(0x80 | bytes.count)] + bytes
    }
}
