import Foundation
import Security
import CryptoKit
import FleetCore

/// SPKI SHA-256 fingerprint of a certificate's public key (RFC 7469 pin), for
/// extension-safe one-shot calls.
///
/// FleetNetworking owns the same computation for the app's long-lived transport
/// (`SPKIExtractor`, internal). Extension-facing code may not import
/// FleetNetworking, so this is a deliberately small, independent implementation
/// validated against the same known-answer vectors (see `SPKIPinningTests`).
/// The pin is the SHA-256 of the DER SubjectPublicKeyInfo; raw key bytes from
/// `SecKeyCopyExternalRepresentation` lack the SPKI header, so it is rebuilt per
/// key type. Unsupported or malformed keys return nil (fail closed).
public enum SPKIPinExtractor {
    public static func fingerprint(from certificate: SecCertificate) -> SPKIFingerprint? {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        return fingerprint(from: key)
    }

    public static func fingerprint(from key: SecKey) -> SPKIFingerprint? {
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(key, &error) as Data?,
              let algorithm = algorithmIdentifier(for: key, rawByteCount: raw.count) else {
            return nil
        }
        var bitString: [UInt8] = [0x03]
        bitString.append(contentsOf: derLength(raw.count + 1))
        bitString.append(0x00) // no unused bits
        bitString.append(contentsOf: raw)

        var spki: [UInt8] = [0x30]
        spki.append(contentsOf: derLength(algorithm.count + bitString.count))
        spki.append(contentsOf: algorithm)
        spki.append(contentsOf: bitString)
        return SPKIFingerprint(sha256Digest: Data(SHA256.hash(data: Data(spki))))
    }

    private static func algorithmIdentifier(for key: SecKey, rawByteCount: Int) -> [UInt8]? {
        let attributes = SecKeyCopyAttributes(key) as? [String: Any]
        let keyType = attributes?[kSecAttrKeyType as String] as? String
        let keySize = attributes?[kSecAttrKeySizeInBits as String] as? Int ?? 0
        let ecType = kSecAttrKeyTypeECSECPrimeRandom as String
        let rsaType = kSecAttrKeyTypeRSA as String

        // id-ecPublicKey 1.2.840.10045.2.1
        let ecPublicKey: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        switch (keyType, keySize) {
        case (ecType, 256):
            guard rawByteCount == 65 else { return nil }
            // secp256r1 1.2.840.10045.3.1.7
            return derSequence(ecPublicKey + [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        case (ecType, 384):
            guard rawByteCount == 97 else { return nil }
            // secp384r1 1.3.132.0.34
            return derSequence(ecPublicKey + [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22])
        case (ecType, 521):
            guard rawByteCount == 133 else { return nil }
            // secp521r1 1.3.132.0.35
            return derSequence(ecPublicKey + [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x23])
        case (rsaType, let bits) where (2048...4096).contains(bits):
            // rsaEncryption 1.2.840.113549.1.1.1 + NULL parameters
            let rsaEncryption: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
            return derSequence(rsaEncryption + [0x05, 0x00])
        default:
            return nil
        }
    }

    private static func derSequence(_ content: [UInt8]) -> [UInt8] {
        [0x30] + derLength(content.count) + content
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [UInt8(0x80 | bytes.count)] + bytes
    }
}

/// The verdict of a one-shot pin check.
public enum PinVerdict: Sendable, Equatable {
    case matched
    /// No pin is stored for this gateway. One-shot calls never trust on first
    /// use: only the app's interactive connection flow may create a pin.
    case noPinStored
    case mismatch
    /// The pin store failed or the key was unsupported (fail closed).
    case unavailable
}

/// Verify-only SPKI pin check against a `SynchronousPinStoring`.
///
/// Unlike the app's TOFU evaluator this NEVER writes a pin and never accepts an
/// unpinned certificate.
public struct PinVerifier: Sendable {
    public let gatewayID: GatewayID
    private let pinStore: any SynchronousPinStoring

    public init(gatewayID: GatewayID, pinStore: any SynchronousPinStoring) {
        self.gatewayID = gatewayID
        self.pinStore = pinStore
    }

    public func verdict(forCertificate certificate: SecCertificate) -> PinVerdict {
        guard let presented = SPKIPinExtractor.fingerprint(from: certificate) else {
            return .unavailable
        }
        let expected: SPKIFingerprint?
        do {
            expected = try pinStore.syncLoadPin(for: gatewayID)
        } catch {
            return .unavailable
        }
        guard let expected else { return .noPinStored }
        return presented == expected ? .matched : .mismatch
    }

    public func verdict(forServerTrust trust: SecTrust) -> PinVerdict {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return .unavailable
        }
        return verdict(forCertificate: leaf)
    }
}

/// A read-only pin store for callers that hold pins from another channel (for
/// example a pin carried in a payload). Saving or deleting throws: one-shot and
/// extension code must not mutate trust.
public struct FixedPinStore: SynchronousPinStoring {
    private let pins: [GatewayID: SPKIFingerprint]

    public init(pins: [GatewayID: SPKIFingerprint]) {
        self.pins = pins
    }

    public func syncSavePin(_ pin: SPKIFingerprint, for gatewayID: GatewayID) throws {
        throw PinStoreError.unexpectedStatus(Int(errSecWrPerm))
    }

    public func syncLoadPin(for gatewayID: GatewayID) throws -> SPKIFingerprint? {
        pins[gatewayID]
    }

    public func syncDeletePin(for gatewayID: GatewayID) throws {
        throw PinStoreError.unexpectedStatus(Int(errSecWrPerm))
    }
}
