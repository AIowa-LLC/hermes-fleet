import Foundation

/// S3 (B2) — private/loopback host classifier for the cleartext-warning gate.
///
/// The gateway form must warn before saving an `http://` endpoint whose host
/// is NOT a private or loopback address (a password would travel unencrypted
/// to a public address). This is the pure, network-free classifier the UI
/// consumes: it takes a host string and answers "is this provably private or
/// loopback?".
///
/// Classified private/loopback:
///   - RFC1918 IPv4: 10/8, 172.16/12, 192.168/16
///   - IPv4 loopback: 127/8
///   - IPv6 loopback: ::1
///   - mDNS names: `.local` suffix (bonjour/mDNS link-local names)
///   - the literal `localhost` hostname
///
/// Everything else — public IPv4, and bare hostnames that would resolve later
/// (e.g. `gateway.example.com`) — is NOT private. The conservative default for
/// an unresolvable bare hostname is "not private" (the warning shows) because
/// we cannot prove it is private without a DNS lookup. This helper never
/// performs network I/O and is fully unit-testable.
public enum PrivateNetwork {

    /// Returns `true` when `host` is provably private or loopback.
    ///
    /// The host is expected as it appears in a URL (`url.host`), i.e. without
    /// scheme or port. It is matched case-insensitively after trimming
    /// surrounding whitespace and a single trailing dot (FQDN form).
    public static func isPrivateOrLoopbackHost(_ host: String) -> Bool {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // FQDN form "hermes.local." — strip one trailing dot before matching.
        if h.hasSuffix(".") { h.removeLast() }

        guard !h.isEmpty else { return false }

        // Literal localhost name.
        if h == "localhost" { return true }

        // mDNS / Bonjour link-local names.
        if h.hasSuffix(".local") { return true }

        // IPv6 loopback — only the ::1 forms qualify (RFC 4291).
        if h.contains(":") {
            return h == "::1" || h == "0:0:0:0:0:0:0:1"
        }

        // IPv4 classification (RFC1918 + loopback).
        return isPrivateIPv4(h)
    }

    // MARK: - IPv4

    /// Strict IPv4 classification: exactly four decimal octets in 0...255,
    /// then RFC1918 / loopback range checks. Rejects malformed input.
    private static func isPrivateIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }

        var parts: [Int] = []
        for octet in octets {
            // Strict decimal parse — no signs, no leading "+", no empty parts.
            guard !octet.isEmpty, let value = Int(octet), value >= 0, value <= 255,
                  String(value) == octet else {
                return false
            }
            parts.append(value)
        }

        let a = parts[0], b = parts[1]

        // Loopback 127/8.
        if a == 127 { return true }
        // RFC1918 10/8.
        if a == 10 { return true }
        // RFC1918 172.16/12 → 172.16...172.31.
        if a == 172 && b >= 16 && b <= 31 { return true }
        // RFC1918 192.168/16.
        if a == 192 && b == 168 { return true }

        return false
    }
}
