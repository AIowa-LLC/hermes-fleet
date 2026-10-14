import Foundation

/// Fetches the public-key fingerprint a secure endpoint ACTUALLY presents,
/// without sending any request content or credentials. The handshake is
/// abandoned as soon as the key has been observed.
public protocol TLSKeyProbing: Sendable {
    func presentedKey(for endpoint: URL) async throws -> SPKIFingerprint
}

/// The result of showing the user the key a secure gateway presented.
///
/// A review is bound to ONE endpoint (normalized origin) and ONE key. It is the
/// only thing that can authorize first-use pinning: the approval stored from it
/// matches that exact key, so a different key (key rotated or swapped between
/// the review and the first real connection) never pins. Reviews expire, and
/// an endpoint edit makes them stale.
public struct TLSKeyReview: Sendable, Equatable {
    /// How long a displayed fingerprint stays confirmable.
    public static let maxAge: TimeInterval = 5 * 60

    public let endpoint: URL
    public let fingerprint: SPKIFingerprint
    public let reviewedAt: Date

    public init(endpoint: URL, fingerprint: SPKIFingerprint, reviewedAt: Date = Date()) {
        self.endpoint = endpoint
        self.fingerprint = fingerprint
        self.reviewedAt = reviewedAt
    }

    /// Full SHA-256 of the key's SubjectPublicKeyInfo as colon-separated hex,
    /// for comparison against a trusted source (never abbreviated here).
    public var displayFingerprint: String {
        fingerprint.sha256Digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Validate this review for use with `endpoint` right now. Fails closed.
    public func validate(for endpoint: URL, now: Date = Date()) throws {
        guard let current = try? GatewayEndpoint.normalizedOrigin(from: endpoint),
              Self.sameOrigin(current, self.endpoint) else {
            throw TLSKeyReviewError.endpointChanged
        }
        let age = now.timeIntervalSince(reviewedAt)
        guard age >= 0, age <= Self.maxAge else { throw TLSKeyReviewError.stale }
    }

    /// Scheme, host and port must match exactly; case-insensitive for scheme/host.
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String {
            let scheme = url.scheme?.lowercased() ?? ""
            let port = url.port ?? (scheme == "https" ? 443 : 80)
            var path = url.path
            if path.hasSuffix("/") { path.removeLast() }
            return "\(scheme)://\(url.host?.lowercased() ?? ""):\(port)\(path)"
        }
        return key(a) == key(b)
    }
}

public enum TLSKeyReviewError: Error, Sendable, Equatable, LocalizedError {
    /// A secure endpoint needs its presented key reviewed and confirmed first.
    case required
    /// The confirmation is older than `TLSKeyReview.maxAge`.
    case stale
    /// The endpoint changed after the key was displayed.
    case endpointChanged
    /// The endpoint did not present a usable key.
    case probeFailed

    public var errorDescription: String? {
        switch self {
        case .required: return "Review and confirm this gateway's certificate fingerprint before connecting."
        case .stale: return "The certificate review expired. Review the fingerprint again."
        case .endpointChanged: return "The address changed after the certificate was reviewed. Review it again."
        case .probeFailed: return "Could not read a certificate from this address."
        }
    }
}
