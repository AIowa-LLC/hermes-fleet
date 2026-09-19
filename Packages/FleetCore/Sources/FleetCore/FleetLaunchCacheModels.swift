import Foundation

/// ADR-0012 (Instant Fleet): the persisted launch-cache DTOs. These are a
/// STABLE wire format decoupled from the live models (`FleetBot` /
/// `FleetRosterSnapshot` are not Codable and evolve with the UI); the cache
/// layer maps to/from them at the seams. **No credentials, tokens, or auth
/// material — display fields, Route identity, and session summaries only.**
///
/// Rendering contract: the registry (restored first at launch, P0-4) owns
/// gateway identity; the roster DTO carries ONLY per-gateway bot lists and
/// is merged into a synthetic snapshot over the registry's gateways.

/// One bot row, frozen at cache time.
public struct CachedFleetBot: Codable, Sendable, Equatable, Identifiable {
    /// Canonical routing identity (Codable ✓).
    public let route: Route
    /// Presentation name; never used for routing.
    public let displayName: String
    public let hasAvatar: Bool
    /// Model/provider summary as last reported.
    public let model: String?
    public let provider: String?
    public let profileDescription: String?
    /// Latest known activity state (Codable ✓).
    public let activity: BotActivity
    /// Whether the profile runs its own gateway process (secondary badge).
    public let gatewayRunning: Bool

    public var id: Route { route }

    public init(
        route: Route,
        displayName: String,
        hasAvatar: Bool = false,
        model: String? = nil,
        provider: String? = nil,
        profileDescription: String? = nil,
        activity: BotActivity = .unknown,
        gatewayRunning: Bool = false
    ) {
        self.route = route
        self.displayName = displayName
        self.hasAvatar = hasAvatar
        self.model = model
        self.provider = provider
        self.profileDescription = profileDescription
        self.activity = activity
        self.gatewayRunning = gatewayRunning
    }
}

/// A gateway's bot list as of the last successful roster refresh.
public struct CachedGatewayRoster: Codable, Sendable, Equatable {
    public let gatewayID: GatewayID
    public let bots: [CachedFleetBot]
    public let cachedAt: Date

    public init(gatewayID: GatewayID, bots: [CachedFleetBot], cachedAt: Date = Date()) {
        self.gatewayID = gatewayID
        self.bots = bots
        self.cachedAt = cachedAt
    }
}

/// One route's session list as of the last successful read.
public struct CachedSessionList: Codable, Sendable, Equatable {
    public let route: Route
    /// `SessionSummary` is Codable ✓ and carries `lastActive`, so unread
    /// dots render from cache on first paint (r4 contract).
    public let sessions: [SessionSummary]
    public let cachedAt: Date

    public init(route: Route, sessions: [SessionSummary], cachedAt: Date = Date()) {
        self.route = route
        self.sessions = sessions
        self.cachedAt = cachedAt
    }
}

/// Cache-wide policy (Hermex parity): entries expire after 7 days; reads
/// past TTL discard; writes prune orphans (gateways no longer registered).
public enum FleetLaunchCachePolicy {
    public static let ttl: TimeInterval = 7 * 24 * 60 * 60
}

/// Mapping between the live roster models and the cache DTOs. Display
/// fields only — the live model stays the runtime source of truth; Bot Mode
/// metadata (uiMeta/canonical/worker refs) is intentionally NOT cached: it
/// is re-read per-use by its owning surfaces and never renders from cache.
public enum FleetLaunchCacheMapper {
    /// Freezes a live bot into its cache DTO.
    public static func dto(from bot: FleetBot) -> CachedFleetBot {
        CachedFleetBot(
            route: bot.route,
            displayName: bot.displayName,
            hasAvatar: bot.hasAvatar,
            model: bot.model,
            provider: bot.provider,
            profileDescription: bot.profileDescription,
            activity: bot.activity,
            gatewayRunning: bot.gatewayRunning
        )
    }

    /// Thaws a cached bot into the live model (Bot Mode fields at their
    /// defaults; presence is refined by the owning gateway's live state).
    public static func live(from dto: CachedFleetBot) -> FleetBot {
        FleetBot(
            route: dto.route,
            displayName: dto.displayName,
            hasAvatar: dto.hasAvatar,
            model: dto.model,
            provider: dto.provider,
            profileDescription: dto.profileDescription,
            activity: dto.activity,
            latestSession: nil,
            gatewayRunning: dto.gatewayRunning
        )
    }
}
