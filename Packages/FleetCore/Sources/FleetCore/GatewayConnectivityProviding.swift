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

    /// Heartbeat-freshness liveness snapshot (t_a07ca37e): when the last
    /// VALID inbound frame (heartbeat pong or payload — junk never refreshes
    /// it, P1-4) arrived on the underlying transport. Nil when the provider
    /// has no live transport (test doubles, preview connections) — consumers
    /// treat nil as "no freshness signal" and fall back to `status`.
    /// The default keeps protocol conformers without a transport compiling.
    var liveness: ConnectionLivenessSnapshot? { get }

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

extension GatewayConnectivityProviding {
    /// No freshness signal by default (no live transport backing).
    public var liveness: ConnectionLivenessSnapshot? { nil }
}

/// Errors a single-gateway connection surfaces, classified for the UI.
public enum GatewayConnectivityError: Error, Sendable, Equatable, LocalizedError {
    /// The gateway could not be reached (no route / connection lost).
    case unreachable
    /// Close 4401 — the credential/ticket was rejected.
    case authenticationRequired
    /// F1: the auth REST surface answered with this HTTP status before the
    /// socket opened. 401/403 → `authenticationRequired` (credential
    /// rejected); anything else means the endpoint answered but is not the
    /// gateway API surface (wrong port) — `unsupported`.
    case authSurfaceHTTP(Int)
    /// P0-9: the auth surface rejected the request and NAMED its cause (the
    /// tunnel's 401 `no_cookie`) — the configured strategy cannot work
    /// against this gateway. Classifies as `authenticationRequired` (the
    /// user must fix auth) with cause-specific guidance via the detail
    /// string, distinct from a bad credential.
    case authStrategyRejected(AuthRejectionReason)
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
        case .authSurfaceHTTP(let code): return "auth endpoint returned HTTP \(code)"
        case .authStrategyRejected(let reason): return "auth rejected: \(reason.rawValue)"
        case .unsupported(let detail): return "unsupported gateway: \(detail)"
        case .timeout: return "gateway connect timed out"
        case .connectionFailed(let detail): return "gateway connection failed: \(detail)"
        case .invalidState(let detail): return "invalid gateway connection state: \(detail)"
        }
    }
}
