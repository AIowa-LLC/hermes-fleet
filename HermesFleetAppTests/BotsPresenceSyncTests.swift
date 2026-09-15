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

    func testBotsEntryAndConnectUseTheNarrowSynchronizationSeams() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let appEnvironment = try String(contentsOf: root.appendingPathComponent("Packages/FleetUI/Sources/FleetUI/AppEnvironment.swift"), encoding: .utf8)
        let rosterView = try String(contentsOf: root.appendingPathComponent("Packages/FleetUI/Sources/FleetUI/FleetRosterView.swift"), encoding: .utf8)
        XCTAssertTrue(appEnvironment.contains("scheduleRosterSyncAfterConnectionRepair"))
        XCTAssertTrue(appEnvironment.contains("if connectionStates[id] == .connected"))
        XCTAssertTrue(rosterView.contains("await environment.refreshSummaryIfDue()"))
    }
}
