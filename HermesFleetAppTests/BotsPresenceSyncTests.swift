import XCTest
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

/// Regression coverage for the stale Bots presence seen after a gateway
/// transport recovered. The tests exercise the AppEnvironment seam rather
/// than making presence a side effect of connection state.
@MainActor
final class BotsPresenceSyncTests: XCTestCase {
    private let workstation = GatewayID(rawValue: "workstation")
    private let arch = GatewayID(rawValue: "arch")

    private final class SyncConnection: GatewayConnectivityProviding, @unchecked Sendable {
        let gatewayID: GatewayID
        let error: GatewayConnectivityError?
        private(set) var connectCount = 0

        init(gatewayID: GatewayID, error: GatewayConnectivityError? = nil) {
            self.gatewayID = gatewayID
            self.error = error
        }

        var status: GatewayStatus { error == nil ? .online : .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {
            connectCount += 1
            if let error { throw error }
        }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
    }

    private final class SyncRoster: FleetRosterProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: FleetRosterSnapshot
        private var count = 0
        private var open = true
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(_ snapshot: FleetRosterSnapshot) { self.snapshot = snapshot }

        var refreshCount: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        func set(_ snapshot: FleetRosterSnapshot) {
            lock.lock(); defer { lock.unlock() }
            self.snapshot = snapshot
        }

        func closeGate() {
            lock.lock(); defer { lock.unlock() }
            open = false
        }

        func openGate() {
            lock.lock()
            open = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        private func begin() -> (FleetRosterSnapshot, Bool) {
            lock.lock()
            count += 1
            let current = snapshot
            let shouldWait = !open
            lock.unlock()
            return (current, shouldWait)
        }

        private func currentSnapshot() -> FleetRosterSnapshot {
            lock.lock(); defer { lock.unlock() }
            return snapshot
        }

        func refreshRoster() async -> FleetRosterSnapshot {
            let (current, shouldWait) = begin()
            if shouldWait {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if open {
                        lock.unlock()
                        continuation.resume()
                    } else {
                        waiters.append(continuation)
                        lock.unlock()
                    }
                }
                return currentSnapshot()
            }
            return current
        }
    }

    /// FB2: a connection whose `status` can flip to `.online` on its own
    /// (simulating the transport's own reconnect landing) WITHOUT another
    /// `connect()` call — the exact shape of a self-healing socket the
    /// explicit `connect(to:)`/`scheduleAutoReconnect()` paths never see.
    /// `lastDisconnectReason()` stays nil (the protocol default: no retryable
    /// classification), so the auto-reconnect ladder never fires either —
    /// isolating the connection-watch `.online` repair branch under test.
    private final class SelfHealingConnection: GatewayConnectivityProviding, @unchecked Sendable {
        let gatewayID: GatewayID
        private let lock = NSLock()
        private var _status: GatewayStatus
        private(set) var connectCount = 0

        init(gatewayID: GatewayID, initialStatus: GatewayStatus) {
            self.gatewayID = gatewayID
            self._status = initialStatus
        }

        var status: GatewayStatus {
            lock.lock(); defer { lock.unlock() }
            return _status
        }

        func setStatus(_ status: GatewayStatus) {
            lock.lock()
            _status = status
            lock.unlock()
        }

        func connect() async throws {
            connectCount += 1
        }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
    }

    private struct EmptySessionList: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private struct EmptyHealth: ConnectionHealthAccumulating {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    private func route(_ gateway: GatewayID, _ profile: String) -> Route {
        Route(gatewayID: gateway, profileSlug: ProfileSlug(rawValue: profile))
    }

    private func snapshot(
        workstationOutcome: GatewayRosterOutcome,
        archOutcome: GatewayRosterOutcome,
        bots: [FleetBot] = []
    ) -> FleetRosterSnapshot {
        var roster = FleetRoster()
        roster.upsertGateway(FleetGateway(id: workstation, displayName: "Workstation"))
        roster.upsertGateway(FleetGateway(id: arch, displayName: "Arch"))
        for bot in bots { roster.upsertBot(bot) }
        return FleetRosterSnapshot(
            roster: roster,
            gatewayOutcomes: [workstation: workstationOutcome, arch: archOutcome])
    }

    private func registration(_ id: GatewayID) -> GatewayRegistration {
        GatewayRegistration(
            id: id,
            displayName: id.rawValue,
            endpoint: URL(string: "http://127.0.0.1:9000")!)
    }

