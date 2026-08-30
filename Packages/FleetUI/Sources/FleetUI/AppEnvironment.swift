import Foundation
import Observation
import FleetCore

/// Builds a single-gateway connection for a registered gateway, so the app
/// runtime can drive the connect/disconnect/reconnect lifecycle without
/// depending on transport construction itself.
///
/// Mirrors `GatewayConnectionFactory` in FleetNetworking but lives in FleetUI
/// (a different typealias name to avoid cross-module ambiguity) so SwiftUI
/// depends only on the FleetCore seam — never on the transport module (M0
/// hard guard). Injected at the composition root (app target): production
/// builds a `SingleGatewayConnection`; DEBUG simulator builds a scripted
/// connection; tests inject scripted doubles.
public typealias FleetConnectionFactory = @Sendable (
    _ gateway: FleetGateway,
    _ credential: GatewayCredential?
) -> any GatewayConnectivityProviding

/// Observable, per-gateway connection lifecycle (spec §13 states; §31
/// "disconnect does not crash").
///
/// U1: the runtime owns the lifecycle — connect / disconnect / reconnect are
/// driven here and their phases are `@Observable` so SwiftUI renders
/// Connecting / Connected / Offline / failed-state transitions without
/// importing the transport module.
public enum GatewayConnectionState: Equatable, Sendable {
    /// Never connected this session (fresh registry entry).
    case idle
    /// `connect()` in flight (socket handshake / `gateway.ready` wait).
    case connecting
    /// Fully connected and serving (status online/degraded).
    case connected
    /// Cleanly disconnected (client requested teardown; status offline).
    case disconnected
    /// A connect attempt failed. `status` is the classified §13 status
    /// (authRequired / offline / unsupported / degraded) — never a guess.
    case failed(GatewayStatus)

    /// Map a transport seam status onto the observable lifecycle vocabulary.
    init(status: GatewayStatus) {
        switch status {
        case .online, .degraded: self = .connected
        case .connecting: self = .connecting
        case .offline, .authenticationRequired, .unsupported: self = .failed(status)
        }
    }
}

/// The observable application runtime for the Hermes Fleet cockpit.
///
/// U1 composition (all behind FleetCore seams — NO FleetNetworking import in
/// FleetUI):
/// - `any GatewayRegistryManaging` — gateway registry CRUD + credentials +
///   testConnection (concrete `GatewayRegistryService` injected at root).
/// - `any FleetRosterProviding` — the M8 multi-gateway union roster (concrete
///   `FleetRosterService` injected at root).
/// - `any CacheStoring` — the M10 non-secret persistence cache (concrete
///   `SwiftDataCacheStore` injected at root).
/// - `FleetConnectionFactory` — per-gateway connection lifecycle seam.
///
/// The app owns the connection lifecycle: `connect` / `disconnect` /
/// `reconnect` transition `connectionStates[id]` which SwiftUI observes.
@MainActor
@Observable
public final class AppEnvironment {
    // MARK: Observable state (SwiftUI reads these)

    /// Registered gateways in stable ID order.
    public private(set) var gateways: [FleetGateway] = []
    /// Latest union-roster snapshot (nil until the first refresh).
    public private(set) var rosterSnapshot: FleetRosterSnapshot?
    /// True while a roster refresh is in flight.
    public private(set) var isRefreshing = false
    /// Count of cached session watermarks (proves the cache seam is wired;
    /// non-secret — synthesis §12).
    public private(set) var cachedWatermarkCount = 0
    /// Per-gateway connection lifecycle, observable.
    public private(set) var connectionStates: [GatewayID: GatewayConnectionState] = [:]

    /// Per-gateway connection-test result, observable (§13 reachable /
    /// unreachable probe). Set only after `testConnection` completes; a
    /// gateway with no entry has never been tested this session.
    public private(set) var testResults: [GatewayID: GatewayTestResult] = [:]

    /// Gateways currently running a connection test (for a Testing… row).
    public private(set) var testingGatewayIDs: Set<GatewayID> = []

    /// Sessions per bot route, fetched via the read-only `session.list` seam.
    /// Observable so Bot detail re-renders as a fetch resolves.
    public private(set) var sessionsByRoute: [Route: [SessionSummary]] = [:]

    /// Routes whose `session.list` fetch is in flight.
    public private(set) var loadingRoutes: Set<Route> = []

