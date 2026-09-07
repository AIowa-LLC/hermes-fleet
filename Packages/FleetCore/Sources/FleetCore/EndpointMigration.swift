import Foundation

/// F2 (t_b678fb38) — LEGACY one-time endpoint convergence mapping.
///
/// Historical context: persisted gateway rows created before the fleet's
/// HTTPS convergence pointed at private-network spellings of one specific
/// legacy gateway (LAN IP, tailnet IP, MagicDNS hostname, or the old
/// compiled loopback default). The original F2 pass re-pointed those rows
/// onto a configured default endpoint.
///
/// PUBLIC-RELEASE CONTRACT (Issue #2 review): this mapping is LEGACY
/// MIGRATION, not generic private-endpoint rewriting. Hermes Fleet
/// explicitly supports user-owned LAN/tailnet/loopback gateways, so the
/// migration must only ever run when a caller deliberately requests legacy
/// state migration (see `GatewayRegistryService` — the runner is gated
/// behind an explicit opt-in flag that is OFF by default). With the flag
/// absent, every persisted row — private, tailnet, or public — survives
/// restore verbatim.
///
/// Dead-host classification is SHAPE-based (loopback/RFC1918 via
/// `PrivateNetwork`, RFC 6598 CGNAT, `*.ts.net` MagicDNS names): no private
/// network values are compiled into this module, and no public host is ever
/// classified dead.
///
/// Pure and network-free: the caller performs the store writes, so the
/// mapping is fully unit-testable (contract: idempotent, identity and
/// display name preserved, public endpoints untouched).
public enum EndpointMigration {

    /// Private-network HOST shapes eligible for LEGACY migration: loopback
    /// names, RFC1918/tailnet IPs, and Tailscale MagicDNS `*.ts.net` names.
    /// Matched on the URL host (any port, any scheme). Public hosts are
    /// NEVER dead — rows pointing at any public endpoint the user configured
    /// survive migration untouched. This classification is only consulted
    /// when legacy migration has been explicitly enabled by the caller.
    public static func isDeadHost(_ host: String) -> Bool {
        PrivateNetwork.isPrivateOrLoopbackHost(host)
            || isCarrierGradeNATIPv4(host)
            || host.lowercased().hasSuffix(".ts.net")
    }

    /// RFC 6598 carrier-grade NAT (100.64.0.0/10) — the IPv4 block Tailscale
    /// assigns tailnet addresses from. Strict four-octet decimal parse
    /// (mirrors `PrivateNetwork.isPrivateIPv4`): exactly four non-empty
    /// decimal octets, each 0...255, no signs, no leading zeros/whitespace —
    /// anything else (hostnames, malformed IPv4) is rejected.
    static func isCarrierGradeNATIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        var parts: [Int] = []
        for octet in octets {
            guard !octet.isEmpty,
                  let value = Int(octet),
                  value >= 0, value <= 255,
                  String(value) == octet else { return false }
            parts.append(value)
        }
        return parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127
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

    /// Decide one endpoint's LEGACY migration outcome against
    /// `defaultEndpoint`. Only meaningful when the caller has explicitly
    /// enabled legacy migration.
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
    /// LEGACY ONLY: callers must gate this behind an explicit legacy
    /// migration opt-in (never a bare "a default endpoint is configured").
    ///
    /// P0-9 strategy alignment: a `.loopbackToken` row being re-pointed onto
    /// the public tunnel gets its strategy migrated to `.usernamePassword`.
    /// Loopback-token auth is a trusted-private-network strategy — `?token=`
    /// on the socket — and a converged HTTPS endpoint rejects it outright
    /// (403, QA-verified live). Leaving it would strand the row in a strategy
    /// that can never authenticate; the tunnel's only working path is the
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