    private func makeEnvironment(
        roster: SyncRoster,
        connectionErrors: [GatewayID: GatewayConnectivityError] = [:]
    ) async -> (AppEnvironment, [GatewayID: SyncConnection]) {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in SyncConnection(gatewayID: gateway.id) })
        let connections = Dictionary(uniqueKeysWithValues: [workstation, arch].map { id in
            (id, SyncConnection(gatewayID: id, error: connectionErrors[id]))
        })
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: EmptySessionList(),
            connectionFactory: { gateway, _ in
                connections[gateway.id] ?? SyncConnection(gatewayID: gateway.id)
            },
            health: EmptyHealth(),
            seedRegistrations: [registration(workstation), registration(arch)])
        await environment.load()
        return (environment, connections)
    }

    /// FB2: builds an environment around explicit `SelfHealingConnection`
    /// instances (rather than the scripted `SyncConnection`) so a test can
    /// flip a gateway's live `status` without ever calling `connect()` again.
    private func makeEnvironment(
        roster: SyncRoster,
        connections: [GatewayID: SelfHealingConnection],
        recoveryTiming: ConnectionRecoveryTiming = ConnectionRecoveryTiming(watchInterval: 0.1)
    ) async -> AppEnvironment {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in SyncConnection(gatewayID: gateway.id) })
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: EmptySessionList(),
            connectionFactory: { gateway, _ in
                let resolved: any GatewayConnectivityProviding = connections[gateway.id] ?? SyncConnection(gatewayID: gateway.id)
                return resolved
            },
            health: EmptyHealth(),
            seedRegistrations: [self.registration(self.workstation), self.registration(self.arch)],
            recoveryTiming: recoveryTiming)
        await environment.load()
        return environment
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    func testSuccessfulConnectAutomaticallyRefreshesRosterPresence() async {
        let bot = FleetBot(route: route(workstation, "researcher"), displayName: "Researcher")
        let roster = SyncRoster(snapshot(
            workstationOutcome: .failed(status: .offline, detail: "down"),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        let (environment, connections) = await makeEnvironment(roster: roster)

        await environment.refreshRoster()
        XCTAssertEqual(environment.botPresence(for: bot.route), .unreachable)
        roster.set(snapshot(
            workstationOutcome: .loaded(profileCount: 1),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        await environment.connect(to: workstation)

        XCTAssertEqual(environment.connectionStates[workstation], .connected)
        let recovered = await waitUntil { environment.botPresence(for: bot.route) == .reachable }
        XCTAssertTrue(recovered)
        XCTAssertEqual(connections[workstation]?.connectCount, 1)
        XCTAssertGreaterThanOrEqual(roster.refreshCount, 2)
    }

    func testFailedConnectDoesNotFabricateReachablePresence() async {
        let bot = FleetBot(route: route(workstation, "researcher"), displayName: "Researcher")
        let roster = SyncRoster(snapshot(
            workstationOutcome: .failed(status: .offline, detail: "down"),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        let (environment, _) = await makeEnvironment(
            roster: roster, connectionErrors: [workstation: .unreachable])
        await environment.refreshRoster()
        let before = roster.refreshCount

        await environment.connect(to: workstation)
        XCTAssertEqual(environment.connectionStates[workstation], .failed(.offline))
        XCTAssertEqual(environment.botPresence(for: bot.route), .unreachable)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(roster.refreshCount, before)
    }

    func testRepeatedConnectIsIdempotentAndDoesNotRefreshStorm() async {
        let roster = SyncRoster(snapshot(
            workstationOutcome: .loaded(profileCount: 0),
            archOutcome: .loaded(profileCount: 0)))
        let (environment, connections) = await makeEnvironment(roster: roster)
        await environment.connect(to: workstation)
        let started = await waitUntil { roster.refreshCount >= 1 }
        XCTAssertTrue(started)
        let settled = await waitUntil { !environment.isRefreshing && roster.refreshCount >= 1 }
        XCTAssertTrue(settled)
        let refreshes = roster.refreshCount

        await environment.connect(to: workstation)
        await environment.connect(to: workstation)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(connections[workstation]?.connectCount, 1)
        XCTAssertEqual(roster.refreshCount, refreshes)
    }

    func testRestorationAlsoRefreshesPresenceAndLeavesOtherGatewayHonest() async {
        let bot = FleetBot(route: route(workstation, "researcher"), displayName: "Researcher")
        let other = FleetBot(route: route(arch, "default"), displayName: "Default")
        let roster = SyncRoster(snapshot(
            workstationOutcome: .loaded(profileCount: 1),
            archOutcome: .loaded(profileCount: 1), bots: [bot, other]))
        let (environment, connections) = await makeEnvironment(roster: roster)
        await environment.connect(to: workstation)
        let initiallyReachable = await waitUntil { environment.botPresence(for: bot.route) == .reachable }
        XCTAssertTrue(initiallyReachable)

        await environment.disconnectAll()
        roster.set(snapshot(
            workstationOutcome: .failed(status: .offline, detail: "suspended"),
            archOutcome: .failed(status: .offline, detail: "still down"),
            bots: [bot, other]))
        await environment.refreshRoster()
        XCTAssertEqual(environment.botPresence(for: bot.route), .unreachable)

        roster.set(snapshot(
            workstationOutcome: .loaded(profileCount: 1),
            archOutcome: .failed(status: .offline, detail: "still down"),
            bots: [bot, other]))
        await environment.restoreIntendedConnections()
        let restored = await waitUntil { environment.botPresence(for: bot.route) == .reachable }
        XCTAssertTrue(restored)
        XCTAssertEqual(connections[workstation]?.connectCount, 2)
        XCTAssertEqual(environment.botPresence(for: other.route), .unreachable)
    }

    func testConnectDuringRosterRefreshCoalescesOneTrailingObservation() async {
        let bot = FleetBot(route: route(workstation, "researcher"), displayName: "Researcher")
        let roster = SyncRoster(snapshot(
            workstationOutcome: .failed(status: .offline, detail: "down"),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        let (environment, _) = await makeEnvironment(roster: roster)
        roster.closeGate()
        let refresh = Task { await environment.refreshRoster() }
        let refreshStarted = await waitUntil { environment.isRefreshing }
        XCTAssertTrue(refreshStarted)
        roster.set(snapshot(
            workstationOutcome: .loaded(profileCount: 1),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        await environment.connect(to: workstation)
        XCTAssertEqual(roster.refreshCount, 1)
        roster.openGate()
        await refresh.value
        let trailingRefreshRecovered = await waitUntil { environment.botPresence(for: bot.route) == .reachable }
        XCTAssertTrue(trailingRefreshRecovered)
        XCTAssertEqual(roster.refreshCount, 2)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(roster.refreshCount, 2)
    }

    // MARK: FB2 — TestFlight Build 90 #2 ("Bot shows offline but is online")
    //
    // Root cause: `connect(to:)`'s own success branch already re-armed the
    // roster (the tests above). Two OTHER paths that can observe a gateway
    // becoming reachable again did not: (1) the connection-watch loop noticing
    // the transport's own `.online` self-heal, and (2) the manual §13 "Test
    // Connection" probe (Gateway management's "check status", per the
    // tester). Both used to correct only `connectionStates` and leave
    // `rosterSnapshot` — and therefore Bot Detail's presence — on the stale
    // failed/ghost outcome until an unrelated due-check happened to land.

    /// The transport repairs itself (its own `status` flips to `.online`)
    /// with NO further `connect()` call. The connection watch must notice on
    /// its next tick and re-arm the roster exactly like an explicit repair —
    /// presence recovers, and `connectCount` proves no reconnect was needed.
    func testSelfHealingConnectionAutomaticallyRefreshesRosterPresence() async {
        let bot = FleetBot(route: route(workstation, "researcher"), displayName: "Researcher")
        let roster = SyncRoster(snapshot(
            workstationOutcome: .failed(status: .offline, detail: "down"),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        let workstationConnection = SelfHealingConnection(gatewayID: workstation, initialStatus: .offline)
        let archConnection = SelfHealingConnection(gatewayID: arch, initialStatus: .online)
        let environment = await makeEnvironment(
            roster: roster,
            connections: [workstation: workstationConnection, arch: archConnection])
        await environment.refreshRoster()

        // Establish the failed connection (mirrors the tester's dropped
        // gateway) — the watch loop starts even though connect() fails.
        await environment.connect(to: workstation)
        XCTAssertEqual(environment.connectionStates[workstation], .failed(.offline))
        XCTAssertEqual(environment.botPresence(for: bot.route), .unreachable)
        let connectCountAtFailure = workstationConnection.connectCount

        // The gateway becomes reachable again purely at the transport level.
        roster.set(snapshot(
            workstationOutcome: .loaded(profileCount: 1),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        workstationConnection.setStatus(.online)

        let recovered = await waitUntil { environment.botPresence(for: bot.route) == .reachable }
        XCTAssertTrue(recovered)
        XCTAssertEqual(environment.connectionStates[workstation], .connected)
        // No second connect() was needed — this is the watch's own `.online`
        // repair branch, not the auto-reconnect ladder.
        XCTAssertEqual(workstationConnection.connectCount, connectCountAtFailure)
    }

    /// Once the watch loop has already caught the repair, further ticks with
    /// the connection still `.online` and the roster already `.loaded` must
    /// NOT keep re-triggering roster refreshes (no polling storm).
    func testSelfHealingConnectionDoesNotRefreshStormOnceSettled() async {
        let roster = SyncRoster(snapshot(
            workstationOutcome: .failed(status: .offline, detail: "down"),
            archOutcome: .loaded(profileCount: 0)))
        let workstationConnection = SelfHealingConnection(gatewayID: workstation, initialStatus: .offline)
        let archConnection = SelfHealingConnection(gatewayID: arch, initialStatus: .online)
        let environment = await makeEnvironment(
            roster: roster,
            connections: [workstation: workstationConnection, arch: archConnection])

        await environment.connect(to: workstation)
        roster.set(snapshot(
            workstationOutcome: .loaded(profileCount: 0),
            archOutcome: .loaded(profileCount: 0)))
        workstationConnection.setStatus(.online)
        let settled = await waitUntil { environment.connectionStates[self.workstation] == .connected }
        XCTAssertTrue(settled)
        _ = await waitUntil { roster.refreshCount >= 2 }
        let refreshesAfterRepair = roster.refreshCount

        // Several more watch ticks with nothing changed.
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(roster.refreshCount, refreshesAfterRepair)
    }

    /// The manual §13 Test Connection probe ("check status" in the gateway
    /// menu) finding the gateway reachable again must re-arm the roster the
    /// same way, so Bot Detail is not left waiting on an unrelated due-check.
    func testManualTestConnectionAutomaticallyRefreshesStalePresence() async {
        let bot = FleetBot(route: route(workstation, "researcher"), displayName: "Researcher")
        let roster = SyncRoster(snapshot(
            workstationOutcome: .failed(status: .offline, detail: "down"),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        let credentials = InMemoryCredentialStore()
        // The registry's OWN connection factory answers online — this is the
        // probe's transport, independent of AppEnvironment's connections.
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in SyncConnection(gatewayID: gateway.id) })
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: EmptySessionList(),
            connectionFactory: { gateway, _ in SyncConnection(gatewayID: gateway.id, error: .unreachable) },
            health: EmptyHealth(),
            seedRegistrations: [registration(workstation), registration(arch)])
        await environment.load()
        await environment.refreshRoster()
        XCTAssertEqual(environment.botPresence(for: bot.route), .unreachable)

        roster.set(snapshot(
            workstationOutcome: .loaded(profileCount: 1),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        try? await environment.testConnection(to: workstation)
        XCTAssertEqual(environment.connectionStates[workstation], .connected)

        let recovered = await waitUntil { environment.botPresence(for: bot.route) == .reachable }
        XCTAssertTrue(recovered)
    }

    /// Negative: a Test Connection probe that STILL classifies the gateway as
    /// failed must not fabricate presence or force an unneeded roster
    /// refresh — the failed truth (and any other gateway's independent
    /// failure) is preserved.
    func testManualTestConnectionStillFailedDoesNotRefreshOrFabricatePresence() async {
        let bot = FleetBot(route: route(workstation, "researcher"), displayName: "Researcher")
        let other = FleetBot(route: route(arch, "default"), displayName: "Default")
        let roster = SyncRoster(snapshot(
            workstationOutcome: .failed(status: .offline, detail: "down"),
            archOutcome: .failed(status: .offline, detail: "also down"), bots: [bot, other]))
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in SyncConnection(gatewayID: gateway.id, error: .unreachable) })
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: EmptySessionList(),
            connectionFactory: { gateway, _ in SyncConnection(gatewayID: gateway.id, error: .unreachable) },
            health: EmptyHealth(),
            seedRegistrations: [registration(workstation), registration(arch)])
        await environment.load()
        await environment.refreshRoster()
        let before = roster.refreshCount

        try? await environment.testConnection(to: workstation)
        XCTAssertEqual(environment.connectionStates[workstation], .failed(.offline))
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(roster.refreshCount, before)
        XCTAssertEqual(environment.botPresence(for: bot.route), .unreachable)
        XCTAssertEqual(environment.botPresence(for: other.route), .unreachable)
    }

    // MARK: FB2 (gap) — Bot Detail appearance while CONNECTED the whole time
    //
    // The two triggers above only fire on a `.connected`/`.online`
    // TRANSITION or a manual Test Connection. A gateway can stay
    // `.connected` throughout while one later roster refresh times out
    // (`.failed`) and the summary backoff climbs to 120-300s — no transition
    // and no manual probe ever happens, so Bot Detail was left on the ghost
    // outcome for up to 5 minutes. `refreshRosterIfStaleForVisibleBot(on:)`
    // closes that gap from Bot Detail's own `.task`.

    /// Connected + failed outcome (backoff pending) → the appearance trigger
    /// forces one authoritative refresh and presence recovers.
    func testAppearanceTriggerRefreshesStaleOutcomeWhileStillConnected() async {
        let bot = FleetBot(route: route(workstation, "researcher"), displayName: "Researcher")
        let roster = SyncRoster(snapshot(
            workstationOutcome: .loaded(profileCount: 1),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        let (environment, _) = await makeEnvironment(roster: roster)

        await environment.connect(to: workstation)
        let initiallyReachable = await waitUntil { environment.botPresence(for: bot.route) == .reachable }
        XCTAssertTrue(initiallyReachable)
        XCTAssertEqual(environment.connectionStates[workstation], .connected)

        // One later background observation times out while the connection
        // itself stays up — no transition, so neither existing trigger fires.
        roster.set(snapshot(
            workstationOutcome: .failed(status: .offline, detail: "timed out"),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        await environment.refreshRoster()
        XCTAssertEqual(environment.connectionStates[workstation], .connected)
        XCTAssertEqual(environment.botPresence(for: bot.route), .unreachable)
        let refreshesBeforeAppearance = roster.refreshCount

        // The gateway is reachable again; Bot Detail appears.
        roster.set(snapshot(
            workstationOutcome: .loaded(profileCount: 1),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        environment.refreshRosterIfStaleForVisibleBot(on: workstation)

        let recovered = await waitUntil { environment.botPresence(for: bot.route) == .reachable }
        XCTAssertTrue(recovered)
        XCTAssertGreaterThan(roster.refreshCount, refreshesBeforeAppearance)
    }

    /// Already `.loaded` → the appearance trigger is a no-op (no redundant
    /// refresh on every Bot Detail visit).
    func testAppearanceTriggerDoesNothingWhenOutcomeAlreadyLoaded() async {
        let bot = FleetBot(route: route(workstation, "researcher"), displayName: "Researcher")
        let roster = SyncRoster(snapshot(
            workstationOutcome: .loaded(profileCount: 1),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        let (environment, _) = await makeEnvironment(roster: roster)

        await environment.connect(to: workstation)
        let reachable = await waitUntil { environment.botPresence(for: bot.route) == .reachable }
        XCTAssertTrue(reachable)
        let refreshesBeforeAppearance = roster.refreshCount

        environment.refreshRosterIfStaleForVisibleBot(on: workstation)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(roster.refreshCount, refreshesBeforeAppearance)
    }

    /// A DISCONNECTED gateway never gets a refresh forced on it by merely
    /// appearing in Bot Detail — it stays honestly offline instead of the
    /// trigger fabricating an unearned refresh cycle.
    func testAppearanceTriggerDoesNothingForDisconnectedGateway() async {
        let bot = FleetBot(route: route(workstation, "researcher"), displayName: "Researcher")
        let roster = SyncRoster(snapshot(
            workstationOutcome: .failed(status: .offline, detail: "down"),
            archOutcome: .loaded(profileCount: 0), bots: [bot]))
        let (environment, _) = await makeEnvironment(
            roster: roster, connectionErrors: [workstation: .unreachable])
        await environment.refreshRoster()
        XCTAssertNotEqual(environment.connectionStates[workstation], .connected)
        let refreshesBeforeAppearance = roster.refreshCount

        environment.refreshRosterIfStaleForVisibleBot(on: workstation)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(roster.refreshCount, refreshesBeforeAppearance)
        XCTAssertEqual(environment.botPresence(for: bot.route), .unreachable)
    }

    func testBotsEntryAndConnectUseTheNarrowSynchronizationSeams() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let appEnvironment = try String(contentsOf: root.appendingPathComponent("Packages/FleetUI/Sources/FleetUI/AppEnvironment.swift"), encoding: .utf8)
        let rosterView = try String(contentsOf: root.appendingPathComponent("Packages/FleetUI/Sources/FleetUI/FleetRosterView.swift"), encoding: .utf8)
        XCTAssertTrue(appEnvironment.contains("scheduleRosterSyncAfterConnectionRepair"))
        XCTAssertTrue(appEnvironment.contains("if connectionStates[id] == .connected"))
        XCTAssertTrue(rosterView.contains("await environment.refreshSummaryIfDue()"))
    }
}
