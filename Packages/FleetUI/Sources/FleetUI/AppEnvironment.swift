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

/// Builds a per-gateway conversation session (U3): connectivity + conversation
/// + replay + history over one transport. Mirrors `FleetConnectionFactory` but
/// lives in FleetUI so SwiftUI depends only on the FleetCore seam — never on
/// the transport module (M0 hard guard). Injected at the composition root:
/// production builds a `GatewayConversationSession`; DEBUG builds a scripted
/// session; tests inject scripted doubles.
public typealias FleetConversationFactory = @Sendable (
    _ gateway: FleetGateway,
    _ credential: GatewayCredential?
) -> any ConversationSessionProviding

/// Builds a per-gateway kanban board watcher (t_3b321b7b). Lives in FleetUI
/// for the same M0-guard reason as the factories above: SwiftUI depends only
/// on the FleetCore `KanbanBoardWatching` seam — never on the transport
/// module. Injected at the composition root: production builds a
/// `KanbanEventStreamClient`; DEBUG builds a scripted watcher; tests inject
/// doubles.
public typealias FleetKanbanWatcherFactory = @Sendable (
    _ gateway: FleetGateway
) -> any KanbanBoardWatching

/// Builds a per-gateway management seam (R9-T5/T6 — cron + skills). Lives in
/// FleetUI for the same M0-guard reason as the factories above: SwiftUI
/// depends only on the FleetCore `GatewayManagementProviding` seam — never on
/// the transport module. Injected at the composition root: production builds
/// a `GatewayManagementClient` over the gateway's transport; DEBUG builds a
/// scripted seam; tests inject doubles.
public typealias FleetManagementSeamFactory = @Sendable (
    _ gateway: FleetGateway
) -> any GatewayManagementProviding

/// Builds a per-gateway learning seam (R9-T7 — memory graph). Same M0-guard
/// construction as the management seam above.
public typealias FleetLearningSeamFactory = @Sendable (
    _ gateway: FleetGateway
) -> any GatewayLearningProviding

/// Builds a per-gateway projects seam (R10-T3 — remote file browser).
/// Same M0-guard construction as the seams above.
public typealias FleetProjectsSeamFactory = @Sendable (
    _ gateway: FleetGateway
) -> any GatewayProjectsProviding

