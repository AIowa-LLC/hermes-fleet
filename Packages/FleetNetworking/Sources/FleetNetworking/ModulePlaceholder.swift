import FleetCore

/// M0 establishes the `FleetNetworking` module boundary ONLY.
///
/// This module will own the JSON-RPC / WebSocket transport and the concrete
/// `HermesTransport` implementation. Per the M0 hard scope guard, NO transport
/// code is implemented yet — that work is gated behind a later milestone.
///
/// The reference to `FleetGateway` below proves the module's dependency
/// direction (FleetNetworking → FleetCore) at compile time. SwiftUI never
/// imports this module; only the composition root does.
public enum FleetNetworkingPlaceholder {
    public static func describe(_ gateway: FleetGateway) -> String {
        "\(gateway.id) · \(gateway.displayName)"
    }
}
