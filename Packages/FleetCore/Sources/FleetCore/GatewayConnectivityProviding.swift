import Foundation

/// The single-gateway connectivity seam that keeps SwiftUI free of the
/// transport module (mirrors the M0 guard used for `HermesTransport` and
/// `RosterProviding`).
///
/// A concrete implementation lives in FleetNetworking and composes the M1
/// WebSocket JSON-RPC transport with the M2 gateway identity into one
/// connectable gateway. FleetUI and the app depend on this protocol — never on
/// the concrete transport — so reachable/unreachable state, `gateway.ready`
/// adoption and disconnect safety are presentable without importing the
/// transport module.
public protocol GatewayConnectivityProviding: Sendable {
    /// The gateway this connection is bound to.
    var gatewayID: GatewayID { get }

    /// User-facing reachable/unreachable state (spec §13).
    var status: GatewayStatus { get }

    /// The `gateway.ready` metadata adopted on the last successful connect.
    func adoptedReady() async -> GatewayReadyAdoption?

    /// Connect (mint ticket → open socket → `gateway.ready` handshake) and
    /// adopt the ready metadata. Throws `GatewayConnectivityError` on failure;
    /// never leaves the connection half-open.
    func connect() async throws

    /// Tear down the connection. Idempotent and safe from every state — the
    /// acceptance "disconnect does not crash" (spec §31 Gateway).
    func disconnect() async

    /// The registered gateway with adopted metadata (connection state,
    /// capabilities, replay epoch), for the registry / fleet model.
    func currentGateway() async -> FleetGateway
}

/// Errors a single-gateway connection surfaces, classified for the UI.
public enum GatewayConnectivityError: Error, Sendable, Equatable, LocalizedError {
    /// The gateway could not be reached (no route / connection lost).
    case unreachable
    /// Close 4401 — the credential/ticket was rejected.
    case authenticationRequired
    /// The endpoint answered but is not a usable gateway surface.
    case unsupported(String)
    /// Connect or `gateway.ready` handshake timed out.
    case timeout
    /// Transport failed for another reason.
    case connectionFailed(String)
    /// The operation is invalid in the current connection state.
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable: return "gateway unreachable"
        case .authenticationRequired: return "authentication required"
        case .unsupported(let detail): return "unsupported gateway: \(detail)"
        case .timeout: return "gateway connect timed out"
        case .connectionFailed(let detail): return "gateway connection failed: \(detail)"
        case .invalidState(let detail): return "invalid gateway connection state: \(detail)"
        }
    }
}
