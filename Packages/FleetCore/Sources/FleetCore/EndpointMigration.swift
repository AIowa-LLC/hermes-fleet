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
/// topology. Historically this type enumerated the fleet's literal dead hosts;
/// for public release it now classifies dead hosts by SHAPE (private/loopback
/// hosts via `PrivateNetwork`, plus tailnet `*.ts.net` names) — no private
/// network values are compiled into the module.
///
/// Pure and network-free: the caller performs the store writes, so the
/// mapping is fully unit-testable (F2 contract: idempotent, identity and
/// display name preserved, unknown endpoints untouched).
public enum EndpointMigration {

    /// Historically-dead private-network HOST classes this fleet used before
    /// user-owned HTTPS endpoints: loopback names, RFC1918/tailnet IPs, and
    /// Tailscale MagicDNS `*.ts.net` names. Matched on the URL host (any
    /// port, any scheme) via `PrivateNetwork` shape classification, so no
    /// real private network values are compiled into the module. Public
    /// hosts are NEVER dead — rows pointing at any public endpoint the user
    /// configured survive migration untouched.
    public static func isDeadHost(_ host: String) -> Bool {
        PrivateNetwork.isPrivateOrLoopbackHost(host)
            || isCarrierGradeNATIPv4(host)
            || host.lowercased().hasSuffix(".ts.net")
    }

    /// RFC 6598 carrier-grade NAT (100.64.0.0/10) — the IPv4 block Tailscale
    /// assigns tailnet addresses from. Strict four-octet decimal parse.
    private static func isCarrierGradeNATIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let a = Int(octets[0]), let b = Int(octets[1]),
              String(a) == octets[0], String(b) == octets[1] else { return false }
        return a == 100 && b >= 64 && b <= 127
    }

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
        if isDeadHost(current) { return .migrated }
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
