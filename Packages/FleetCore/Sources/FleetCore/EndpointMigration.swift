import Foundation

/// F2 (t_b678fb38) — one-time endpoint convergence for the HTTPS tunnel.
///
/// Every persisted gateway row created before the tunnel pointed at a private
/// network spelling of the same Arch gateway: LAN IP, tailnet IP, MagicDNS
/// hostname, or loopback (the old compiled default). Those spellings are dead
/// on the public path and — worse — the raw-IP forms were compiled into the
/// app binary as ATS exceptions, leaking Tony's home network topology into
/// every shipped IPA. F2 strips those exceptions, so EVERY spelling of those
/// hosts (any port — the 8642 relay era AND the 9119 direct era) must be
/// re-pointed or the row would silently fail ATS.
///
/// `migrateEndpoints(in:defaultEndpoint:)` re-points persisted rows off every
/// dead host onto the configured default endpoint. The replacement address
/// arrives as DATA (the caller reads it from configuration), never as compiled
/// topology — this type knows the DEAD hosts (historical facts about this
/// fleet, required to catch them) but not the live address.
///
/// Pure and network-free: the caller performs the store writes, so the
/// mapping is fully unit-testable (F2 contract: idempotent, identity and
/// display name preserved, unknown endpoints untouched).
public enum EndpointMigration {

    /// Dead private-network HOSTS this fleet has used for the Arch gateway.
    /// Matched on the URL host (any port, any cleartext scheme) so both the
    /// old :8642 relay spellings and the F1-era :9119 direct spellings are
    /// caught. Historical fleet facts, not live topology — the live address
    /// is never compiled in.
    public static let deadHosts: Set<String> = [
        "<lan-ip>",                    // Arch LAN IP
        "<tailnet-ip>",                  // Arch tailnet IP
        "<private-host>",   // Arch MagicDNS host
        "127.0.0.1",                       // compiled loopback default
        "localhost",                       // loopback by name
    ]

    /// The result of one row's migration decision.
    public enum Outcome: Equatable, Sendable {
        /// Row pointed at a dead host — re-point it to the default endpoint.
        case migrated
        /// Row already points at the default endpoint (idempotent re-run).
        case alreadyCurrent
        /// Row points somewhere unknown — left EXACTLY as-is (the user may
        /// run other gateways; migration never rewrites what it does not
        /// recognize).
        case untouched
    }

    /// Extract the comparable, lowercased host from an endpoint string
    /// (trailing FQDN dot stripped). Nil for unparseable endpoints.
    static func host(of endpoint: String) -> String? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let rawHost = url.host else {
            return nil
        }
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// Decide one endpoint's migration outcome against `defaultEndpoint`.
    public static func classify(endpoint: String, defaultEndpoint: String) -> Outcome {
        guard let current = host(of: endpoint),
              let target = host(of: defaultEndpoint) else { return .untouched }
        if current == target { return .alreadyCurrent }
        if deadHosts.contains(current) { return .migrated }
        return .untouched
    }

    /// Map persisted gateway records onto the default endpoint, rewriting
    /// every row whose host matches a dead spelling. The written endpoint is
    /// the trimmed `defaultEndpoint` verbatim (single canonical spelling).
    /// Idempotent (rows already on the default are unchanged); rows with
    /// unrecognized endpoints pass through verbatim; identity (`id`) and
    /// display name are always preserved.
    ///
    /// P0-9 strategy alignment: a `.loopbackToken` row being re-pointed onto
    /// the public tunnel gets its strategy migrated to `.usernamePassword`.
    /// Loopback-token auth is a trusted-private-network strategy — `?token=`
    /// on the socket — and the converged tunnel rejects it outright (403,
    /// QA-verified live). Leaving it would strand the row in a strategy that
    /// can never authenticate; the tunnel's only working path is the
    /// username/password cookie flow. Token strategies (`.sessionToken` /
    /// `.bearerToken`) are left to their honest failure copy — a future
    /// gateway may legitimately accept them, and the ws-ticket 401
    /// "no_cookie" rejection now surfaces cause-specific guidance.
    public static func migrateEndpoints(
        in records: [StoredGatewayRecord],
        defaultEndpoint: String
    ) -> [StoredGatewayRecord] {
        let trimmed = defaultEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, host(of: trimmed) != nil else { return records }
        return records.map { record in
            switch classify(endpoint: record.endpoint, defaultEndpoint: trimmed) {
            case .migrated:
                var updated = record
                updated.endpoint = trimmed
                if updated.authConfiguration.strategy == .loopbackToken {
                    updated.authConfiguration.strategy = .usernamePassword
                }
                return updated
            case .alreadyCurrent, .untouched:
                return record
            }
        }
    }
}
