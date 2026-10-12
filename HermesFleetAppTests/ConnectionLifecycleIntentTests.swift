import XCTest
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

/// Regression coverage for the distinction between user connection intent and
/// live transport state. Lifecycle teardown must preserve intent, while an
/// explicit Disconnect and fail-closed auth errors remain authoritative.
@MainActor
final class ConnectionLifecycleIntentTests: XCTestCase {
    private final class ScriptedConnection: GatewayConnectivityProviding, @unchecked Sendable {
        let gatewayID: GatewayID
        let connectError: GatewayConnectivityError?
        nonisolated(unsafe) private(set) var connectCount = 0

        init(gatewayID: GatewayID, connectError: GatewayConnectivityError? = nil) {
            self.gatewayID = gatewayID
            self.connectError = connectError
        }

        var status: GatewayStatus { .online }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {
            connectCount += 1
            if let connectError { throw connectError }
        }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
    }

    /// Scripted per-attempt outcome for `RecoveringConnection`.
    private enum RecoveryOutcome {
        case success
        case failure(GatewayConnectivityError, DisconnectReason)
    }

    /// Dogfood r2 (2026-09-23): scripted connection with a MUTABLE status and
    /// a typed disconnect reason — drives the runtime's bounded auto-recovery
    /// (failed connect / post-open drop → policy-gated retry).
    private final class RecoveringConnection: GatewayConnectivityProviding, @unchecked Sendable {
        let gatewayID: GatewayID
        /// Each entry = the outcome of the next connect attempt (exhausted =
        /// success).
        nonisolated(unsafe) var scripted: [RecoveryOutcome]
        nonisolated(unsafe) var statusValue: GatewayStatus = .offline
        nonisolated(unsafe) var reasonValue: DisconnectReason?
        nonisolated(unsafe) private(set) var connectCount = 0

        init(gatewayID: GatewayID, scripted: [RecoveryOutcome]) {
            self.gatewayID = gatewayID
            self.scripted = scripted
        }

        var status: GatewayStatus { statusValue }
        func lastDisconnectReason() async -> DisconnectReason? { reasonValue }

        func connect() async throws {
            connectCount += 1
            let outcome: RecoveryOutcome = scripted.isEmpty ? .success : scripted.removeFirst()
            switch outcome {
            case .success:
                statusValue = .online
                reasonValue = nil
            case .failure(let error, let reason):
                statusValue = GatewayStatus(connectivityError: error)
                reasonValue = reason
                throw error
            }
        }

        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
    }

    /// First connect can be held open while the app backgrounds. A later
    /// attempt succeeds immediately so the test can verify ownership passed
    /// back to foreground restore.
    private final class InterruptedConnection: GatewayConnectivityProviding, @unchecked Sendable {
        let gatewayID: GatewayID
        nonisolated(unsafe) private(set) var connectCount = 0
        nonisolated(unsafe) private(set) var disconnectCount = 0
        nonisolated(unsafe) private(set) var firstConnectStarted = false
        nonisolated(unsafe) var statusValue: GatewayStatus = .offline
        nonisolated(unsafe) private var firstConnectContinuation: CheckedContinuation<Void, Never>?

        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }
        var status: GatewayStatus { statusValue }

        func connect() async throws {
            connectCount += 1
            if connectCount == 1 {
                await withCheckedContinuation { continuation in
                    firstConnectStarted = true
                    firstConnectContinuation = continuation
                }
            }
            statusValue = .online
        }

