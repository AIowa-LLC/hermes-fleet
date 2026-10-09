import XCTest
import os
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
        nonisolated(unsafe) private(set) var disconnectCount = 0
        /// Makes connect() suspend, so watch ticks run while it is in flight.
        nonisolated(unsafe) var connectDelay: TimeInterval = 0
        nonisolated(unsafe) var disconnectDelay: TimeInterval = 0
        /// Highest number of connect() calls observed at the same time.
        nonisolated(unsafe) private(set) var maxConcurrentConnects = 0
        nonisolated(unsafe) private var inFlight = 0

        init(gatewayID: GatewayID, scripted: [RecoveryOutcome]) {
            self.gatewayID = gatewayID
            self.scripted = scripted
        }

        var status: GatewayStatus { statusValue }
        func lastDisconnectReason() async -> DisconnectReason? { reasonValue }

        func connect() async throws {
            connectCount += 1
            inFlight += 1
            maxConcurrentConnects = max(maxConcurrentConnects, inFlight)
            defer { inFlight -= 1 }
            if connectDelay > 0 { try? await Task.sleep(for: .seconds(connectDelay)) }
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
        func disconnect() async {
            disconnectCount += 1
            if disconnectDelay > 0 { try? await Task.sleep(for: .seconds(disconnectDelay)) }
            statusValue = .offline
        }
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
    }

    private struct EmptyRosterSession: GatewayRosterSession {
        let gatewayID: GatewayID
        var status: GatewayStatus { .online }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] { [] }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private struct EmptySessions: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
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
        var statusValue: GatewayStatus = .online
        var connectCount = 0
        let conversation: any ConversationProviding = UnreachableConversation()
        let replay: any ReplayProviding = UnreachableReplay()
        let history: any SessionHistoryProviding = UnreachableHistory()

        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }

        var status: GatewayStatus { statusValue }
        var liveness: ConnectionLivenessSnapshot? { nil }

        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws { connectCount += 1 }
        func disconnect() async {}
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
        defaults: UserDefaults? = nil
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
            sessionList: EmptySessions(),
            connectionFactory: { gateway, _ in
                connections[gateway.id] ?? ScriptedConnection(gatewayID: gateway.id)
            },
            health: TestHealth(),
            seedRegistrations: ids.map(registration),
            connectionIntentDefaults: defaults)
        await environment.load()
        return (environment, connections)
    }

    private func suiteDefaults() -> UserDefaults {
        UserDefaults(suiteName: "connection-intent-\(UUID().uuidString)")!
    }

    private func makeRecoveryEnvironment(
        id: GatewayID,
        connection: RecoveringConnection,
        timing: ConnectionRecoveryTiming
    ) async -> AppEnvironment {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { _, _ in connection })
        let roster = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in EmptyRosterSession(gatewayID: gateway.id) })
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: EmptySessions(),
            connectionFactory: { _, _ in connection },
            health: TestHealth(),
            seedRegistrations: [registration(id.rawValue)],
            connectionIntentDefaults: suiteDefaults(),
            recoveryTiming: timing)
        await environment.load()
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

    // MARK: Finding 5 — backoff survives short-lived connections

    /// A peer that accepts the connection and drops it again (for example
    /// after rejecting an oversized frame) must not regain the base reconnect
    /// delay by staying "online" for a watch tick.
    func testRepeatedShortLivedConnectionsStayBoundedByTheRetryBudget() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 3, healthyDuration: 30))
        await environment.connect(to: id)
        for _ in 0..<8 {
            let before = connection.connectCount
            // Connected for a few watch ticks, then dropped (oversized-frame style).
            _ = await waitUntil(timeout: 0.15) { false }
            connection.statusValue = .offline
            connection.reasonValue = .abnormalClosure
            _ = await waitUntil(timeout: 0.4) { connection.connectCount > before }
        }
        let settled = connection.connectCount
        _ = await waitUntil(timeout: 0.4) { false }
        XCTAssertEqual(connection.connectCount, settled, "the loop has stopped: no further reconnects")
        // Eight drops were offered. Unbounded behavior (budget restored by a
        // single online sample) would reconnect for every one of them (1 + 8).
        XCTAssertLessThanOrEqual(settled, 1 + 3, "never more than the initial connect plus maxAttempts retries")
        XCTAssertGreaterThanOrEqual(settled, 2, "recovery did start")
    }

    func testSustainedHealthRestoresTheBudgetSoARecoveredGatewayIsNotPenalized() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2, healthyDuration: 0.15))
        await environment.connect(to: id)
        for _ in 0..<6 {
            let before = connection.connectCount
            _ = await waitUntil(timeout: 0.4) { false }          // healthy: online well past healthyDuration
            connection.statusValue = .offline
            connection.reasonValue = .abnormalClosure
            let retried = await waitUntil(timeout: 1) { connection.connectCount > before }
            XCTAssertTrue(retried, "a gateway that stayed healthy keeps recovering")
        }
        XCTAssertGreaterThan(connection.connectCount, 1 + 2, "more reconnects than a single budget allows")
    }

    func testForegroundRestoreAndManualReconnectRestoreAnExhaustedBudget() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: Array(
            repeating: .failure(.unreachable, .abnormalClosure), count: 3))
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2, healthyDuration: 30))
        await environment.connect(to: id)
        _ = await waitUntil { connection.connectCount == 3 }
        _ = await waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(connection.connectCount, 3, "budget spent")
        connection.scripted = [] // next connect succeeds
        await environment.restoreIntendedConnections()
        XCTAssertEqual(connection.connectCount, 4, "a foreground restore is an explicit fresh start")
        XCTAssertEqual(environment.connectionStates[id], .connected)
        // And the budget really is fresh: two more drops still retry.
        for expected in [5, 6] {
            // Settle first: toggling status while a connect() is mid-flight races the double.
            _ = await waitUntil { environment.connectionStates[id] == .connected }
            connection.statusValue = .offline
            connection.reasonValue = .abnormalClosure
            let retried = await waitUntil(timeout: 1) { connection.connectCount == expected }
            XCTAssertTrue(retried, "expected \(expected) got \(connection.connectCount) state \(String(describing: environment.connectionStates[id])) status \(connection.statusValue) attempts \(environment.reconnectAttemptsForTesting(id)) pending \(environment.hasPendingRetryForTesting(id))")
        }
    }

    func testDisconnectCancelsPendingBackoffAndLeavesNoStaleBudget() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: Array(
            repeating: .failure(.unreachable, .abnormalClosure), count: 2))
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.3, maxDelay: 0.3, maxAttempts: 2, healthyDuration: 30))
        await environment.connect(to: id)
        _ = await waitUntil(timeout: 0.1) { false }
        await environment.disconnect(from: id)                 // cancels the pending retry
        _ = await waitUntil(timeout: 0.5) { false }
        XCTAssertEqual(connection.connectCount, 1)
        connection.scripted = []
        await environment.reconnect(to: id)                    // explicit user reconnect
        XCTAssertEqual(environment.connectionStates[id], .connected)
        for expected in [3, 4] {
            _ = await waitUntil(timeout: 2) { environment.connectionStates[id] == .connected }
            connection.statusValue = .offline
            connection.reasonValue = .abnormalClosure
            let retried = await waitUntil(timeout: 1.5) { connection.connectCount == expected }
            XCTAssertTrue(retried, "the budget was reset by the deliberate reconnect")
        }
    }

    func testManualReconnectSerializesRepeatedCallsPerGateway() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [.success, .success])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2, healthyDuration: 30))
        await environment.connect(to: id)
        connection.connectDelay = 0.12

        let retry = Task { await environment.reconnect(to: id) }
        let enteredHandshake = await waitUntil { connection.connectCount == 2 }
        XCTAssertTrue(enteredHandshake)
        XCTAssertTrue(environment.reconnectingGatewayIDs.contains(id))

        // A second tap during the teardown/handshake window is ignored.
        await environment.reconnect(to: id)
        XCTAssertEqual(connection.connectCount, 2)
        XCTAssertEqual(connection.maxConcurrentConnects, 1)

        await retry.value
        XCTAssertFalse(environment.reconnectingGatewayIDs.contains(id))
        XCTAssertEqual(environment.connectionStates[id], .connected)
    }

    func testExplicitDisconnectCancelsReconnectDuringTeardown() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [.success, .success])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2, healthyDuration: 30))
        await environment.connect(to: id)
        connection.disconnectDelay = 0.12

        let retry = Task { await environment.reconnect(to: id) }
        let retryStarted = await waitUntil { environment.reconnectingGatewayIDs.contains(id) }
        XCTAssertTrue(retryStarted)

        await environment.disconnect(from: id)
        await retry.value

        XCTAssertEqual(connection.connectCount, 1, "explicit Disconnect must prevent a late retry")
        XCTAssertEqual(environment.connectionStates[id], .disconnected)
        XCTAssertFalse(environment.isConnectionIntended(id))
        XCTAssertFalse(environment.reconnectingGatewayIDs.contains(id))
    }

    func testManualReconnectDuringLifecycleTeardownWaitsForForegroundRestore() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [.success, .success])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2, healthyDuration: 30))
        await environment.connect(to: id)
        connection.disconnectDelay = 0.12

        let teardown = Task { await environment.disconnectAll() }
        let teardownStarted = await waitUntil { connection.disconnectCount == 1 }
        XCTAssertTrue(teardownStarted)

        await environment.reconnect(to: id)
        XCTAssertEqual(connection.connectCount, 1, "manual retry must not open a session during teardown")
        XCTAssertTrue(environment.reconnectingGatewayIDs.contains(id), "the queued row action should remain visibly pending")

        await teardown.value
        XCTAssertEqual(environment.connectionStates[id], .disconnected)
        XCTAssertEqual(connection.connectCount, 1, "background/lock teardown alone must not drain a queued retry")

        await environment.restoreIntendedConnections()
        XCTAssertEqual(connection.connectCount, 2, "foreground/unlock restore should run the queued manual retry")
        XCTAssertEqual(environment.connectionStates[id], .connected)
        XCTAssertFalse(environment.reconnectingGatewayIDs.contains(id))
    }

    func testExplicitDisconnectCancelsDeferredReconnectDuringTeardown() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [.success, .success])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2, healthyDuration: 30))
        await environment.connect(to: id)
        connection.disconnectDelay = 0.12

        let teardown = Task { await environment.disconnectAll() }
        let teardownStarted = await waitUntil { connection.disconnectCount == 1 }
        XCTAssertTrue(teardownStarted)
        await environment.reconnect(to: id)
        XCTAssertTrue(environment.reconnectingGatewayIDs.contains(id))

        await environment.disconnect(from: id)
        await teardown.value
        await environment.restoreIntendedConnections()

        XCTAssertEqual(connection.connectCount, 1, "Disconnect must cancel the deferred retry")
        XCTAssertEqual(environment.connectionStates[id], .disconnected)
        XCTAssertFalse(environment.isConnectionIntended(id))
        XCTAssertFalse(environment.reconnectingGatewayIDs.contains(id))
    }

    func testRemovalCancelsDeferredReconnectBeforeForegroundRestore() async throws {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [.success, .success])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2, healthyDuration: 30))
        await environment.connect(to: id)
        connection.disconnectDelay = 0.12

        let teardown = Task { await environment.disconnectAll() }
        let teardownStarted = await waitUntil { connection.disconnectCount == 1 }
        XCTAssertTrue(teardownStarted)
        await environment.reconnect(to: id)
        await teardown.value

        _ = try await environment.removeGateway(id)
        await environment.restoreIntendedConnections()

        XCTAssertEqual(connection.connectCount, 1, "a removed gateway must not receive a deferred retry")
        XCTAssertNil(environment.gateway(for: id))
        XCTAssertFalse(environment.isConnectionIntended(id))
        XCTAssertFalse(environment.reconnectingGatewayIDs.contains(id))
    }

    func testRemovalDuringReconnectTeardownPreventsALateSession() async throws {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [.success, .success])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2, healthyDuration: 30))
        await environment.connect(to: id)
        connection.disconnectDelay = 0.12

        let retry = Task { await environment.reconnect(to: id) }
        let retryStarted = await waitUntil { environment.reconnectingGatewayIDs.contains(id) }
        XCTAssertTrue(retryStarted)

        _ = try await environment.removeGateway(id)
        await retry.value

        XCTAssertEqual(connection.connectCount, 1, "removed gateways must not receive a late reconnect")
        XCTAssertNil(environment.gateway(for: id))
        XCTAssertNil(environment.connectionStates[id])
        XCTAssertFalse(environment.isConnectionIntended(id))
    }

    func testForegroundRestoreWaitsForBackgroundTeardownToFinish() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: [.success, .success])
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2, healthyDuration: 30))
        await environment.connect(to: id)
        connection.disconnectDelay = 0.12

        let teardown = Task { await environment.disconnectAll() }
        let teardownStarted = await waitUntil { connection.disconnectCount == 1 }
        XCTAssertTrue(teardownStarted)
        XCTAssertEqual(environment.connectionStates[id], .connected,
                       "the fixture keeps the stale observable state during transport shutdown")

        // This models `.active` arriving while the background scene teardown
        // is suspended in the transport's async disconnect.
        await environment.restoreIntendedConnections()
        await teardown.value

        XCTAssertEqual(connection.connectCount, 2,
                       "the queued foreground restore should reconnect after teardown")
        XCTAssertEqual(environment.connectionStates[id], .connected)
        XCTAssertTrue(environment.isConnectionIntended(id))
    }

    /// The UI's Connect button calls `connect(to:)` directly: after the budget
    /// is spent it must restore the budget, otherwise the next drop is never retried.
    func testManualConnectAfterExhaustionRestoresTheBudget() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: Array(
            repeating: .failure(.unreachable, .abnormalClosure), count: 3))
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2, healthyDuration: 30))
        await environment.connect(to: id)
        _ = await waitUntil { connection.connectCount == 3 }
        _ = await waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(connection.connectCount, 3, "budget spent")
        connection.scripted = []
        await environment.connect(to: id)                       // the user taps Connect
        XCTAssertEqual(environment.connectionStates[id], .connected)
        connection.statusValue = .offline
        connection.reasonValue = .abnormalClosure
        let retried = await waitUntil(timeout: 1) { connection.connectCount == 5 }
        XCTAssertTrue(retried, "a manual Connect restored the budget, so the next drop retries")
    }

    /// While a retry's connect() is in flight, watch ticks still see the old
    /// failed status. They must not schedule another retry and burn budget.
    func testWatchTicksDuringAnInFlightConnectDoNotBurnTheBudget() async {
        let id = GatewayID(rawValue: "workstation")
        let connection = RecoveringConnection(gatewayID: id, scripted: Array(
            repeating: .failure(.unreachable, .abnormalClosure), count: 3))
        connection.connectDelay = 0.12
        let environment = await makeRecoveryEnvironment(
            id: id, connection: connection,
            timing: ConnectionRecoveryTiming(
                watchInterval: 0.01, baseDelay: 0.02, maxDelay: 0.05, maxAttempts: 2, healthyDuration: 30))
        await environment.connect(to: id)
        let exhausted = await waitUntil(timeout: 3) { connection.connectCount == 3 }
        XCTAssertTrue(exhausted, "initial attempt + BOTH retries ran: no attempt was burned by a duplicate schedule")
        _ = await waitUntil(timeout: 0.5) { false }
        XCTAssertEqual(connection.connectCount, 3)
        XCTAssertEqual(connection.maxConcurrentConnects, 1,
                       "a watch tick during an in-flight connect must not start a second concurrent connect")
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

    // MARK: Cold-launch persistence races (Fleet Dev build 4 report)

    private final class FlakyRecordStore: GatewayRecordStoring, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: (records: [String: StoredGatewayRecord](), failing: false))
        var failing: Bool {
            get { lock.withLock { $0.failing } }
            set { lock.withLock { $0.failing = newValue } }
        }
        func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {
            lock.withLock { $0.records[record.id] = record }
        }
        func deleteGatewayRecord(id: GatewayID) async throws {
            lock.withLock { _ = $0.records.removeValue(forKey: id.rawValue) }
        }
        func loadGatewayRecords() async throws -> [StoredGatewayRecord] {
            try lock.withLock { state in
                if state.failing { throw CacheStoreError.storeUnavailable("scripted") }
                return state.records.values.sorted { $0.id < $1.id }
            }
        }
    }

    /// Relaunch fixture: a fresh registry + runtime over SHARED durable
    /// state (record store + connect-intent defaults), NOT yet loaded.
    private func makeRelaunchEnvironment(
        records: FlakyRecordStore,
        credentials: InMemoryCredentialStore,
        defaults: UserDefaults
    ) -> (AppEnvironment, ScriptedConnection) {
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in ScriptedConnection(gatewayID: gateway.id) },
            recordStore: records)
        let connection = ScriptedConnection(gatewayID: GatewayID(rawValue: "workstation"))
        let environment = AppEnvironment(
            registry: registry,
            roster: FleetRosterService(
                registry: registry,
                credentials: credentials,
                sessionFactory: { gateway, _ in EmptyRosterSession(gatewayID: gateway.id) }),
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: EmptySessions(),
            connectionFactory: { _, _ in connection },
            health: TestHealth(),
            connectionIntentDefaults: defaults)
        return (environment, connection)
    }

    /// Session 1: the user adds + connects a gateway; returns the shared state.
    private func connectedFirstSession() async throws -> (FlakyRecordStore, InMemoryCredentialStore, UserDefaults) {
        let records = FlakyRecordStore()
        let credentials = InMemoryCredentialStore()
        let defaults = suiteDefaults()
        let (first, _) = makeRelaunchEnvironment(records: records, credentials: credentials, defaults: defaults)
        _ = try await first.addGateway(registration("workstation"))
        await first.connect(to: GatewayID(rawValue: "workstation"))
        XCTAssertTrue(first.isConnectionIntended(GatewayID(rawValue: "workstation")))
        return (records, credentials, defaults)
    }

    /// The scenePhase `.active` hook can run while launch `load()` has not
    /// populated the registry yet. That early restore must not prune the
    /// persisted intent, or the saved gateway comes back offline with no
    /// automatic reconnect.
    func testRestoreBeforeHydrationPreservesPersistedIntent() async throws {
        let (records, credentials, defaults) = try await connectedFirstSession()
        let id = GatewayID(rawValue: "workstation")
        let (second, connection) = makeRelaunchEnvironment(
            records: records, credentials: credentials, defaults: defaults)

        await second.restoreIntendedConnections()   // racing foreground hook
        XCTAssertEqual(connection.connectCount, 0)
        XCTAssertTrue(second.isConnectionIntended(id), "unhydrated restore must not erase intent")

        await second.load()
        await second.restoreIntendedConnections()
        XCTAssertEqual(second.gateways.map(\.id), [id], "saved gateway is still present")
        XCTAssertEqual(second.connectionStates[id], .connected, "automatic recovery without manual Connect")
    }

    /// A failed durable read is "unknown", not "no gateways": intent survives
    /// and a later foreground pass restores the saved gateway and reconnects.
    func testFailedDurableReadPreservesIntentAndForegroundRetryRecovers() async throws {
        let (records, credentials, defaults) = try await connectedFirstSession()
        let id = GatewayID(rawValue: "workstation")
        let (second, connection) = makeRelaunchEnvironment(
            records: records, credentials: credentials, defaults: defaults)

        records.failing = true                       // e.g. file protection while locked
        await second.load()
        XCTAssertTrue(second.gateways.isEmpty)
        XCTAssertEqual(second.hydrationPhase, .loading, "unresolved read is not 'unconfigured'")
        XCTAssertTrue(second.isConnectionIntended(id), "failed read must not erase intent")

        await second.restoreIntendedConnections()    // still failing → still no change
        XCTAssertTrue(second.isConnectionIntended(id))

        records.failing = false                      // store readable again
        await second.restoreIntendedConnections()    // foreground pass
        XCTAssertEqual(second.gateways.map(\.id), [id])
        XCTAssertEqual(second.hydrationPhase, .configured)
        XCTAssertEqual(second.connectionStates[id], .connected)
        XCTAssertEqual(connection.connectCount, 1)
    }

    /// An explicit removal still prunes intent once the registry has
    /// authoritatively answered (no resurrected connect for a deleted gateway).
    func testAuthoritativeEmptyRegistryStillPrunesIntent() async throws {
        let (records, credentials, defaults) = try await connectedFirstSession()
        let id = GatewayID(rawValue: "workstation")
        try await records.deleteGatewayRecord(id: id)
        let (second, _) = makeRelaunchEnvironment(
            records: records, credentials: credentials, defaults: defaults)
        await second.load()
        await second.restoreIntendedConnections()
        XCTAssertFalse(second.isConnectionIntended(id))
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

    func testAppRootDoesNotDisconnectOnLifecycleTransitions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("HermesFleetApp/HermesFleetApp.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("environment.disconnectAll()"))
        XCTAssertTrue(source.contains("restoreIntendedConnections()"))
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
