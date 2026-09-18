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
        func resumeSession(sessionID: String, lastEventID: Int?) async throws -> ConversationSession {
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
