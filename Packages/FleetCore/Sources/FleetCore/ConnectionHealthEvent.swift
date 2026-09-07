import Foundation

/// A connection-health observation emitted by the transport layer and consumed
/// by the FleetCore stats accumulator (H2 Connection health dashboard).
///
/// Lives in FleetCore (not FleetNetworking) so the accumulator and the UI can
/// speak the same vocabulary without importing the transport module (M0 hard
/// guard: FleetUI must never import FleetNetworking).
public enum ConnectionHealthEvent: Sendable, Equatable {
    /// A connect attempt began (socket handshake / `gateway.ready` wait).
    case connectStarted
    /// The connection became fully open and serving (`gateway.ready` adopted).
    case connected
    /// The connection ended, with the classified reason (the transport's
    /// `DisconnectReason.debugDescription` — never secret material).
    case disconnected(reason: String)
    /// A heartbeat ping round-trip completed (wall time between sending
    /// `gateway.ping` and receiving its correlated pong).
    case pingRTT(milliseconds: Double)
}
