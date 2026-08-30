import Foundation
import FleetCore

/// Typed navigation destinations for the U2 fleet cockpit.
///
/// Flow: Gateways → Bots (per-gateway drill) → Bot detail → Conversation
/// (list-detail push navigation per the synthesis UX plan). `roster` is the
/// fleet-wide union Bots roster (M8 aggregation, per-gateway grouping,
/// partial-outage states). U2 builds Gateways registry management, the union
/// roster, and Bot detail; Conversation remains the U3 placeholder canvas.
public enum FleetScreen: Hashable, Sendable {
    /// Bots on a specific gateway (drilled from the gateways list).
    case bots(GatewayID)
    /// Fleet-wide union roster (all gateways' bots grouped per gateway).
    case roster
    /// Bot detail for an exact route: identity + status + sessions list.
    case botDetail(Route)
    /// Conversation for a session (U3 placeholder canvas; session-scoped).
    case conversation(Route, sessionID: String)
}
