import Foundation
import FleetCore

/// Concrete `ConversationSessionProviding` for the Hermes gateway — the U3
/// per-gateway conversation bundle over ONE transport.
///
/// Composes the M3 `SingleGatewayConnection` (connectivity) with the M5
/// `GatewayConversationClient` (create/resume/submit/interrupt + streamed
/// events), the M6 `GatewayReplayEngine` (replay after reconnect) and the M4
/// `GatewaySessionHistoryClient` (authoritative history refetch) — all bound
/// to the same `GatewayWebSocketTransport`, so:
///   - streamed turn events and replayed events share one seq-consistent
///     channel (replay-hold → flush seq-gated dedupe, spec §9/§10);
///   - a reconnect + replay re-hydrates exactly what this session missed;
///   - `reauthenticate()` (M11) re-mints a FRESH ticket — never a silent
///     retry with the same credential.
public actor GatewayConversationSession: ConversationSessionProviding, ApprovalsCapable {
    public let gatewayID: GatewayID

    /// The connectivity half (M3): reachable/unreachable + connect/disconnect.
    private let connection: SingleGatewayConnection

    /// The M5 conversation client bound to the shared transport. Created once
    /// (the transport event channel is single-consumer — M5 note), so repeated
    /// `conversation` access returns the same streamed event channel.
    public let conversation: any ConversationProviding

    /// The M6 replay engine bound to the shared transport + history client.
    public let replay: any ReplayProviding

    /// The M4 read-only history client bound to the shared transport.
    public let history: any SessionHistoryProviding

    /// R9-T1 approvals client bound to the shared transport (approve/deny +
    /// per-session YOLO). Non-optional: `GatewayApprovalClient` is
    /// fail-closed by itself (throws `.notConnected` when the transport is
    /// down), matching every other seam on this session.
    public let approvals: any ApprovalsProviding

    public init(
        gatewayID: GatewayID,
        displayName: String,
        endpoint: URL?,
        transport: GatewayWebSocketTransport
    ) {
        self.gatewayID = gatewayID
        let connection = SingleGatewayConnection(
            gatewayID: gatewayID,
            displayName: displayName,
            endpoint: endpoint,
            transport: transport
        )
        self.connection = connection
        let history = GatewaySessionHistoryClient(gatewayID: gatewayID, transport: transport)
        self.history = history
        self.approvals = GatewayApprovalClient(gatewayID: gatewayID, transport: transport)
        self.conversation = GatewayConversationClient(gatewayID: gatewayID, transport: transport)
        self.replay = GatewayReplayEngine(gatewayID: gatewayID, transport: transport, history: history)
    }

    // MARK: GatewayConnectivityProviding (delegated to the connection)

    public nonisolated var status: GatewayStatus { connection.status }

    /// t_a07ca37e: heartbeat-freshness snapshot via the underlying connection.
    public nonisolated var liveness: ConnectionLivenessSnapshot? { connection.liveness }

    public func adoptedReady() async -> GatewayReadyAdoption? {
        await connection.adoptedReady()
    }

    public func connect() async throws {
        try await connection.connect()
    }

    public func disconnect() async {
        await connection.disconnect()
    }

    public func currentGateway() async -> FleetGateway {
        await connection.currentGateway()
    }

    // MARK: ConversationSessionProviding

    /// Explicit re-authentication after a 4401 close. `SingleGatewayConnection`
    /// mints a fresh single-use ticket via the injected `AuthenticationProviding`
    /// seam — never a silent retry (M11).
    public func reauthenticate() async throws {
        try await connection.reauthenticate()
    }
}
