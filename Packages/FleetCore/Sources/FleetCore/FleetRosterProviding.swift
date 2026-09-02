import Foundation

/// The multi-gateway union roster seam (spec §31 Multi-Gateway, synthesis §13).
///
/// Mirrors the M0 seam pattern (`RosterProviding`, `GatewayConnectivityProviding`,
/// `GatewayRegistryManaging`): FleetUI and the app depend on this protocol —
/// never on the concrete `FleetRosterService` in FleetNetworking — so the UI
/// can present the union fleet roster without importing the transport module.
///
/// Partial-outage contract (spec §31 "one unavailable gateway does not break
/// another"; §13 "Fleet screen stays useful when partially available"):
/// `refreshRoster()` NEVER throws because one gateway is unreachable. Every
/// registered gateway is probed independently and its outcome is classified
/// into the snapshot; the union roster still contains the reachable gateways
/// and their bots. The caller inspects `gatewayOutcomes` to learn which
/// gateways failed and why (spec §30 error philosophy).
public protocol FleetRosterProviding: Sendable {
    /// Refresh the union fleet roster across every registered gateway.
    ///
    /// - Returns: a snapshot containing the union roster (every gateway with
    ///   its last-known connection state, plus bots from the gateways that
    ///   answered `profiles.list`) and a per-gateway `GatewayRosterOutcome`.
    ///   Never throws for a single-gateway outage.
    func refreshRoster() async -> FleetRosterSnapshot
}

/// The result of one fleet roster refresh across all registered gateways.
///
/// `roster` is the union: every registered gateway (with updated connection
/// state) plus the bots of every gateway that answered `profiles.list`,
/// keyed by full `Route` so identically-named profiles on two gateways stay
/// distinct (spec §31). `gatewayOutcomes` carries the per-gateway result so
/// the UI can say *which* gateway failed and *what else is still available*
/// (spec §30).
public struct FleetRosterSnapshot: Sendable, Equatable {
    /// The union roster: gateways + bots, keyed by `Route`.
    public var roster: FleetRoster
    /// Per-gateway result of this refresh (absent for an empty registry).
    public var gatewayOutcomes: [GatewayID: GatewayRosterOutcome]

    public init(
        roster: FleetRoster = FleetRoster(),
        gatewayOutcomes: [GatewayID: GatewayRosterOutcome] = [:]
    ) {
        self.roster = roster
        self.gatewayOutcomes = gatewayOutcomes
    }

    /// The refresh outcome for one gateway, or `nil` when it was not part of
    /// this refresh (fail closed).
    public func outcome(for id: GatewayID) -> GatewayRosterOutcome? {
        gatewayOutcomes[id]
    }

    /// Gateways that answered `profiles.list` in this refresh.
    public var reachableGateways: [FleetGateway] {
        roster.allGateways.filter { gateway in
            if case .loaded = gatewayOutcomes[gateway.id] { return true }
            return false
        }
    }

    /// Gateways that did not answer `profiles.list` (unreachable / auth /
    /// unsupported / degraded) — the §30 "which gateway failed" half.
    public var unreachableGateways: [FleetGateway] {
        roster.allGateways.filter { gateway in
            if case .loaded = gatewayOutcomes[gateway.id] { return false }
            return true
        }
    }

    /// Bots owned by one gateway, in route order (empty when the gateway is
    /// unreachable or absent — fail closed).
    public func bots(on id: GatewayID) -> [FleetBot] {
        roster.bots(on: id)
    }

    /// The single bot for an exact `(gateway, profile)` route, or `nil` (fail
    /// closed — a collision can never misroute).
    public func bot(for route: Route) -> FleetBot? {
        roster.bot(for: route)
    }

    /// P0-7 multiplexer presence: a bot is ONLINE (reachable) when the
    /// gateway that listed it answered `profiles.list` this refresh — the
    /// Hermes gateway is a profile MULTIPLEXER, so every profile it serves is
    /// chat-reachable through that one connection (`/p/<profile>/` routes).
    /// Presence therefore derives from the OWNING GATEWAY's roster outcome,
    /// never from a per-bot signal: a gateway that failed to answer has no
    /// reachable bots, and a gateway that answered has ALL its bots reachable.
    ///
    /// This is deliberately SEPARATE from `FleetBot.activity` (live bot work
    /// state) and from `gateway_running` (own-process badge): connection
    /// state, presence, and activity are three distinct concerns.
    public func botPresence(on id: GatewayID) -> BotPresence {
        guard roster.gateways[id] != nil else { return .unknown }
        switch gatewayOutcomes[id] {
        case .loaded: return .reachable
        case .failed: return .unreachable
        case nil: return .unknown
        }
    }

    /// Presence for one exact bot route (fail closed: an unknown route is
    /// `.unknown`, never guessed).
    public func botPresence(for route: Route) -> BotPresence {
        guard roster.bots[route] != nil else { return .unknown }
        return botPresence(on: route.gatewayID)
    }
}

/// P0-7: per-bot presence derived from the owning gateway's roster outcome
/// (the multiplexer model — see `FleetRosterSnapshot.botPresence(on:)`).
public enum BotPresence: String, Hashable, Sendable, Codable {
    /// The owning gateway answered `profiles.list` this refresh — the bot is
    /// chat-reachable through the multiplexer connection.
    case reachable
    /// The owning gateway failed to answer — the bot is not reachable.
    case unreachable
    /// No refresh has classified the owning gateway yet (fail closed).
    case unknown
}

/// The per-gateway result of a fleet roster refresh (spec §13 states).
///
/// A `loaded` outcome means `profiles.list` succeeded and the gateway's bots
/// are in the union roster. A `failed` outcome carries the classified §13
/// status (`GatewayStatus`) plus a non-secret detail, so the UI can render
/// "MacBook is unreachable. Researcher on 4090 and Revenue on Arch are still
/// available" (spec §30) without inventing state.
public enum GatewayRosterOutcome: Sendable, Equatable {
    /// `profiles.list` answered; `profileCount` bots stamped into the roster.
    case loaded(profileCount: Int)
    /// The gateway did not serve its roster. `status` is the §13
    /// classification; `detail` is a short non-secret reason.
    case failed(status: GatewayStatus, detail: String?)
}
