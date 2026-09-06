import Foundation

/// F2 — QR-code gateway pairing payload (v1).
///
/// The canonical format encoded into the pairing QR shown by the Hermes
/// gateway surface (Mac/WebUI). One scan of the code yields everything the
/// Add-Gateway form needs: the gateway endpoint plus a short-lived scoped
/// credential.
///
/// SECURITY MODEL (F2 card):
/// - The QR image IS credential material on screen. The gateway side must
///   generate a SHORT-LIVED, scoped credential, show the QR only on explicit
///   user action, and regenerate per pairing. This type carries the result;
///   it enforces neither lifetime nor scope (the gateway owns that).
/// - The payload is JSON with a `v` version field so the scanner can evolve
///   the format without ambiguity. Unknown versions are a clean parse error,
///   not a best-effort guess.
/// - Transport is scanned-over-the-shoulder (camera). The secret is inside
///   the payload by design; the app must never log the encoded JSON.
public struct PairingPayload: Sendable, Equatable, Codable {
    /// Payload format version. v1 = url + username + password.
    public static let currentVersion = 1

    /// Format version discriminator.
    public let v: Int
    /// Gateway endpoint origin (e.g. `http://192.168.50.37:8642`).
    public let url: String
    /// Username half of the scoped pairing credential.
    public let username: String
    /// Password/token half of the scoped pairing credential.
    public let password: String

    public init(v: Int = PairingPayload.currentVersion, url: String, username: String, password: String) {
        self.v = v
        self.url = url
        self.username = username
        self.password = password
    }

    public enum DecodeError: Error, Equatable, Sendable {
        /// The scanned data was not valid UTF-8 / JSON.
        case malformedData
        /// Valid JSON but not a pairing payload shape.
        case notAPairingPayload
        /// A pairing payload from a future format version.
        case unsupportedVersion(Int)
        /// A structurally valid payload with an empty required field.
        case emptyField
    }

    /// Encode to the compact JSON string that gets rendered into the QR.
    ///
    /// Sorted keys + no whitespace keeps the code small. The output contains
    /// the secret — never log it.
    public func encoded() -> String {
        var json = String()
        json += "{\"password\":"
        json += Self.quote(password)
        json += ",\"url\":"
        json += Self.quote(url)
        json += ",\"username\":"
        json += Self.quote(username)
        json += ",\"v\":"
        json += String(v)
        json += "}"
        return json
    }

    /// Parse a scanned QR string into a payload.
    ///
    /// Accepts the compact encoder output as well as any JSON object with the
    /// same keys (a gateway may emit via its own JSON encoder). Version must
    /// be exactly `v1` — future versions are rejected as unsupported rather
    /// than misread.
    public static func decode(_ text: String) throws -> PairingPayload {
        guard let data = text.data(using: .utf8) else { throw DecodeError.malformedData }
        let decoded: PairingPayload
        do {
            decoded = try JSONDecoder().decode(PairingPayload.self, from: data)
        } catch {
            // Distinguish "wrong shape" from "future version": try again
            // looking only at the version field. A KNOWN version with missing
            // fields is a shape problem, not a version problem.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = obj["v"] as? Int,
               version != currentVersion {
                throw DecodeError.unsupportedVersion(version)
            }
            throw DecodeError.notAPairingPayload
        }
        guard decoded.v == currentVersion else {
            throw DecodeError.unsupportedVersion(decoded.v)
        }
        guard !decoded.url.isEmpty, !decoded.username.isEmpty, !decoded.password.isEmpty else {
            throw DecodeError.emptyField
        }
        return decoded
    }

    /// Minimal JSON string quoting (mirrors JSONEncoder's escaping rules for
    /// the characters that can appear in endpoints and credentials).
    private static func quote(_ raw: String) -> String {
        var out = "\""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
