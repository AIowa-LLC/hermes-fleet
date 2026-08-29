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
        bots[bot.route] = bot
    }

    /// Replace (or seed) the bot set for one gateway from its profile list.
    public mutating func setBots(on gatewayID: GatewayID, from descriptors: [ProfileDescriptor]) {
        for route in bots.keys where route.gatewayID == gatewayID {
            bots.removeValue(forKey: route)
        }
        for descriptor in descriptors {
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