/// R10-T4 — builds the on-device voice engine (Speech framework STT +
/// AVSpeechSynthesizer TTS) shared by every conversation view model. nil ⇒
/// the fail-closed `UnsupportedVoiceTranscriber` (mic affordances hidden).
/// Lives in FleetUI for the same M0-guard reason as the factories above:
/// SwiftUI depends only on the FleetCore `VoiceTranscribing` seam — never on
/// AVFoundation/Speech directly.
public typealias FleetVoiceEngineFactory = @Sendable () -> (any VoiceTranscribing)?

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

    /// H2: latest per-gateway connection-health snapshots (uptime %,
    /// reconnects, last-disconnect reason, ping RTT). Updated by
    /// `refreshHealthStats()`; the Health dashboard refreshes it live.
    public private(set) var healthStats: [GatewayID: GatewayHealthStats] = [:]

    /// P0-2: in-progress Add/Edit-Gateway form draft. Lives HERE (composition
    /// root) so it survives the H1 biometric lock / scenePhase teardown — the
    /// form sheet is destroyed on background+relock, and `GatewaysView`
    /// re-presents it from this store on unlock. In-memory only, never
    /// persisted.
    public let gatewayFormDraft = GatewayFormDraftStore()

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
    /// H2: connection-health accumulator (FleetCore seam; concrete
    /// `GatewayHealthStatsAccumulator` fed by the composition root's transport
    /// feed task — FleetUI never touches the transport module).
    private let health: any ConnectionHealthAccumulating
    /// Read-only `session.list` path for Bot detail (injected concrete:
    /// `GatewaySessionListService` in production, scripted in DEBUG/tests).
    private let sessionList: any SessionListProviding
    /// R9-T1: biometric seam for the approval gate (FaceID-gated approve /
    /// confirmed YOLO enable). Injected by the app composition root; the
    /// default fails closed.
    private let biometrics: any AppLockBiometricAuth
    /// U3 conversation sessions per gateway (injected concrete:
    /// `GatewayConversationSession` in production, scripted in DEBUG/tests).
    private let conversationFactory: FleetConversationFactory?
    /// t_3b321b7b: kanban board watcher factory — one watcher per gateway
    /// (the concrete `KanbanEventStreamClient` in production, scripted in
    /// DEBUG/tests).
    private let kanbanWatcherFactory: FleetKanbanWatcherFactory?
    /// R9-T5/T6: management seam factory (cron + skills) — one per gateway
    /// (the concrete `GatewayManagementClient` in production, scripted in
    /// DEBUG/tests).
    private let managementSeamFactory: FleetManagementSeamFactory?
    /// R9-T7: learning seam factory (memory graph) — one per gateway (the
    /// concrete `GatewayLearningClient` in production, scripted in
    /// DEBUG/tests).
    private let learningSeamFactory: FleetLearningSeamFactory?
    /// R9-T7: learning-graph snapshot store (offline browse). Optional —
    /// tests inject doubles; production passes the composition root's
    /// SwiftData cache store adapted to the FleetCore seam.
    private let learningSnapshotStore_: (any LearningGraphSnapshotStoring)?
    /// R10-T3: projects seam factory (remote file browser) — one per
    /// gateway (the concrete `GatewayProjectsClient` in production,
    /// scripted in DEBUG/tests).
    private let projectsSeamFactory: FleetProjectsSeamFactory?

    /// R10-T4 — builds the shared on-device voice engine (nil ⇒ fail-closed
    /// default; mic affordances hidden).
    private let voiceEngineFactory: FleetVoiceEngineFactory?
    /// R10-T3: projects-tree snapshot store (offline browse). Same
    /// construction as the learning snapshot store.
    private let projectsSnapshotStore_: (any ProjectsSnapshotStoring)?
    /// Gateways to register on first launch (empty registry) so the U1
    /// navigation skeleton is walkable in the simulator. Presentation data
    /// only — the user manages the real fleet in U2.
    private let seedRegistrations: [GatewayRegistration]

    /// Active connection per gateway (owned by the runtime; survives view
    /// teardowns so disconnect/reconnect are stable).
    private var activeConnections: [GatewayID: any GatewayConnectivityProviding] = [:]

    /// Lazily-built U3 conversation sessions per gateway (one per gateway;
    /// created on first conversation screen use).
    private var conversationSessions: [GatewayID: any ConversationSessionProviding] = [:]

    /// R9-T5/T6: lazily-built management seams per gateway (one per
    /// gateway; created on first Cron/Skills pane use — the pane's
    /// transport survives view teardowns like a conversation session's).
    private var managementSeams: [GatewayID: any GatewayManagementProviding] = [:]

    /// R9-T7: lazily-built learning seams per gateway (same lifetime as
    /// the management seams).
    private var learningSeams: [GatewayID: any GatewayLearningProviding] = [:]

    /// R10-T3: lazily-built projects seams per gateway (same lifetime as
    /// the learning seams).
    private var projectsSeams: [GatewayID: any GatewayProjectsProviding] = [:]

    /// Generation of the newest roster refresh (t_e77c614c). Bumped each time
    /// `refreshRoster()` starts; an in-flight refresh whose captured token no
    /// longer matches is STALE and must not settle observable state (the
    /// `OnboardingViewModel.beginOperation()` fencing pattern).
    @ObservationIgnored private var rosterGeneration = 0

    public init(
        registry: any GatewayRegistryManaging,
        roster: any FleetRosterProviding,
        cache: any CacheStoring,
        sessionList: any SessionListProviding,
        connectionFactory: @escaping FleetConnectionFactory,
        conversationFactory: FleetConversationFactory? = nil,
        kanbanWatcherFactory: FleetKanbanWatcherFactory? = nil,
        managementSeamFactory: FleetManagementSeamFactory? = nil,
        learningSeamFactory: FleetLearningSeamFactory? = nil,
        learningSnapshotStore: (any LearningGraphSnapshotStoring)? = nil,
        projectsSeamFactory: FleetProjectsSeamFactory? = nil,
        projectsSnapshotStore: (any ProjectsSnapshotStoring)? = nil,
        health: any ConnectionHealthAccumulating,
        biometrics: any AppLockBiometricAuth = NeverLockBiometricAuth(),
        seedRegistrations: [GatewayRegistration] = [],
        voiceEngineFactory: FleetVoiceEngineFactory? = nil
    ) {
        self.registry = registry
        self.roster = roster
        self.cache = cache
        self.sessionList = sessionList
        self.connectionFactory = connectionFactory
        self.conversationFactory = conversationFactory
        self.kanbanWatcherFactory = kanbanWatcherFactory
        self.managementSeamFactory = managementSeamFactory
        self.learningSeamFactory = learningSeamFactory
        self.learningSnapshotStore_ = learningSnapshotStore
        self.projectsSeamFactory = projectsSeamFactory
        self.projectsSnapshotStore_ = projectsSnapshotStore
        self.health = health
        self.biometrics = biometrics
        self.seedRegistrations = seedRegistrations
        self.voiceEngineFactory = voiceEngineFactory
    }

    // MARK: Load / refresh

    /// Load gateways from the registry. On a truly empty registry, seeds the
    /// known gateways (DEBUG simulator walkthrough) — never overrides a
    /// user-managed fleet.
    public func load() async {
        // P0-4: FIRST rebuild the registry from the durable record store so a
        // user-added gateway survives app close / relaunch (never-connected
        /// entries included, restored disconnected). Restore runs BEFORE the
        /// seeding check so a restored user fleet suppresses seeding.
        do {
            _ = try await registry.restorePersistedGateways()
        } catch {
            // A broken record store must not brick launch — log and continue
            // with the (possibly empty) in-memory registry.
            #if DEBUG
            print("P0-4 gateway restore failed: \(error)")
            #endif
        }
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
        // H2: restore persisted health stats for any registered gateway the
        // accumulator has not observed this session (e.g. a gateway re-added
        // after an app restart — the registry is in-memory, the health store
        // is not). Live entries are untouched by the accumulator's guard.
        await health.rehydrate(gatewayIDs: gateways.map(\.id))
        healthStats = await health.snapshot()
    }

    /// Begins a tracked roster refresh and returns its generation token used
    /// to fence settlement against newer overlapping refreshes (the
    /// `OnboardingViewModel.beginOperation()` reference pattern).
    private func beginRosterRefresh() -> Int {
        rosterGeneration += 1
        return rosterGeneration
    }

    /// Refresh the union fleet roster (M8). Never throws for a single-gateway
    /// outage (partial-availability contract).
    ///
    /// t_e77c614c: generation-fenced — a rapid retap starts a newer refresh
    /// whose token supersedes any still-in-flight older one; the stale
    /// completion is silently dropped so observable state always reflects
    /// only the most recent refresh.
    public func refreshRoster() async {
        let token = beginRosterRefresh()
        isRefreshing = true
        let snapshot = await roster.refreshRoster()
        // Stale completion: a newer refresh owns settlement — silently drop
        // the result (observable state stays what the newest refresh set).
        guard token == rosterGeneration else { return }
        rosterSnapshot = snapshot
        isRefreshing = false
    }

    /// H2: copy the latest connection-health snapshots into the observable
    /// state (the accumulator is fed continuously by the composition root).
    public func refreshHealthStats() async {
        healthStats = await health.snapshot()
    }

    // MARK: Connection lifecycle (runtime-owned, observable)

    /// Connect to a gateway: `connecting` → `connected`, or `failed(status)`.
    /// Idempotent-safe: a connect on an already-connecting OR already-connected
    /// gateway is ignored. (P0-7: the transport's `connect()` is itself now
    /// idempotent from `.open`, but the guard also prevents redundant work and
    /// keeps the observable lifecycle from flapping.)
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

    /// P0-7 multiplexer presence for one bot route, from the latest roster
    /// snapshot (fail closed: no snapshot yet → `.unknown`, which renders
    /// offline-gray — never a fabricated online).
    public func botPresence(for route: Route) -> BotPresence {
        rosterSnapshot?.botPresence(for: route) ?? .unknown
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
        // P1-8: retire session resources with the gateway — tear down the
        // live connection (not just drop the reference), release the
        // conversation session, and clear observable lifecycle state.
        if let connection = activeConnections[id] {
            await connection.disconnect()
        }
        activeConnections[id] = nil
        conversationSessions[id] = nil
        managementSeams[id] = nil
        connectionStates[id] = nil
        testResults[id] = nil
        // H2: drop the gateway's accumulated + persisted health stats.
        await health.forget(gatewayID: id)
        healthStats = await health.snapshot()
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

    // MARK: U3 — conversation sessions (per-gateway, lazily built)

    /// The conversation session for a gateway, building it on first use via
    /// the injected `FleetConversationFactory` (one per gateway; survives view
    /// teardowns so a reconnect mid-conversation stays on the same transport).
    /// Returns `nil` when the factory is not wired or the gateway is absent
    /// (fail closed).
    public func conversationSession(for gatewayID: GatewayID) -> (any ConversationSessionProviding)? {
        if let existing = conversationSessions[gatewayID] { return existing }
        guard let factory = conversationFactory,
              let gateway = gateways.first(where: { $0.id == gatewayID }) else { return nil }
        let session = factory(gateway, nil)
        conversationSessions[gatewayID] = session
        return session
    }

    /// Build the U3 Conversation view model for a route (nil when the gateway
    /// has no conversation session wired — the screen renders an unavailable
    /// state, fail closed). R10-T4: the shared voice engine rides along
    /// (fail-closed default inside the VM when nil).
    public func makeConversationViewModel(route: Route, sessionID: String?) -> ConversationViewModel? {
        guard let session = conversationSession(for: route.gatewayID) else { return nil }
        return ConversationViewModel(
            session: session,
            cache: cache,
            route: route,
            sessionID: sessionID,
            biometrics: biometrics,
            voice: voiceEngineFactory?()
        )
    }

    // MARK: Kanban board (t_3b321b7b)

    /// Build the read-only kanban board watcher for a gateway. Nil when no
    /// factory is wired (the screen renders its unavailable state, fail
    /// closed).
    public func makeKanbanWatcher(for gateway: FleetGateway) -> (any KanbanBoardWatching)? {
        kanbanWatcherFactory?(gateway)
    }

    // MARK: Management panes (R9-T5/T6 — cron + skills)

    /// Build the management seam for a gateway. Nil when no factory is
    /// wired (the panes render their unavailable state, fail closed).
    public func makeManagementSeam(for gatewayID: GatewayID) -> (any GatewayManagementProviding)? {
        if let existing = managementSeams[gatewayID] { return existing }
        guard let factory = managementSeamFactory,
              let gateway = gateways.first(where: { $0.id == gatewayID }) else { return nil }
        let seam = factory(gateway)
        managementSeams[gatewayID] = seam
        return seam
    }

    // MARK: Memory graph (R9-T7 — learning star map)

    /// Build the learning seam for a gateway. Nil when no factory is wired
    /// (the pane renders its unavailable state, fail closed).
    public func makeLearningSeam(for gatewayID: GatewayID) -> (any GatewayLearningProviding)? {
        if let existing = learningSeams[gatewayID] { return existing }
        guard let factory = learningSeamFactory,
              let gateway = gateways.first(where: { $0.id == gatewayID }) else { return nil }
        let seam = factory(gateway)
        learningSeams[gatewayID] = seam
        return seam
    }

    /// The learning-graph snapshot store (offline browse), when wired.
    public var learningSnapshotStore: (any LearningGraphSnapshotStoring)? {
        learningSnapshotStore_
    }

    // MARK: Projects browser (R10-T3 — remote file browser)

    /// Build the projects seam for a gateway. Nil when no factory is
    /// wired (the browser renders its unavailable state, fail closed).
    public func makeProjectsSeam(for gatewayID: GatewayID) -> (any GatewayProjectsProviding)? {
        if let existing = projectsSeams[gatewayID] { return existing }
        guard let factory = projectsSeamFactory,
              let gateway = gateways.first(where: { $0.id == gatewayID }) else { return nil }
        let seam = factory(gateway)
        projectsSeams[gatewayID] = seam
        return seam
    }

    /// The projects-tree snapshot store (offline browse), when wired.
    public var projectsSnapshotStore: (any ProjectsSnapshotStoring)? {
        projectsSnapshotStore_
    }
}