    /// Last classified read error per route (non-secret), for the Bot-detail
    /// error state. Absent until a fetch fails.
    public private(set) var sessionReadErrors: [Route: String] = [:]

    // MARK: Injected seams (composition root)

    private let registry: any GatewayRegistryManaging
    private let roster: any FleetRosterProviding
    private let cache: any CacheStoring
    private let connectionFactory: FleetConnectionFactory
    /// Read-only `session.list` path for Bot detail (injected concrete:
    /// `GatewaySessionListService` in production, scripted in DEBUG/tests).
    private let sessionList: any SessionListProviding
    /// Gateways to register on first launch (empty registry) so the U1
    /// navigation skeleton is walkable in the simulator. Presentation data
    /// only — the user manages the real fleet in U2.
    private let seedRegistrations: [GatewayRegistration]

    /// Active connection per gateway (owned by the runtime; survives view
    /// teardowns so disconnect/reconnect are stable).
    private var activeConnections: [GatewayID: any GatewayConnectivityProviding] = [:]

    public init(
        registry: any GatewayRegistryManaging,
        roster: any FleetRosterProviding,
        cache: any CacheStoring,
        sessionList: any SessionListProviding,
        connectionFactory: @escaping FleetConnectionFactory,
        seedRegistrations: [GatewayRegistration] = []
    ) {
        self.registry = registry
        self.roster = roster
        self.cache = cache
        self.sessionList = sessionList
        self.connectionFactory = connectionFactory
        self.seedRegistrations = seedRegistrations
    }

    // MARK: Load / refresh

    /// Load gateways from the registry. On a truly empty registry, seeds the
    /// known gateways (DEBUG simulator walkthrough) — never overrides a
    /// user-managed fleet.
    public func load() async {
        let existing = await registry.allGateways()
        if existing.isEmpty, !seedRegistrations.isEmpty {
            for registration in seedRegistrations {
                try? await registry.addGateway(registration)
            }
        }
        await reloadGateways()
        cachedWatermarkCount = (try? await cache.loadWatermarks())?.count ?? 0
    }

    private func reloadGateways() async {
        gateways = await registry.allGateways()
        for gateway in gateways where connectionStates[gateway.id] == nil {
            connectionStates[gateway.id] = .idle
        }
    }

    /// Refresh the union fleet roster (M8). Never throws for a single-gateway
    /// outage (partial-availability contract).
    public func refreshRoster() async {
        isRefreshing = true
        defer { isRefreshing = false }
        rosterSnapshot = await roster.refreshRoster()
    }

    // MARK: Connection lifecycle (runtime-owned, observable)

    /// Connect to a gateway: `connecting` → `connected`, or `failed(status)`.
    /// Idempotent-safe: a connect on an already-connecting OR already-connected
    /// gateway is ignored — a real transport throws `invalidState` on a second
    /// connect, so the runtime must never drive one (the observable state would
    /// otherwise wrongly flip `connected → failed(.offline)`).
    public func connect(to id: GatewayID) async {
        guard connectionStates[id] != .connecting,
              connectionStates[id] != .connected else { return }
        guard let gateway = gateways.first(where: { $0.id == id }) else { return }
        connectionStates[id] = .connecting
        let connection = activeConnections[id] ?? connectionFactory(gateway, nil)
        activeConnections[id] = connection
        do {
            try await connection.connect()
            connectionStates[id] = GatewayConnectionState(status: connection.status)
        } catch let error as GatewayConnectivityError {
            connectionStates[id] = .failed(GatewayStatus(connectivityError: error))
        } catch {
            connectionStates[id] = .failed(.offline)
        }
    }

    /// Disconnect cleanly and safely from every state (spec §31).
    public func disconnect(from id: GatewayID) async {
        guard let connection = activeConnections[id] else {
            connectionStates[id] = .disconnected
            return
        }
        await connection.disconnect()
        connectionStates[id] = .disconnected
    }

    /// Reconnect: tear down cleanly, then reconnect. Observable as
    /// `disconnected` → `connecting` → `connected`/`failed`.
    public func reconnect(to id: GatewayID) async {
        await disconnect(from: id)
        await connect(to: id)
    }

    // MARK: Roster accessors (for the Bots / Sessions screens)

