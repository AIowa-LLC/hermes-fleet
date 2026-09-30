import XCTest
import SwiftUI
import FleetCore
import FleetNetworking
import FleetPersistence
import FleetSecurity
import FleetUI

/// R8 (#95): `AppEnvironment.handleScenePhase` wiring of the background grace
/// window — begins only when a conversation transport is live, releases on
/// foreground without touching connections, and on expiry intentionally
/// suspends (disconnect) while leaving connection INTENT untouched. The window
/// state machine itself is covered in FleetCore's `BackgroundGraceWindowTests`.
@MainActor
final class BackgroundGraceEnvironmentTests: XCTestCase {

    private final class FakeTasks: FleetBackgroundTaskProviding {
        private(set) var began: [Int] = []
        private(set) var ended: [Int] = []
        private var expirations: [Int: @MainActor () -> Void] = [:]
        private var next = 500

        func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int? {
            next += 1
            began.append(next)
            expirations[next] = expiration
            return next
        }
        func end(_ identifier: Int) { ended.append(identifier) }
        func expire() { if let id = began.last { expirations[id]?() } }
        var leaked: [Int] { began.filter { !ended.contains($0) } }
    }

    private final class LiveSession: ConversationSessionProviding, @unchecked Sendable {
        let gatewayID: GatewayID
        nonisolated(unsafe) var statusValue: GatewayStatus = .online
        nonisolated(unsafe) private(set) var disconnectCount = 0
        let conversation: any ConversationProviding = IdleConversation()
        let replay: any ReplayProviding = IdleReplay()
        let history: any SessionHistoryProviding = IdleHistory()

        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }
        var status: GatewayStatus { statusValue }
        var liveness: ConnectionLivenessSnapshot? { nil }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async { disconnectCount += 1 }
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue)
        }
        func reauthenticate() async throws {}
    }

    private struct IdleConversation: ConversationProviding {
        var events: AsyncStream<ConversationEvent> { AsyncStream { $0.finish() } }
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            throw GatewayConnectivityError.unreachable
        }
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
        func resumeSession(sessionID: String, lastEventID: Int?, profile: String? = nil) async throws -> ConversationSession {
            throw GatewayConnectivityError.unreachable
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission { PromptSubmission(status: "ok") }
        func interrupt(sessionID: String) async throws -> InterruptResult { InterruptResult(status: "ok") }
    }

    private struct IdleReplay: ReplayProviding {
        let gatewayID = GatewayID(rawValue: "workstation")
        func watermarks() async -> [SessionEventWatermark] { [] }
        func replayAfterReconnect() async throws -> [ReplayOutcome] { [] }
    }

    private struct IdleHistory: SessionHistoryProviding {
        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
            SessionHistory(sessionID: sessionID, count: 0, messages: [])
        }
        func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
            SessionStatus(rawOutput: "", sessionID: sessionID)
        }
    }

    private struct NoSessions: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private struct StubHealth: ConnectionHealthAccumulating {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    private let gatewayID = GatewayID(rawValue: "workstation")

    private func makeEnvironment(
        tasks: FakeTasks, session: LiveSession
    ) async -> AppEnvironment {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { _, _ in fatalError("unused") })
        let roster = FleetRosterService(
            registry: registry, credentials: credentials,
            sessionFactory: { _, _ in fatalError("unused") })
        let suite = "fleet.tests.grace.\(UUID().uuidString)"
        let environment = AppEnvironment(
            registry: registry,
            roster: roster,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: NoSessions(),
            connectionFactory: { _, _ in fatalError("unused") },
            conversationFactory: { _, _ in session },
            health: StubHealth(),
            seedRegistrations: [GatewayRegistration(
                id: gatewayID, displayName: "workstation",
                endpoint: URL(string: "http://127.0.0.1:9001")!)],
            connectionIntentDefaults: UserDefaults(suiteName: suite),
            notificationDefaults: UserDefaults(suiteName: suite)!,
            backgroundTasks: tasks)
        await environment.load()
        return environment
    }

    func testBackgroundBeginsATaskOnlyWhenAConversationTransportIsLive() async {
        let tasks = FakeTasks()
        let session = LiveSession(gatewayID: gatewayID)
        let environment = await makeEnvironment(tasks: tasks, session: session)

        // No conversation session built yet: nothing to keep alive.
        environment.handleScenePhase(.background)
        XCTAssertTrue(tasks.began.isEmpty)
        environment.handleScenePhase(.active)

        _ = environment.conversationSession(for: gatewayID)
        environment.handleScenePhase(.background)
        XCTAssertEqual(tasks.began.count, 1)
        environment.handleScenePhase(.inactive)
        XCTAssertTrue(tasks.leaked.isEmpty, "any non-background phase releases the task")
        XCTAssertEqual(session.disconnectCount, 0, "returning inside the window leaves connections alone")
    }

    func testExpirySuspendsConnectionsAndEndsTheTaskPromptly() async {
        let tasks = FakeTasks()
        let session = LiveSession(gatewayID: gatewayID)
        let environment = await makeEnvironment(tasks: tasks, session: session)
        _ = environment.conversationSession(for: gatewayID)

        environment.handleScenePhase(.background)
        tasks.expire()
        for _ in 0..<100 where !tasks.leaked.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }

        XCTAssertGreaterThanOrEqual(session.disconnectCount, 1, "connections are intentionally suspended")
        XCTAssertTrue(tasks.leaked.isEmpty, "the OS task is ended")
    }

    func testBackgroundingDoesNotNotifyNorAskForPermission() async {
        let tasks = FakeTasks()
        let session = LiveSession(gatewayID: gatewayID)
        let environment = await makeEnvironment(tasks: tasks, session: session)
        environment.handleScenePhase(.background)
        XCTAssertFalse(environment.localNotifications.isEnabled, "notifications stay opt-in")
        XCTAssertEqual(environment.localNotifications.authorization, .notDetermined,
                       "no permission query or prompt is triggered by lifecycle alone")
    }
}
