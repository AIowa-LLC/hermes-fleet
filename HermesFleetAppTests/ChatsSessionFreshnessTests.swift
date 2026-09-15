import XCTest
import FleetCore
import FleetNetworking
import FleetPersistence
import FleetSecurity
import FleetUI

/// Regression coverage for cache-first Chats refreshes. These tests exercise
/// the environment seam directly so the UI remains a pure projection of
/// cached rows and refresh state.
@MainActor
final class ChatsSessionFreshnessTests: XCTestCase {
    private final class CountingSessionList: SessionListProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [Route] = []
        private var inFlight = 0
        private var maxInFlight = 0
        private var failures: Set<Route>
        private let delay: TimeInterval

        init(failures: Set<Route> = [], delay: TimeInterval = 0) {
            self.failures = failures
            self.delay = delay
        }

        private func begin(_ route: Route) {
            lock.lock()
            routes.append(route)
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            lock.unlock()
        }

        private func end(_ route: Route) -> Bool {
            lock.lock()
            inFlight -= 1
            let failed = failures.contains(route)
            lock.unlock()
            return failed
        }

        var fetches: [Route] { lock.lock(); defer { lock.unlock() }; return routes }
        var fetchCount: Int { lock.lock(); defer { lock.unlock() }; return routes.count }
        var observedMaxInFlight: Int { lock.lock(); defer { lock.unlock() }; return maxInFlight }

