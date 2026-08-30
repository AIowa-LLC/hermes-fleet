import Foundation
import FleetCore

/// Typed navigation destinations for the U1 cockpit shell.
///
/// Flow: Gateways → Bots → Sessions → Conversation (list-detail push
/// navigation per the synthesis UX plan; NO bot-detail content and NO
/// conversation canvas in U1 — those destinations exist as skeleton
/// placeholders that U2/U3 fill with real content).
public enum FleetScreen: Hashable, Sendable {
    /// Bots on a specific gateway (drilled from the gateways list).
    case bots(GatewayID)
    /// Sessions for a bot route (drilled from the bots list).
    case sessions(Route)
    /// Conversation for a session (U3 placeholder canvas; session-scoped).
    case conversation(Route, sessionID: String)
}