    /// Bots owned by a gateway from the latest roster snapshot (fail closed:
    /// empty while the gateway is unreachable or the snapshot is stale).
    public func bots(on id: GatewayID) -> [FleetBot] {
        rosterSnapshot?.bots(on: id) ?? []
    }

    /// The single bot for an exact route, or nil (fail closed).
    public func bot(for route: Route) -> FleetBot? {
        rosterSnapshot?.bot(for: route)
    }

    /// The registered gateway for an ID, or nil.
    public func gateway(for id: GatewayID) -> FleetGateway? {
        gateways.first { $0.id == id }
    }

    // MARK: Registry passthroughs (U2 Gateway management reuses these)

    public func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway {
        let gateway = try await registry.addGateway(registration)
        await reloadGateways()
        return gateway
    }

    /// Register a gateway and optionally store its credential in one seam
    /// call (U2 add-gateway form). The credential is passed straight to the
    /// registry's Keychain-safe store — it is never held by the view layer
    /// or logged. `nil` credential → registration only.
    public func addGateway(
        _ registration: GatewayRegistration,
        credential: GatewayCredential?
    ) async throws -> FleetGateway {
        let gateway = try await registry.addGateway(registration)
        if let credential {
            try await registry.saveCredential(credential, for: gateway.id)
        }
        await reloadGateways()
        return gateway
    }

    /// Apply a partial edit to a gateway's display name / endpoint / auth
    /// config. Throws `.notFound` / `.invalidEndpoint` from the registry seam.
    public func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
        let gateway = try await registry.updateGateway(id, edits: edits)
        await reloadGateways()
        return gateway
    }

    public func removeGateway(_ id: GatewayID) async throws {
        try await registry.removeGateway(id)
        activeConnections[id] = nil
        connectionStates[id] = nil
        testResults[id] = nil
        await reloadGateways()
    }

    // MARK: Auth config entry (M7 credential flow — Keychain-safe)

    /// Store a credential for a gateway (Keychain via the registry seam; the
    /// secret never transits the UI model or logs). Marks auth configured.
    public func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {
        try await registry.saveCredential(credential, for: id)
        await reloadGateways()
    }

    /// Clear the stored credential for a gateway (no-op when absent).
    public func clearCredential(for id: GatewayID) async throws {
        try await registry.clearCredential(for: id)
        await reloadGateways()
    }

    /// Whether a credential is currently stored for a gateway (Keychain).
    public func hasCredential(for id: GatewayID) async -> Bool {
        await registry.hasCredential(for: id)
    }

    // MARK: Test connection (§13 reachable/unreachable probe, observable)

    /// Probe a gateway's reachability and capability surface. Observable:
    /// `testingGatewayIDs` while in flight, then `testResults[id]` set to the
    /// classified §13 result. A classified failure (offline / authRequired /
    /// unsupported / degraded) is stored, never thrown to the UI — only an
    /// absent gateway throws (from the registry seam).
    public func testConnection(to id: GatewayID) async throws {
        guard gateways.contains(where: { $0.id == id }) else {
            throw GatewayRegistryError.notFound(id)
        }
        testingGatewayIDs.insert(id)
        defer { testingGatewayIDs.remove(id) }
        let result = try await registry.testConnection(to: id)
        testResults[id] = result
        // Reflect the probe into the observable connection lifecycle so the
        // row shows the §13 state without a separate connect attempt.
        connectionStates[id] = GatewayConnectionState(status: result.status)
    }

    // MARK: Session list (Bot detail — read-only `session.list` seam)

    /// Load a bot's sessions via the read-only `session.list` seam, cached in
    /// the observable `sessionsByRoute`. Fail-closed: a classified read error
    /// is recorded (non-secret) so the UI renders an error state, never a
    /// crash.
    public func loadSessions(for route: Route) async {
        guard !loadingRoutes.contains(route) else { return }
        loadingRoutes.insert(route)
        defer { loadingRoutes.remove(route) }
        do {
            let sessions = try await sessionList.fetchSessions(for: route, limit: 200)
            sessionsByRoute[route] = sessions
            sessionReadErrors[route] = nil
        } catch let error as RosterError {
            sessionReadErrors[route] = error.errorDescription
        } catch {
            sessionReadErrors[route] = String(describing: error)
        }
    }

    /// Sessions for a route, or `nil` when never fetched.
    public func sessions(for route: Route) -> [SessionSummary]? {
        sessionsByRoute[route]
    }
}