        func setFailures(_ routes: Set<Route>) {
            lock.lock(); failures = routes; lock.unlock()
        }

        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
            begin(route)
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if end(route) { throw RosterError.notConnected }
            return [SessionSummary(
                id: "\(route.id).s1", title: "Conversation", preview: "fixture",
                startedAt: 1_755_000_000, messageCount: 1, source: "test")]
        }
    }

    private final class GatedSessionList: SessionListProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var release: CheckedContinuation<Void, Never>?

        private func markStarted(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            started = true
            release = continuation
            lock.unlock()
        }

        private var hasStarted: Bool {
            lock.lock(); defer { lock.unlock() }
            return started
        }

        func waitUntilStarted() async {
            while !hasStarted {
                await Task.yield()
            }
        }

        func releaseFetch() {
            lock.lock()
            let continuation = release
            release = nil
            lock.unlock()
            continuation?.resume()
        }

        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
            await withCheckedContinuation { markStarted($0) }
            return [SessionSummary(
                id: "old.\(route.id)", title: "Old", preview: "stale",
                startedAt: 1_755_000_000, messageCount: 1, source: "test")]
        }
    }

    private final class EmptyHealth: ConnectionHealthAccumulating, @unchecked Sendable {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    private final class MutableRoster: FleetRosterProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var value: FleetRosterSnapshot
        init(_ value: FleetRosterSnapshot) { self.value = value }
        func set(_ value: FleetRosterSnapshot) { lock.lock(); self.value = value; lock.unlock() }
        private func capture() -> FleetRosterSnapshot {
            lock.lock(); defer { lock.unlock() }; return value
        }
        func refreshRoster() async -> FleetRosterSnapshot {
            capture()
        }
    }

    private final class ScriptedConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        init(_ gatewayID: GatewayID) { self.gatewayID = gatewayID }
        var status: GatewayStatus { .online }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }
    }

    private func route(_ gateway: String, _ profile: String) -> Route {
        Route(gatewayID: GatewayID(rawValue: gateway), profileSlug: ProfileSlug(rawValue: profile))
    }

    private func snapshot(routes: [Route], failed: Set<GatewayID> = []) -> FleetRosterSnapshot {
        var roster = FleetRoster()
        var outcomes: [GatewayID: GatewayRosterOutcome] = [:]
        let gatewayIDs = Set(routes.map(\.gatewayID)).union(failed)
        for id in gatewayIDs {
            roster.upsertGateway(FleetGateway(id: id, displayName: id.rawValue, endpoint: nil))
            outcomes[id] = failed.contains(id)
                ? .failed(status: .offline, detail: "down")
                : .loaded(profileCount: routes.filter { $0.gatewayID == id }.count)
        }
        for route in routes {
            roster.upsertBot(FleetBot(route: route, displayName: route.profileSlug.rawValue))
        }
        return FleetRosterSnapshot(roster: roster, gatewayOutcomes: outcomes)
    }

    private func makeEnvironment(
        sessionList: SessionListProviding,
        initialSnapshot: FleetRosterSnapshot? = nil
    ) async -> (AppEnvironment, MutableRoster) {
        let registry = GatewayRegistryService(
            credentials: InMemoryCredentialStore(),
            connectionFactory: { gateway, _ in ScriptedConnection(gateway.id) })
        _ = try! await registry.addGateway(GatewayRegistration(
            id: GatewayID(rawValue: "workstation"), displayName: "Workstation",
            endpoint: URL(string: "http://127.0.0.1:9100")!))
        _ = try! await registry.addGateway(GatewayRegistration(
            id: GatewayID(rawValue: "arch"), displayName: "Arch",
            endpoint: URL(string: "http://127.0.0.1:9101")!))
        let roster = MutableRoster(initialSnapshot ?? FleetRosterSnapshot())
        let environment = AppEnvironment(
            registry: registry, roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: sessionList,
            connectionFactory: { gateway, _ in ScriptedConnection(gateway.id) },
            health: EmptyHealth())
        await environment.load()
        return (environment, roster)
    }

    func testMissingRouteIsStaleAndSuccessfulReadBecomesFresh() async {
        let seam = CountingSessionList()
        let (environment, _) = await makeEnvironment(sessionList: seam)
        let route = route("workstation", "default")
        XCTAssertTrue(environment.needsSessionRefresh(route))

        await environment.loadSessions(for: route)
        XCTAssertNotNil(environment.sessionsLastObserved(route))
        XCTAssertFalse(environment.needsSessionRefresh(route))
    }

    func testFailedReadRetainsRowsAndDoesNotStampFreshness() async {
        let seam = CountingSessionList()
        let (environment, _) = await makeEnvironment(sessionList: seam)
        let route = route("workstation", "default")
        await environment.loadSessions(for: route)
        environment.invalidateSessions(for: route)
        seam.setFailures([route])

        await environment.loadSessions(for: route)

        XCTAssertTrue(environment.needsSessionRefresh(route))
        XCTAssertNotNil(environment.sessions(for: route))
        XCTAssertNotNil(environment.sessionReadErrors[route])
    }

    func testFreshRoutesSuppressedMissingAndStaleRoutesRefresh() async {
        let seam = CountingSessionList()
        let (environment, _) = await makeEnvironment(sessionList: seam)
        let fresh = route("workstation", "default")
        let missing = route("arch", "default")
        await environment.loadSessions(for: fresh)

        await environment.refreshSessions(routes: [fresh, missing])

        XCTAssertEqual(seam.fetches.filter { $0 == fresh }.count, 1)
        XCTAssertEqual(seam.fetches.filter { $0 == missing }.count, 1)
    }

    func testRapidReentryPerformsZeroRedundantReads() async {
        let seam = CountingSessionList()
        let (environment, _) = await makeEnvironment(sessionList: seam)
        let routes = [route("workstation", "default"), route("arch", "default")]
        await environment.refreshSessions(routes: routes)
        let count = seam.fetchCount

        await environment.refreshSessions(routes: routes, now: Date().addingTimeInterval(3))

        XCTAssertEqual(seam.fetchCount, count)
    }

    func testForceRefreshBypassesFreshness() async {
        let seam = CountingSessionList()
        let (environment, _) = await makeEnvironment(sessionList: seam)
        let routes = [route("workstation", "default"), route("arch", "default")]
        await environment.refreshSessions(routes: routes)
        await environment.refreshSessions(routes: routes, force: true, now: Date().addingTimeInterval(1))
        XCTAssertEqual(seam.fetchCount, 4)
    }

    func testRefreshIsConcurrentButNeverExceedsBound() async {
        let seam = CountingSessionList(delay: 0.05)
        let (environment, _) = await makeEnvironment(sessionList: seam)
        let routes = (0..<10).map { route("workstation", "p\($0)") }
        await environment.refreshSessions(routes: routes)

        XCTAssertEqual(seam.fetchCount, 10)
        XCTAssertGreaterThan(seam.observedMaxInFlight, 1)
        XCTAssertLessThanOrEqual(seam.observedMaxInFlight, 4)
    }

    func testPartialFailureIsIsolatedAndCachedRowsRemain() async {
        let failed = route("workstation", "default")
        let healthy = route("arch", "default")
        let seam = CountingSessionList()
        let (environment, _) = await makeEnvironment(sessionList: seam)
        await environment.loadSessions(for: failed)
        environment.invalidateSessions(for: failed)
        seam.setFailures([failed])

        await environment.refreshSessions(routes: [failed, healthy])

        XCTAssertNotNil(environment.sessions(for: failed))
        XCTAssertNotNil(environment.sessionReadErrors[failed])
        XCTAssertNotNil(environment.sessions(for: healthy))
        XCTAssertNil(environment.sessionReadErrors[healthy])
    }

    func testInvalidationFencesAnInFlightReadFromOverwritingFreshness() async {
        let seam = GatedSessionList()
        let (environment, _) = await makeEnvironment(sessionList: seam)
        let route = route("workstation", "default")
        let read = Task { await environment.loadSessions(for: route) }
        await seam.waitUntilStarted()

        environment.invalidateSessions(for: route)
        seam.releaseFetch()
        await read.value

        XCTAssertNil(environment.sessions(for: route))
        XCTAssertNil(environment.sessionsLastObserved(route))
        XCTAssertTrue(environment.needsSessionRefresh(route))
    }

    func testConversationOpenInvalidatesOnlyItsRoute() async {
        let seam = CountingSessionList()
        let (environment, _) = await makeEnvironment(sessionList: seam)
        let opened = route("workstation", "default")
        let other = route("arch", "default")
        await environment.loadSessions(for: opened)
        await environment.loadSessions(for: other)

        environment.recordConversationOpen(
            route: opened, sessionID: "s1", canonical: false, title: "T", subtitle: "s")

        XCTAssertTrue(environment.needsSessionRefresh(opened))
        XCTAssertFalse(environment.needsSessionRefresh(other))
    }

    func testGatewayRecoveryInvalidatesOnlyRecoveredGatewayRoutes() async {
        let workstation = route("workstation", "default")
        let arch = route("arch", "default")
        let seam = CountingSessionList()
        let (environment, roster) = await makeEnvironment(
            sessionList: seam,
            initialSnapshot: snapshot(routes: [workstation, arch], failed: [arch.gatewayID]))
        await environment.loadSessions(for: workstation)
        await environment.loadSessions(for: arch)
        await environment.refreshRoster()

        roster.set(snapshot(routes: [workstation, arch]))
        await environment.refreshRoster()

        XCTAssertTrue(environment.needsSessionRefresh(arch))
        XCTAssertFalse(environment.needsSessionRefresh(workstation))
    }

    func testCanonicalBotChatAndMultiGatewayRouteIdentityRemainExplicit() async {
        let seam = CountingSessionList()
        let (environment, _) = await makeEnvironment(sessionList: seam)
        let first = route("workstation", "default")
        let second = route("arch", "default")
        await environment.loadSessions(for: first)
        await environment.loadSessions(for: second)

        XCTAssertFalse(environment.isCanonicalBotChat(route: first, sessionID: "not-canonical"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set(environment.sessionsByRoute.keys), [first, second])
    }
}
