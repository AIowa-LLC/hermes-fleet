import Foundation
import FleetCore

/// Concrete `SessionListProviding` — the `session.list` read path for a
/// single bot route (U2 Bot detail).
///
/// Mirrors the M8 `FleetRosterService` per-gateway pattern: resolve the
/// route's owning gateway from the registry, load its stored credential
/// (Keychain via `CredentialStoring`), build a per-gateway roster session,
/// connect → `session.list` → tear the session down on EVERY exit path
/// (ADR #3 from M7 — the "disconnect does not crash" acceptance, spec §31).
///
/// Observation only: this service issues the read-only `session.list` call
/// and nothing else. A Bot-detail screen driven through this seam
/// structurally cannot create, resume, interrupt, or close a session
/// (spec §5.4 Observation Must Not Imply Ownership; spec §36 session-safety).
///
/// Fail closed (M9): an unsafe route is rejected before any RPC; a route
/// whose owning gateway is not registered throws `.gatewayNotFound` rather
/// than guessing a transport.
public actor GatewaySessionListService: SessionListProviding {
    private let registry: any GatewayRegistryManaging
    private let credentials: any CredentialStoring
    private let sessionFactory: GatewayRosterSessionFactory

    public init(
        registry: any GatewayRegistryManaging,
        credentials: any CredentialStoring,
        sessionFactory: @escaping GatewayRosterSessionFactory
    ) {
        self.registry = registry
        self.credentials = credentials
        self.sessionFactory = sessionFactory
    }

    // MARK: SessionListProviding

    public func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
        // M9 fail-closed guard: an unsafe route never reaches the transport.
        guard route.isRoutingSafe else {
            throw RosterError.invalidRoute("route \(route.id) is not a safe routing key")
        }
        guard let gateway = await registry.gateway(for: route.gatewayID) else {
            throw RosterError.gatewayNotFound(route.gatewayID)
        }
        let credential = try? await credentials.loadCredential(for: route.gatewayID)
        let session = sessionFactory(gateway, credential)

        let outcome = await Self.probe(session, route: route, limit: limit)

        // ADR #3 — the probe ALWAYS tears down before returning, on every path
        // (success and classified failure alike).
        await session.disconnect()
        return try outcome.get()
    }

    /// Connect → `session.list` in isolation, classifying the failure. This
    /// helper NEVER throws and NEVER disconnects: the caller owns teardown so
    /// the socket is always closed even when the call throws (ADR #3).
    private static func probe(
        _ session: any GatewayRosterSession,
        route: Route,
        limit: Int
    ) async -> Result<[SessionSummary], RosterError> {
        do {
            try await session.connect()
            _ = await session.adoptedReady()
            let sessions = try await session.fetchSessions(for: route, limit: limit)
            return .success(sessions)
        } catch let error as RosterError {
            // The roster call itself failed: not-connected → the socket
            // dropped (offline); malformed/rpc → the surface is degraded.
            return .failure(error)
        } catch let error as GatewayConnectivityError {
            // A connect/socket failure is a classified offline / auth
            // failure, surfaced through the roster error vocabulary so the
            // UI renders it as a failed read (never a crash).
            return .failure(mapConnectivity(error))
        } catch {
            return .failure(.rpcFailed(String(describing: error)))
        }
    }

    /// Map a connectivity failure onto the `RosterError` vocabulary. The
    /// exact reason is preserved in a non-secret detail string for the UI.
    private static func mapConnectivity(_ error: GatewayConnectivityError) -> RosterError {
        switch error {
        case .unreachable, .timeout:
            return .notConnected
        case .authenticationRequired:
            return .rpcFailed("authentication required (4401)")
        case .authStrategyRejected(let reason):
            // P0-9: the gateway rejected the STRATEGY itself (401
            // "no_cookie" — a token mint against a cookie-only gateway).
            // Non-secret: the server-echoed reason word only.
            return .rpcFailed("auth strategy rejected (\(reason.rawValue))")
        case .authSurfaceHTTP(let code) where code == 401 || code == 403:
            return .rpcFailed("authentication required (HTTP \(code))")
        case .authSurfaceHTTP(let code):
            return .rpcFailed("endpoint answered but is not the gateway API (HTTP \(code))")
        case .unsupported(let detail):
            return .rpcFailed("unsupported gateway: \(detail)")
        case .connectionFailed(let detail), .invalidState(let detail):
            return .rpcFailed(detail)
        }
    }
}
