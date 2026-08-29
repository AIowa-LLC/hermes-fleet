import Foundation

/// Canonical routing identity for a Hermes bot: an exact `(GatewayID,
/// ProfileSlug)` pair.
///
/// M2 routing rule (synthesis §7): a route is ALWAYS the pair — never a
/// display name, never a bare profile slug. Two gateways that both expose a
/// profile named "default" are two DISTINCT routes; this type is the reason a
/// request targeting `A/default` can never be routed to `B/default`.
///
/// Fails closed: resolution APIs that take a route return `nil` when the
/// owning gateway is absent or the pair is not registered — the caller never
/// guesses a target from a partial identity.
public struct Route: Hashable, Sendable, Codable, CustomStringConvertible, Identifiable {
    public let gatewayID: GatewayID
    public let profileSlug: ProfileSlug

    public init(gatewayID: GatewayID, profileSlug: ProfileSlug) {
        self.gatewayID = gatewayID
        self.profileSlug = profileSlug
    }

    /// Stable identity string: `<gateway>#<slug>` — collision-free across
    /// gateways because the gateway ID is always present.
    public var id: String { "\(gatewayID.rawValue)#\(profileSlug.rawValue)" }

    public var description: String { id }
}

extension Route: Comparable {
    /// Deterministic ordering for roster rendering (gateway first, then slug).
    public static func < (lhs: Route, rhs: Route) -> Bool {
        if lhs.gatewayID.rawValue != rhs.gatewayID.rawValue {
            return lhs.gatewayID.rawValue < rhs.gatewayID.rawValue
        }
        return lhs.profileSlug.rawValue < rhs.profileSlug.rawValue
    }
}
