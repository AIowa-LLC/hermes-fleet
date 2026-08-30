import Foundation

/// The roster seam that keeps SwiftUI free of JSON-RPC / WebSocket plumbing.
///
/// FleetUI and the app depend on this protocol (defined in FleetCore) — never
/// on the concrete `GatewayRosterClient` in FleetNetworking. This mirrors the
/// M0 hard guard used for `HermesTransport`: the UI can present the roster
/// without importing the transport module, and the composition root wires the
/// concrete implementation.
public protocol RosterProviding: Sendable {
    /// Fetch the profile/bot roster from a gateway's `profiles.list`.
    /// - Returns: descriptors in gateway order; empty on a healthy gateway
    ///   with no profiles.
    func fetchProfiles() async throws -> [ProfileDescriptor]

    /// Fetch sessions owned by a `(gateway, profile)` route via `session.list`.
    /// - Parameters:
    ///   - route: the exact routing identity; the profile slug scopes the call.
    ///   - limit: max sessions to return (gateway default 200).
    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary]
}

/// Errors thrown by roster clients (defined here so the seam stays self-contained).
public enum RosterError: Error, Sendable, Equatable, LocalizedError {
    /// The transport is not connected to the gateway.
    case notConnected
    /// The gateway returned a malformed roster payload.
    case malformedPayload(String)
    /// The gateway rejected the request.
    case rpcFailed(String)
    /// The requested route is not a safe routing key (path traversal, `#`,
    /// separators) — fail closed before any RPC is sent (M9).
    case invalidRoute(String)
    /// The route's owning gateway is not registered — fail closed, never
    /// guess a transport for an unknown gateway.
    case gatewayNotFound(GatewayID)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "gateway not connected"
        case .malformedPayload(let s): return "malformed roster payload: \(s)"
        case .rpcFailed(let s): return "roster RPC failed: \(s)"
        case .invalidRoute(let s): return "invalid route: \(s)"
        case .gatewayNotFound(let id): return "gateway not registered: \(id.rawValue)"
        }
    }
}
