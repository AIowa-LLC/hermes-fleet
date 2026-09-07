import Foundation

/// A bot (profile) as it appears on a specific gateway.
///
/// A bot's canonical identity is its `route` — the exact `(GatewayID,
/// ProfileSlug)` pair. Two bots that share a profile slug on different
/// gateways are two distinct bots, exactly as the routing collision
/// requirement (synthesis §7, spec §36) demands.
public struct FleetBot: Identifiable, Hashable, Sendable {
    /// Canonical routing identity — never a display name.
    public let route: Route

    /// Routing slug (shorthand for `route.profileSlug`).
    public var profileSlug: ProfileSlug { route.profileSlug }

    /// Owning gateway (shorthand for `route.gatewayID`).
    public var gatewayID: GatewayID { route.gatewayID }

    /// Presentation name; never used for routing.
    public var displayName: String

    /// Model/provider summary as reported by the gateway.
    public var model: String?
    public var provider: String?
    public var profileDescription: String?

    /// Latest known activity state (derived from authoritative signals only).
    public var activity: BotActivity
    /// Latest human-facing session, when known.
    public var latestSession: SessionSummary?
    /// Server truth (`profiles.list.gateway_running`): this profile runs its
    /// own gateway process. Secondary badge ONLY — never primary presence
    /// (P0-7 multiplexer scope: every listed profile is reachable through the
    /// owning gateway's shared connection).
    public var gatewayRunning: Bool

    public var id: Route { route }

    public init(
        route: Route,
        displayName: String,
        model: String? = nil,
        provider: String? = nil,
        profileDescription: String? = nil,
        activity: BotActivity = .unknown,
        latestSession: SessionSummary? = nil,
        gatewayRunning: Bool = false
    ) {
        self.route = route
        self.displayName = displayName
        self.model = model
        self.provider = provider
        self.profileDescription = profileDescription
        self.activity = activity
        self.latestSession = latestSession
        self.gatewayRunning = gatewayRunning
    }

    /// Build a bot from a gateway-provided `ProfileDescriptor`.
    ///
    /// Provenance is stamped here: the descriptor carries no gateway identity,
    /// so the caller's `GatewayID` is attached to produce the canonical route.
    public static func bot(
        on gatewayID: GatewayID,
        descriptor: ProfileDescriptor
    ) -> FleetBot {
        FleetBot(
            route: Route(gatewayID: gatewayID, profileSlug: descriptor.slug),
            displayName: descriptor.resolvedDisplayName,
            model: descriptor.model,
            provider: descriptor.provider,
            profileDescription: descriptor.profileDescription,
            latestSession: descriptor.lastSession,
            gatewayRunning: descriptor.gatewayRunning
        )
    }
}

/// User-facing activity state of a bot, derived from authoritative Hermes
/// signals where possible (spec §14). `unknown` is the default until a signal
/// is observed; the client must never fabricate activity.
public enum BotActivity: String, Hashable, Sendable, Codable {
    case working
    case thinking
    case usingTool
    case waiting
    case idle
    case offline
    case needsAttention
    case unknown
}
