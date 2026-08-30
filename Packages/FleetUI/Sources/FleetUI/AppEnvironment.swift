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

    // MARK: Injected seams (composition root)

    private let registry: any GatewayRegistryManaging
    private let roster: any FleetRosterProviding
    private let cache: any CacheStoring
    private let connectionFactory: FleetConnectionFactory
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
        connectionFactory: @escaping FleetConnectionFactory,
        seedRegistrations: [GatewayRegistration] = []
    ) {
        self.registry = registry
        self.roster = roster
        self.cache = cache
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

    public func removeGateway(_ id: GatewayID) async throws {
        try await registry.removeGateway(id)
        activeConnections[id] = nil
        connectionStates[id] = nil
        await reloadGateways()
    }
}
