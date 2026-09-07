/// The transport seam that keeps SwiftUI free of JSON-RPC / WebSocket plumbing.
///
/// M0 defines the boundary ONLY. The concrete transport implementation lives in
/// `FleetNetworking` and is gated behind a later milestone. `FleetUI` and the
/// app target depend on this protocol — never on the transport implementation —
/// which is how the M0 hard guard "SwiftUI must never directly depend on
/// JSON-RPC/WebSocket plumbing" is enforced structurally.
public protocol HermesTransport: Sendable {
    /// Current connection state of the transport.
    var state: TransportState { get }

    /// Establish (and maintain) the connection to a gateway.
    func connect() async throws

    /// Tear down the connection.
    func disconnect() async
}

/// Observable connection state of a gateway transport.
public enum TransportState: Hashable, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}