        func releaseFirstConnect() {
            firstConnectContinuation?.resume()
            firstConnectContinuation = nil
        }

        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func disconnect() async {
            disconnectCount += 1
            statusValue = .offline
        }
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
    }

    private final class DelayedDisconnectConnection: GatewayConnectivityProviding, @unchecked Sendable {
        let gatewayID: GatewayID
        nonisolated(unsafe) private(set) var connectCount = 0
        nonisolated(unsafe) private(set) var disconnectCount = 0
        nonisolated(unsafe) private(set) var firstDisconnectStarted = false
        nonisolated(unsafe) private var firstDisconnectContinuation: CheckedContinuation<Void, Never>?
        nonisolated(unsafe) var statusValue: GatewayStatus = .offline

        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }
        var status: GatewayStatus { statusValue }

        func connect() async throws {
            connectCount += 1
            statusValue = .online
        }

        func releaseFirstDisconnect() {
            firstDisconnectContinuation?.resume()
            firstDisconnectContinuation = nil
        }

        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func disconnect() async {
            disconnectCount += 1
            if disconnectCount == 1 {
                await withCheckedContinuation { continuation in
                    firstDisconnectStarted = true
                    firstDisconnectContinuation = continuation
                }
            }
            statusValue = .offline
        }
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
    }

    private struct EmptyRosterSession: GatewayRosterSession {
        let gatewayID: GatewayID
        var descriptors: [ProfileDescriptor] = []
        var status: GatewayStatus { .online }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] { descriptors }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private struct EmptySessions: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private final class RecordingSessions: SessionListProviding, @unchecked Sendable {
        nonisolated(unsafe) private(set) var fetchedRoutes: [Route] = []
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
            fetchedRoutes.append(route)
            return []
        }
    }

    private struct FailingGatewayDeleteRecordStore: GatewayRecordStoring {
        func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {}
        func deleteGatewayRecord(id: GatewayID) async throws {
            throw GatewayRegistryError.recordStoreFailed("synthetic delete failure")
        }
        func loadGatewayRecords() async throws -> [StoredGatewayRecord] { [] }
    }

    private final class DelayedFirstSessionList: SessionListProviding, @unchecked Sendable {
        nonisolated(unsafe) private(set) var callCount = 0
        nonisolated(unsafe) private(set) var firstReadStarted = false
        nonisolated(unsafe) private var firstReadContinuation: CheckedContinuation<[SessionSummary], Never>?

        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
            callCount += 1
            if callCount == 1 {
                return await withCheckedContinuation { continuation in
                    firstReadStarted = true
                    firstReadContinuation = continuation
                }
            }
            return [SessionSummary(id: "fresh", title: "Fresh after unlock", startedAt: 2, lastActive: 2, messageCount: 1)]
        }

        func releaseFirstRead() {
            firstReadContinuation?.resume(returning: [
                SessionSummary(id: "stale", title: "Stale pre-lock response", startedAt: 1, lastActive: 1, messageCount: 1)
            ])
            firstReadContinuation = nil
        }
    }

    private struct TestHealth: ConnectionHealthAccumulating {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    private func registration(_ id: String) -> GatewayRegistration {
        GatewayRegistration(
            id: GatewayID(rawValue: id), displayName: id,
            endpoint: URL(string: "http://127.0.0.1:\(9000 + id.count)")!)
    }

    /// Scripted conversation session for restore tests (status-driven, no
    /// transport). Mirrors the suite's ScriptedConnection shape.
    private final class ScriptedConversationSession: ConversationSessionProviding, @unchecked Sendable {
        let gatewayID: GatewayID
        nonisolated(unsafe) var statusValue: GatewayStatus = .offline
        nonisolated(unsafe) var connectCount = 0
        let conversation: any ConversationProviding = UnreachableConversation()
        let replay: any ReplayProviding = UnreachableReplay()
        let history: any SessionHistoryProviding = UnreachableHistory()

        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }

        var status: GatewayStatus { statusValue }
        var liveness: ConnectionLivenessSnapshot? { nil }

        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {
            connectCount += 1
            statusValue = .online
        }
        func disconnect() async { statusValue = .offline }
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
        func reauthenticate() async throws {}
    }

    private struct UnreachableConversation: ConversationProviding {
        var events: AsyncStream<ConversationEvent> { AsyncStream { $0.finish() } }
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            throw GatewayConnectivityError.unreachable
        }
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
        func resumeSession(sessionID: String, lastEventID: Int?, profile: String? = nil) async throws -> ConversationSession {
            throw GatewayConnectivityError.unreachable
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
            PromptSubmission(status: "ok")
        }
        func interrupt(sessionID: String) async throws -> InterruptResult {
            InterruptResult(status: "ok")
        }
    }

    private struct UnreachableReplay: ReplayProviding {
        let gatewayID = GatewayID(rawValue: "workstation")
        func watermarks() async -> [SessionEventWatermark] { [] }
        func replayAfterReconnect() async throws -> [ReplayOutcome] { [] }
    }

    private struct UnreachableHistory: SessionHistoryProviding {
        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
            SessionHistory(sessionID: sessionID, count: 0, messages: [])
        }
        func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
            SessionStatus(rawOutput: "", sessionID: sessionID)
        }
    }

    private func makeEnvironment(
        ids: [String],
        errors: [String: GatewayConnectivityError] = [:],
        defaults: UserDefaults? = nil,
        sessionList: any SessionListProviding = EmptySessions(),
        conversationFactory: FleetConversationFactory? = nil
    ) async -> (AppEnvironment, [GatewayID: ScriptedConnection]) {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in ScriptedConnection(gatewayID: gateway.id) })
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in EmptyRosterSession(gatewayID: gateway.id) })
        let connections = Dictionary(uniqueKeysWithValues: ids.map { raw in
            let id = GatewayID(rawValue: raw)
            return (id, ScriptedConnection(gatewayID: id, connectError: errors[raw]))
        })
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: sessionList,
            connectionFactory: { gateway, _ in
                connections[gateway.id] ?? ScriptedConnection(gatewayID: gateway.id)
            },
            conversationFactory: conversationFactory,
            health: TestHealth(),
            seedRegistrations: ids.map(registration),
            connectionIntentDefaults: defaults)
        await environment.load()
        environment.setForegroundRecoveryAllowed(true)
        return (environment, connections)
    }

    private func suiteDefaults() -> UserDefaults {
        UserDefaults(suiteName: "connection-intent-\(UUID().uuidString)")!
    }

    private func makeRecoveryEnvironment(
        id: GatewayID,
        connection: any GatewayConnectivityProviding,
        timing: ConnectionRecoveryTiming,
        sessionList: any SessionListProviding = EmptySessions(),
        profiles: [ProfileDescriptor] = [],
        recordStore: (any GatewayRecordStoring)? = nil
    ) async -> AppEnvironment {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { _, _ in connection },
            recordStore: recordStore)
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in EmptyRosterSession(gatewayID: gateway.id, descriptors: profiles) })
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: sessionList,
            connectionFactory: { _, _ in connection },
            health: TestHealth(),
            seedRegistrations: [registration(id.rawValue)],
            connectionIntentDefaults: suiteDefaults(),
            recoveryTiming: timing)
        await environment.load()
        environment.setForegroundRecoveryAllowed(true)
        return environment
    }

    /// Poll until the condition holds or the deadline passes (recovery runs on
    /// watch/backoff timers — never assert on a bare sleep).
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: Dogfood r2 — bounded auto-recovery for failed connections

    func testTransientConnectFailureAutoRetriesUntilSuccess() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [
            .failure(.unreachable, .abnormalClosure),
            .success,
        ])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2))

        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .failed(.offline), "first attempt failed")

        let healed = await waitUntil { environment.connectionStates[id] == .connected }
        XCTAssertTrue(healed, "a transient failure heals via bounded auto-retry")
        XCTAssertEqual(connection.connectCount, 2)
    }

    func testPostOpenDropIsMirroredAndAutoRetried() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [.success, .success])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.3, maxDelay: 0.3, maxAttempts: 2))

        await environment.connect(to: id)
        XCTAssertEqual(environment.connectionStates[id], .connected)

        // Simulate a post-open drop: the transport reports failed while the
        // runtime's observable state still says connected.
        connection.statusValue = .offline
        connection.reasonValue = .abnormalClosure

        let mirrored = await waitUntil { environment.connectionStates[id] == .failed(.offline) }
        XCTAssertTrue(mirrored, "a drop is mirrored, never left stale-'connected'")
        let healed = await waitUntil { environment.connectionStates[id] == .connected }
        XCTAssertTrue(healed, "a post-open drop heals via bounded auto-retry")
        XCTAssertEqual(connection.connectCount, 2)
    }

    func testDisconnectAllStopsRecoveryWatchUntilForegroundRestore() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [.success, .success])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.025, maxDelay: 0.025, maxAttempts: 2))

        await environment.connect(to: id)
        connection.statusValue = .offline
        connection.reasonValue = .abnormalClosure
        let observedDrop = await waitUntil {
            environment.connectionStates[id] == .failed(.offline)
        }
        XCTAssertTrue(observedDrop, "the recovery watch observes the transient drop")

        await environment.disconnectAll()
        XCTAssertEqual(environment.connectionStates[id], .disconnected)
        XCTAssertTrue(environment.isConnectionIntended(id), "background teardown preserves intent")

        let retriedWhileSuspended = await waitUntil(timeout: 0.2) {
            connection.connectCount > 1
        }
        XCTAssertFalse(retriedWhileSuspended, "disconnectAll stops recovery until foreground restore")
        XCTAssertEqual(connection.connectCount, 1)

        await environment.restoreIntendedConnections()
        let restored = await waitUntil {
            environment.connectionStates[id] == .connected
        }
        XCTAssertTrue(restored, "foreground restore reconnects the intended gateway")
        XCTAssertEqual(connection.connectCount, 2)
    }

    func testBackgroundInvalidatesLateConnectAndForegroundOwnsRecovery() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = InterruptedConnection(gatewayID: id)
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.02, maxAttempts: 2))

        let connecting = Task { await environment.connect(to: id) }
        let started = await waitUntil { connection.firstConnectStarted }
        XCTAssertTrue(started)
        XCTAssertEqual(environment.connectionStates[id], .connecting)

        await environment.suspendForBackground()
        XCTAssertTrue(environment.isConnectionIntended(id))
        connection.releaseFirstConnect()
        await connecting.value
        XCTAssertEqual(environment.connectionStates[id], .disconnected,
                       "a late handshake cannot reclaim ownership after background teardown")
        XCTAssertEqual(connection.disconnectCount, 2,
                       "background teardown and stale handshake both leave transport closed")

        environment.setForegroundRecoveryAllowed(true)
        await environment.resumeAfterForeground()
        XCTAssertEqual(connection.connectCount, 2)
        XCTAssertEqual(environment.connectionStates[id], .connected,
                       "unlocked foreground restore owns the next connection attempt")
    }

    func testGatewayRemovalInvalidatesAnInFlightConnect() async throws {
        let id = GatewayID(rawValue: "workstation")
        let connection = InterruptedConnection(gatewayID: id)
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.02, maxAttempts: 2))
        let connecting = Task { await environment.connect(to: id) }
        let started = await waitUntil { connection.firstConnectStarted }
        XCTAssertTrue(started)

        try await environment.removeGateway(id)
        connection.releaseFirstConnect()
        await connecting.value

        XCTAssertFalse(environment.isConnectionIntended(id))
        XCTAssertNil(environment.connectionStates[id])
        XCTAssertFalse(environment.gateways.contains { $0.id == id })
        XCTAssertEqual(connection.disconnectCount, 2,
                       "gateway removal and late handshake both leave the transport closed")
    }

    func testFailedGatewayRemovalPreservesRecoveryIntent() async throws {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [.success])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.02, maxAttempts: 2),
            recordStore: FailingGatewayDeleteRecordStore())
        await environment.connect(to: id)

        do {
            try await environment.removeGateway(id)
            XCTFail("synthetic durable delete failure should preserve the gateway")
        } catch {
            XCTAssertTrue(error is GatewayRegistryError)
        }

        XCTAssertTrue(environment.gateways.contains { $0.id == id })
        XCTAssertTrue(environment.isConnectionIntended(id),
                      "failed removal does not clear user intent")
        XCTAssertEqual(environment.connectionStates[id], .connected,
                       "failed removal does not tear down the live transport")
    }

    func testForegroundWaitsForBackgroundTeardownAndNewerBackgroundWins() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = DelayedDisconnectConnection(gatewayID: id)
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.02, maxAttempts: 2))
        await environment.connect(to: id)

        let firstBackground = Task { await environment.suspendForBackground() }
        let teardownStarted = await waitUntil { connection.firstDisconnectStarted }
        XCTAssertTrue(teardownStarted)
        let staleForeground = Task { await environment.resumeAfterForeground() }
        _ = await waitUntil(timeout: 0.1) { false }
        XCTAssertEqual(connection.connectCount, 1,
                       "foreground cannot reconnect before background teardown finishes")

        environment.beginBackgroundSuspension()
        connection.releaseFirstDisconnect()
        await firstBackground.value
        await staleForeground.value
        XCTAssertEqual(connection.connectCount, 1,
                       "an interrupted foreground reconciliation cannot start a stale connect")

        environment.setForegroundRecoveryAllowed(true)
        await environment.resumeAfterForeground()
        XCTAssertEqual(connection.connectCount, 2)
        XCTAssertEqual(environment.connectionStates[id], .connected)
        XCTAssertEqual(connection.disconnectCount, 2,
                       "the newer background teardown follows the earlier one in order")
    }

    func testForegroundCanRefreshRouteWhilePreLockSessionReadIsStillPending() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [.success, .success])
        let sessionList = DelayedFirstSessionList()
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.02, maxAttempts: 2),
            sessionList: sessionList,
            profiles: [ProfileDescriptor(name: "default", path: "/profiles/default", isDefault: true)])
        let route = Route(gatewayID: id, profileSlug: ProfileSlug(rawValue: "default"))

        let oldRead = Task { await environment.loadSessions(for: route) }
        let started = await waitUntil { sessionList.firstReadStarted }
        XCTAssertTrue(started)
        await environment.suspendForBackground()
        environment.setForegroundRecoveryAllowed(true)
        await environment.resumeAfterForeground()
        XCTAssertEqual(environment.sessionsByRoute[route]?.map(\.id), ["fresh"])

        sessionList.releaseFirstRead()
        await oldRead.value
        XCTAssertEqual(environment.sessionsByRoute[route]?.map(\.id), ["fresh"],
                       "a late pre-lock response cannot overwrite the fresh session list")
    }

    func testBackgroundFlushesPendingDraftAndRepeatedLifecycleKeepsIntent() async {
        let id = GatewayID(rawValue: "workstation")
        let (environment, _) = await makeEnvironment(ids: [id.rawValue])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-draft-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let drafts = ConversationDraftStore(url: url, debounce: 60)
        environment.attachConversationDrafts(drafts)
        let route = Route(gatewayID: id, profileSlug: ProfileSlug(rawValue: "default"))

        await environment.connect(to: id)
        drafts.scheduleSave("keep this thought", route: route, sessionID: "session-1")
        await environment.suspendForBackground()
        await environment.suspendForBackground()
        XCTAssertTrue(environment.isConnectionIntended(id))
        XCTAssertEqual(
            ConversationDraftStore(url: url).draft(route: route, sessionID: "session-1"),
            "keep this thought")

        environment.setForegroundRecoveryAllowed(true)
        await environment.resumeAfterForeground()
        XCTAssertEqual(environment.connectionStates[id], .connected)
    }

    func testForegroundResumeHonorsManualDisconnectForConversationAndSessionReads() async {
        let intendedID = GatewayID(rawValue: "intended")
        let optedOutID = GatewayID(rawValue: "optedout")
        let intendedConversation = ScriptedConversationSession(gatewayID: intendedID)
        let optedOutConversation = ScriptedConversationSession(gatewayID: optedOutID)
        let conversations = [intendedID: intendedConversation, optedOutID: optedOutConversation]
        let sessionList = RecordingSessions()
        let (environment, _) = await makeEnvironment(
            ids: [intendedID.rawValue, optedOutID.rawValue],
            sessionList: sessionList,
            conversationFactory: { gateway, _ in conversations[gateway.id]! })

        _ = environment.conversationSession(for: intendedID)
        _ = environment.conversationSession(for: optedOutID)
        await environment.connect(to: intendedID)
        await environment.connect(to: optedOutID)
        await environment.disconnect(from: optedOutID)
        XCTAssertTrue(environment.isConnectionIntended(intendedID))
        XCTAssertFalse(environment.isConnectionIntended(optedOutID))

        let intendedRoute = Route(gatewayID: intendedID, profileSlug: ProfileSlug(rawValue: "default"))
        let optedOutRoute = Route(gatewayID: optedOutID, profileSlug: ProfileSlug(rawValue: "default"))
        await environment.loadSessions(for: intendedRoute)
        await environment.loadSessions(for: optedOutRoute)
        XCTAssertEqual(sessionList.fetchedRoutes.count, 2)

        await environment.suspendForBackground()
        environment.setForegroundRecoveryAllowed(true)
        await environment.resumeAfterForeground()

        XCTAssertEqual(intendedConversation.connectCount, 1,
                       "foreground restores conversation transport for the intended gateway")
        XCTAssertEqual(optedOutConversation.connectCount, 0,
                       "manual disconnect remains authoritative across backgrounding")
        XCTAssertEqual(sessionList.fetchedRoutes.filter { $0 == intendedRoute }.count, 2,
                       "the intended gateway session list is refreshed after resume")
        XCTAssertEqual(sessionList.fetchedRoutes.filter { $0 == optedOutRoute }.count, 1,
                       "automatic forced refresh skips a manually disconnected gateway")
        XCTAssertFalse(environment.isConnectionIntended(optedOutID))
    }

    func testConversationModelForegroundRecoveryGateHonorsManualDisconnect() async {
        let id = GatewayID(rawValue: "optedout")
        let conversation = ScriptedConversationSession(gatewayID: id)
        let (environment, _) = await makeEnvironment(
            ids: [id.rawValue],
            conversationFactory: { _, _ in conversation })
        let route = Route(gatewayID: id, profileSlug: ProfileSlug(rawValue: "default"))
        let model = environment.makeConversationViewModel(route: route, sessionID: "session")!
        await environment.connect(to: id)
        await environment.disconnect(from: id)

        model.forceDisconnectedForTesting()
        await model.appBecameActive()

        XCTAssertFalse(environment.isConnectionIntended(id))
        XCTAssertEqual(conversation.connectCount, 0,
                       "view-level foreground healing also respects explicit manual opt-out")
    }

    func testConversationModelForegroundRecoveryWaitsForUnlock() async {
        let id = GatewayID(rawValue: "workstation")
        let conversation = ScriptedConversationSession(gatewayID: id)
        let (environment, _) = await makeEnvironment(
            ids: [id.rawValue],
            conversationFactory: { _, _ in conversation })
        let route = Route(gatewayID: id, profileSlug: ProfileSlug(rawValue: "default"))
        let model = environment.makeConversationViewModel(route: route, sessionID: "session")!
        await environment.connect(to: id)
        await environment.suspendForBackground()

        model.forceDisconnectedForTesting()
        await model.appBecameActive()
        XCTAssertEqual(conversation.connectCount, 0,
                       "a view callback cannot resume protected transports while App Lock is active")

        environment.setForegroundRecoveryAllowed(true)
        await environment.resumeAfterForeground()
        XCTAssertEqual(conversation.connectCount, 1,
                       "the authenticated app root resumes the intended conversation session")
    }

    func testAuthRequiredFailureDoesNotAutoRetry() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [
            .failure(.authenticationRequired, .reauthenticationRequired),
            .success,
        ])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2))

        await environment.connect(to: id)
        _ = await waitUntil(timeout: 0.5) { false }
        XCTAssertEqual(connection.connectCount, 1, "authRequired is surfaced, never silently retried (M11)")
        XCTAssertEqual(environment.connectionStates[id], .failed(.authenticationRequired))
    }

    func testTLSApprovalFailureNeverAutoRetries() async {
        // T3: a pin mismatch must NEVER be auto-retried (possible MITM) —
        // even though its classified status is plain `offline`.
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [
            .failure(.unreachable, .tlsPinMismatch),
            .success,
        ])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2))

        await environment.connect(to: id)
        _ = await waitUntil(timeout: 0.5) { false }
        XCTAssertEqual(connection.connectCount, 1, "pin mismatch is never auto-retried")
    }

    func testReconnectAttemptsAreBounded() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: Array(
            repeating: .failure(.unreachable, .abnormalClosure), count: 8))
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2))

        await environment.connect(to: id)
        let exhausted = await waitUntil { connection.connectCount == 3 }
        XCTAssertTrue(exhausted, "initial attempt + 2 retries")
        _ = await waitUntil(timeout: 0.4) { false }
        XCTAssertEqual(connection.connectCount, 3, "the retry budget bounds the loop")
    }

    func testManualDisconnectCancelsPendingRetry() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [
            .failure(.unreachable, .abnormalClosure),
            .success,
        ])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.4, maxDelay: 0.4, maxAttempts: 2))

        await environment.connect(to: id)
        // Let the watch observe the failure and schedule its retry…
        _ = await waitUntil(timeout: 0.12) { false }
        await environment.disconnect(from: id)
        // …then prove the pending retry was cancelled before it fired.
        _ = await waitUntil(timeout: 0.9) { false }
        XCTAssertEqual(connection.connectCount, 1, "manual disconnect cancels the pending retry")
        XCTAssertFalse(environment.isConnectionIntended(id))
    }

    /// Foreground auto-heal for conversation sessions: an unreachable
    /// session's transport reconnects on restore; a reachable one is left
    /// alone; `.authenticationRequired` is surfaced, never silently healed
    /// (M11).
    func testRestoreConversationSessionsHealsDroppedSkipsReachableAndAuth() async {
        let id = GatewayID(rawValue: "workstation")
        let conversation = ScriptedConversationSession(gatewayID: id)

        // Reachable: no reconnect.
        conversation.statusValue = .online
        await AppEnvironment.restoreConversationSessionsTestHarness([conversation])
        XCTAssertEqual(conversation.connectCount, 0, "reachable sessions skip restore")

        // Dropped: reconnect once.
        conversation.statusValue = .offline
        await AppEnvironment.restoreConversationSessionsTestHarness([conversation])
        XCTAssertEqual(conversation.connectCount, 1, "dropped sessions heal")

        // Auth required: NEVER silently re-authenticated (M11).
        conversation.statusValue = .authenticationRequired
        await AppEnvironment.restoreConversationSessionsTestHarness([conversation])
        XCTAssertEqual(conversation.connectCount, 1, "authRequired is surfaced, not healed")
    }

    func testTransportTeardownPreservesIntentAndRestores() async {
        let (environment, connections) = await makeEnvironment(ids: ["workstation"])
        let id = GatewayID(rawValue: "workstation")

        await environment.connect(to: id)
        await environment.disconnectAll()

        XCTAssertEqual(environment.connectionStates[id], .disconnected)
        XCTAssertTrue(environment.isConnectionIntended(id))
        await environment.restoreIntendedConnections()
        XCTAssertEqual(environment.connectionStates[id], .connected)
        XCTAssertEqual(connections[id]?.connectCount, 2)
    }

    func testManualDisconnectClearsIntentAndDoesNotResurrect() async {
        let (environment, connections) = await makeEnvironment(ids: ["workstation"])
        let id = GatewayID(rawValue: "workstation")

        await environment.connect(to: id)
        await environment.disconnect(from: id)
        await environment.restoreIntendedConnections()

        XCTAssertFalse(environment.isConnectionIntended(id))
        XCTAssertEqual(environment.connectionStates[id], .disconnected)
        XCTAssertEqual(connections[id]?.connectCount, 1)
    }

    func testColdRuntimeRestoresOnlyPersistedIntent() async {
        let defaults = suiteDefaults()
        let id = GatewayID(rawValue: "workstation")
        let first = await makeEnvironment(ids: ["workstation", "laptop"], defaults: defaults)
        await first.0.connect(to: id)

        let second = await makeEnvironment(ids: ["workstation", "laptop"], defaults: defaults)
        await second.0.restoreIntendedConnections()

        XCTAssertEqual(second.0.connectionStates[id], .connected)
        XCTAssertEqual(second.1[id]?.connectCount, 1)
        XCTAssertEqual(second.1[GatewayID(rawValue: "laptop")]?.connectCount, 0)
    }

    func testAuthFailureClearsOnlyThatGatewayIntent() async {
        let (environment, connections) = await makeEnvironment(
            ids: ["workstation", "laptop"],
            errors: ["workstation": .authenticationRequired])
        let workstation = GatewayID(rawValue: "workstation")
        let laptop = GatewayID(rawValue: "laptop")

        await environment.connect(to: workstation)
        await environment.connect(to: laptop)
        await environment.restoreIntendedConnections()

        XCTAssertFalse(environment.isConnectionIntended(workstation))
        XCTAssertTrue(environment.isConnectionIntended(laptop))
        XCTAssertEqual(connections[workstation]?.connectCount, 1)
        XCTAssertEqual(connections[laptop]?.connectCount, 1)
    }

    func testZeroGatewayRestoreDoesNoConnectionWork() async {
        let (environment, _) = await makeEnvironment(ids: [])
        await environment.restoreIntendedConnections()
        XCTAssertEqual(environment.gateways.count, 0)
        XCTAssertEqual(environment.hydrationPhase, .unconfigured)
    }

    func testIntentStorePersistsGatewayIDsOnly() {
        let defaults = suiteDefaults()
        let store = ConnectionIntentStore(defaults: defaults)
        store.record(GatewayID(rawValue: "workstation"))

        XCTAssertEqual(
            defaults.stringArray(forKey: ConnectionIntentStore.defaultsKey),
            ["workstation"])
        XCTAssertTrue(ConnectionIntentStore(defaults: defaults)
            .isIntended(GatewayID(rawValue: "workstation")))
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains {
            String(describing: $0).contains("password")
        })
    }

    func testAppRootWiresBackgroundSuspensionAndForegroundResume() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("HermesFleetApp/HermesFleetApp.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("environment.disconnectAll()"))
        XCTAssertTrue(source.contains("beginBackgroundSuspension()"))
        XCTAssertTrue(source.contains("resumeAfterForeground()"))
        XCTAssertTrue(source.contains("phase == .background"))
        XCTAssertTrue(source.contains("phase == .active"))
    }

    func testProductionGraphPersistsConnectionIntentAcrossRelaunch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("HermesFleetApp/FleetServiceGraph.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            source.contains("connectionIntentDefaults: UserDefaults.standard"),
            "production composition must provide the durable non-secret intent store")
    }
}
