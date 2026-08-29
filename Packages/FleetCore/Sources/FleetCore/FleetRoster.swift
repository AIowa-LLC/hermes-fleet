import Foundation

/// The union fleet roster: registered gateways + every bot on them, with each
/// bot's owning gateway preserved (synthesis §7, spec §12).
///
/// Routing rule: bots are keyed by full `Route` — a bare profile slug is never
/// sufficient to address one. `bot(for:)` returns exactly one bot for an exact
/// route and `nil` otherwise (fail closed); it can never misroute a
/// same-named profile from another gateway.
public struct FleetRoster: Sendable, Equatable {
    public private(set) var gateways: [GatewayID: FleetGateway]
    public private(set) var bots: [Route: FleetBot]

    public init(gateways: [FleetGateway] = [], bots: [FleetBot] = []) {
        self.gateways = Dictionary(uniqueKeysWithValues: gateways.map { ($0.id, $0) })
        self.bots = Dictionary(uniqueKeysWithValues: bots.map { ($0.route, $0) })
    }

    // MARK: mutation

    public mutating func upsertGateway(_ gateway: FleetGateway) {
        gateways[gateway.id] = gateway
    }

    public mutating func removeGateway(_ id: GatewayID) {
        gateways.removeValue(forKey: id)
        // Removing a gateway invalidates every route that referenced it.
        bots = bots.filter { $0.key.gatewayID != id }
    }

    public mutating func upsertBot(_ bot: FleetBot) {
        // M9 fail-closed ingest: an unsafe route (path traversal, `#`,
        // separators) is never inserted — it must not become a routable bot
        // even when a gateway reports it. Mirrors the `setBots` guard.
        guard bot.route.isRoutingSafe else { return }
        bots[bot.route] = bot
    }

    /// Replace (or seed) the bot set for one gateway from its profile list.
    ///
    /// M9 fail-closed ingest: a descriptor whose slug is not a safe routing
    /// key (path traversal, `#`, separators) is DROPPED rather than ingested —
    /// an unsafe slug must never become a routable bot route.
    public mutating func setBots(on gatewayID: GatewayID, from descriptors: [ProfileDescriptor]) {
        for route in bots.keys where route.gatewayID == gatewayID {
            bots.removeValue(forKey: route)
        }
        for descriptor in descriptors {
            guard descriptor.slug.isRoutingSafe else { continue }
            let bot = FleetBot.bot(on: gatewayID, descriptor: descriptor)
            bots[bot.route] = bot
        }
    }

    // MARK: routing (fail closed)

    /// Exactly one bot for an exact `(gateway, profile)` route, or `nil`.
    ///
    /// Because the route includes the gateway ID, `A/default` and `B/default`
    /// resolve to different entries — a collision can never misroute.
    public func bot(for route: Route) -> FleetBot? {
        bots[route]
    }

    /// Resolve a bare profile slug to the single bot it addresses, FAILING
    /// CLOSED on ambiguity (spec §5.6, §36).
    ///
    /// A slug alone is not a unique resource — it can exist on many gateways.
    /// This is the ONLY API that accepts a bare slug, and it never guesses:
    /// when the slug matches bots on two or more gateways it returns
    /// `.ambiguous` (with the candidate routes) instead of picking one; when
    /// it matches exactly one it returns `.resolved`; when none, `.notFound`;
    /// and when the slug itself is not a safe routing key (path traversal,
    /// `#` separator, etc.) it returns `.invalid` — M9.
    public func resolve(profileSlug: ProfileSlug) -> RouteResolution {
        guard profileSlug.isRoutingSafe else {
            return .invalid("profile slug is not a safe routing key: \(profileSlug.rawValue)")
        }
        let matches = bots.values
            .map(\.route)
            .filter { $0.profileSlug == profileSlug }
            .sorted()
        switch matches.count {
        case 0: return .notFound
        case 1: return .resolved(matches[0])
        default: return .ambiguous(matches)
        }
    }

    /// Resolve a display name to a bot WITHOUT ever substituting it for a
    /// routing slug (spec §31 Profiles: "display name is never substituted
    /// for routing slug").
    ///
    /// Display names are presentation-only and need not be unique. This API
    /// fails closed on ambiguity exactly like `resolve(profileSlug:)`: two
    /// bots sharing a display name across gateways yield `.ambiguous`, never
    /// a guessed single route.
    public func resolve(displayName: String) -> RouteResolution {
        let matches = bots.values
            .filter { $0.displayName == displayName }
            .map(\.route)
            .sorted()
        switch matches.count {
        case 0: return .notFound
        case 1: return .resolved(matches[0])
        default: return .ambiguous(matches)
        }
    }

    /// All bots owned by one gateway, in route order.
    public func bots(on gatewayID: GatewayID) -> [FleetBot] {
        bots.values
            .filter { $0.route.gatewayID == gatewayID }
            .sorted { $0.route < $1.route }
    }

    /// The registered gateway for an ID, or `nil`.
    public func gateway(for id: GatewayID) -> FleetGateway? {
        gateways[id]
    }

    /// All gateways in stable ID order.
    public var allGateways: [FleetGateway] {
        gateways.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// All bots across all gateways, in route order.
    public var allBots: [FleetBot] {
        bots.values.sorted { $0.route < $1.route }
    }
}

/// The result of resolving a bare slug or display name to a route (M9).
///
/// Routing never guesses: a slug that exists on multiple gateways is
/// `.ambiguous` (candidate routes listed) rather than silently pinned to one
/// owner; an unsafe routing key is `.invalid` rather than interpreted.
public enum RouteResolution: Sendable, Equatable, CustomStringConvertible {
    /// No bot matches the requested identifier.
    case notFound
    /// The requested identifier is not a safe routing key (path traversal,
    /// `#`, separators) — the caller must not interpret it (fail closed).
    case invalid(String)
    /// Exactly one bot matches — the unique route.
    case resolved(Route)
    /// More than one bot matches on different gateways — ambiguous, never a
    /// guess. The candidate routes are listed so the caller can ask the user
    /// which gateway they meant.
    case ambiguous([Route])

    public var description: String {
        switch self {
        case .notFound: return "notFound"
        case .invalid(let reason): return "invalid(\(reason))"
        case .resolved(let route): return "resolved(\(route.id))"
        case .ambiguous(let routes): return "ambiguous(\(routes.map(\.id).joined(separator: ", ")))"
        }
    }
}
