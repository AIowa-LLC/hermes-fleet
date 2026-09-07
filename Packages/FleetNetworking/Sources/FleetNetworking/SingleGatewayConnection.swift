import Foundation
import FleetCore

/// M3 One-Gateway Connectivity: composes the M1 WebSocket JSON-RPC transport
/// with the M2 gateway identity into one connectable gateway.
///
/// Responsibilities (spec §31 Gateway):
/// - `connect()` mints the ticket, opens the socket, waits for `gateway.ready`
///   and adopts the ready metadata (replay_epoch, heartbeat, change_events).
/// - `status` maps the transport's observable state onto the spec §13
///   vocabulary (Online / Connecting / Degraded / AuthRequired / Offline /
///   Unsupported), so the UI can determine reachable/unreachable without
///   importing the transport module (M0 guard).
/// - `disconnect()` is idempotent and safe from every state — the acceptance
///   "disconnect does not crash" is enforced and tested.
/// - `currentGateway()` returns the registry entry with adopted metadata.
///
/// Roster RPCs (`profiles.list` / `session.list`) remain on the separate
/// `GatewayRosterClient` (M2) bound to the same transport; this type owns
/// connectivity only.
public actor SingleGatewayConnection: GatewayConnectivityProviding {
    // MARK: identity (M2)

    public let gatewayID: GatewayID
    private let displayName: String
    private let endpoint: URL?

    // MARK: transport (M1)

    private let transport: GatewayWebSocketTransport

    // MARK: adopted state

    private var adoptedReadyPayload: GatewayReadyAdoption?

    public init(
        gatewayID: GatewayID,
        displayName: String,
        endpoint: URL?,
        transport: GatewayWebSocketTransport
    ) {
        self.gatewayID = gatewayID
        self.displayName = displayName
        self.endpoint = endpoint
        self.transport = transport
    }

    // MARK: GatewayConnectivityProviding

    /// Reachable/unreachable state derived from the transport seam's
    /// observable state (nonisolated via the transport's lock box).
    public nonisolated var status: GatewayStatus {
        GatewayStatus(transportState: transport.state)
    }

    /// t_a07ca37e: heartbeat-freshness snapshot straight off the transport
    /// (nonisolated lock-box read — no actor hop for the status watcher).
    public nonisolated var liveness: ConnectionLivenessSnapshot? {
        transport.liveness
    }

    public func connect() async throws {
        do {
            try await transport.connect()
        } catch let error as TransportError {
            throw Self.map(error)
        } catch {
            throw GatewayConnectivityError.connectionFailed(String(describing: error))
        }
        // Adopt gateway.ready metadata (M3: replay_epoch + capabilities).
        if let ready = await transport.adoptedReady() {
            adoptedReadyPayload = GatewayReadyAdoption(
                replayEpoch: ready.replayEpoch,
                heartbeatEnabled: ready.heartbeat,
                changeEventsEnabled: ready.changeEvents
            )
        }
    }

    /// Idempotent, safe-from-any-state teardown. The transport only writes
    /// terminal state once; repeated / early disconnect calls are no-ops that
    /// never crash (spec §31 "disconnect does not crash").
    public func disconnect() async {
        await transport.disconnect()
    }

    /// M11 — explicit re-authentication after a 4401 (or a client-side auth
    /// failure). NEVER a silent retry with the same credential: the existing
    /// connection is torn down FIRST, then `connect()` mints a FRESH single-use
    /// ticket / reloads the loopback token through the injected
    /// `AuthenticationProviding` seam (spec §8.6 / synthesis §11 "4401 →
    /// re-auth, no silent retry"). The composition root decides WHEN to
    /// re-authenticate; this transport never does so on its own.
    ///
    /// P0-7 audit: the teardown is REQUIRED now that `connect()` is idempotent
    /// from `.open` — without it, a reauthenticate() on a still-open transport
    /// would degrade into a no-op and silently keep the stale credential.
    public func reauthenticate() async throws {
        await transport.disconnect()
        try await connect()
    }

    public func adoptedReady() async -> GatewayReadyAdoption? {
        adoptedReadyPayload
    }

    /// The registered gateway entry with adopted metadata (connection state,
    /// capabilities, replay_epoch, authConfigured).
    public func currentGateway() async -> FleetGateway {
        var gateway = FleetGateway(
            id: gatewayID,
            displayName: displayName,
            endpoint: endpoint,
            connectionState: transport.state
        )
        if let adopted = adoptedReadyPayload {
            gateway.capabilities = adopted.capabilities
            gateway.replayEpoch = adopted.replayEpoch
            gateway.authConfigured = true
        }
        return gateway
    }

    // MARK: error mapping (transport → connectivity)

    /// Map a transport failure onto the UI-facing connectivity vocabulary.
    static func map(_ error: TransportError) -> GatewayConnectivityError {
        switch error {
        case .connectTimeout, .readyTimeout:
            return .timeout
        case .connectionClosed(let reason):
            return map(reason)
        case .authSurfaceStatus(let code):
            return .authSurfaceHTTP(code)
        case .authStrategyRejected(let reason):
            return .authStrategyRejected(reason)
        case .ticketMintFailed(let detail):
            return .connectionFailed("ticket mint failed: \(detail)")
        case .authenticationFailed:
            return .authenticationRequired
        case .invalidState(let detail):
            return .invalidState(detail)
        case .unableToBuildURL:
            return .connectionFailed("unable to build WebSocket URL")
        case .requestTimeout:
            return .connectionFailed("request timed out")
        case .transportFailure(let detail):
            return .connectionFailed(detail)
        }
    }

    static func map(_ reason: DisconnectReason) -> GatewayConnectivityError {
        switch reason {
        case .reauthenticationRequired:
            return .authenticationRequired
        case .invalidChannel, .hostMismatch, .chatDisabled, .peerNotAllowed:
            return .unsupported(reason.debugDescription)
        case .abnormalClosure:
            return .unreachable
        case .normalClosure, .goingAway, .serverError, .tlsHandshakeFailure, .tlsPinMismatch:
            return .connectionFailed(reason.debugDescription)
        case .unknown(let code, let detail):
            return .connectionFailed("unknown close \(code): \(detail)")
        }
    }
}

// MARK: M8 — GatewayRosterSession (connectivity + roster on ONE transport)

/// M8: a `SingleGatewayConnection` is a full per-gateway roster session. The
/// roster RPCs (`profiles.list` / `session.list`) are delegated to a
/// `GatewayRosterClient` bound to the SAME transport this connection owns, so
/// the multi-gateway aggregation service connects once per gateway and fetches
/// its roster over that same socket (synthesis §13, spec §31 Multi-Gateway).
extension SingleGatewayConnection: GatewayRosterSession {
    public func fetchProfiles() async throws -> [ProfileDescriptor] {
        try await GatewayRosterClient(gatewayID: gatewayID, transport: transport).fetchProfiles()
    }

    public func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
        try await GatewayRosterClient(gatewayID: gatewayID, transport: transport).fetchSessions(for: route, limit: limit)
    }
}
