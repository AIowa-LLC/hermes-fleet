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
    /// True Bots slice 3 (D13): the bot's Routines surface (namespaced
    /// cron jobs on the owning profile's store).
    case botRoutines(Route)
    /// True Bots slice 4 (D15/D16/D18): one room's interactive chat screen
    /// (generation-agnostic; capabilities gate every affordance).
    case room(FleetRoom)
    /// Conversation for a session (U3 canvas; sessionID nil = create new).
    case conversation(Route, sessionID: String?)
    /// H2 Connection health dashboard (per-gateway uptime / reconnects /
    /// last-disconnect / ping RTT).
    case health
    /// U4: the registry cockpit, as a pushed destination (Home dashboard
    /// "View All" drill-in on the tab's own stack).
    case gateways
    /// U4: the connection-activity feed, as a pushed destination (Home
    /// dashboard "View All" drill-in on the tab's own stack).
    case activity
    /// t_3b321b7b: the live read-only Kanban board (pushed destination from
    /// the Home dashboard).
    case kanban
    /// R9-T5: the per-gateway Cron management pane.
    case cron(GatewayID)
    /// R9-T6: the per-gateway Skills management pane.
    case skills(GatewayID)
    /// R9-T7: the per-gateway Memory Graph (read-only learning star map).
    case memoryGraph(GatewayID)
    /// R10-T3: the per-gateway remote Projects browser
    /// (projects.tree + drill-in). `focusPath` (R10-T3 round 2) carries a
    /// transcript `@file:`/`@folder:` ref path so the browser pre-
    /// highlights the containing project and surfaces the target path
    /// (the tap-through "at that path" requirement).
    case projects(GatewayID, focusPath: String? = nil)
}
