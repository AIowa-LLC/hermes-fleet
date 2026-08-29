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
///
/// M9 (Routing Collision Hardening): both components are validated by
/// `RoutingGuard`. An unsafe component is rejected because it would make the
/// `id` string ambiguous (`a#b/c` vs `a/b#c` both → `a#b#c`) or allow path
/// traversal; `isRoutingSafe` / `init?(validating:)` let callers fail closed
/// on unsafe routes before they reach a transport or a roster.
public struct Route: Hashable, Sendable, Codable, CustomStringConvertible, Identifiable {
    public let gatewayID: GatewayID
    public let profileSlug: ProfileSlug

    public init(gatewayID: GatewayID, profileSlug: ProfileSlug) {
        self.gatewayID = gatewayID
        self.profileSlug = profileSlug
    }

    /// Failable validating initializer: returns `nil` unless BOTH components
    /// are safe routing keys (M9). Use when a route is built from untrusted
    /// input (user-supplied slug, wire-derived profile name).
    public init?(validating gatewayID: GatewayID, profileSlug: ProfileSlug) {
        guard RoutingGuard.isValidRouteComponent(gatewayID.rawValue),
              RoutingGuard.isValidRouteComponent(profileSlug.rawValue) else { return nil }
        self.init(gatewayID: gatewayID, profileSlug: profileSlug)
    }

    /// Stable identity string: `<gateway>#<slug>` — collision-free across
    /// gateways because the gateway ID is always present, and unambiguous
    /// because both components reject the `#` separator (M9).
    public var id: String { "\(gatewayID.rawValue)#\(profileSlug.rawValue)" }

    public var description: String { id }

    /// Both components are safe routing keys (path-safe tokens, no `#`).
    ///
    /// A route whose components fail the guard is structurally unsafe: its
    /// `id` could collide with another route, and its slug/session key could
    /// carry path traversal. Callers fail closed (M9).
    public var isRoutingSafe: Bool {
        RoutingGuard.isValidRouteComponent(gatewayID.rawValue)
            && RoutingGuard.isValidRouteComponent(profileSlug.rawValue)
    }
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
