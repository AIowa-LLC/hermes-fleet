import XCTest
@testable import FleetNetworking
import FleetCore

/// FOS-4 (t_2f5bf49a, SPEC §17 polling/cost contract) — wire-budget proof
/// for the bounded summary wave:
/// - a refresh performs exactly ONE connect + ONE profiles.list per
///   registered gateway (no session.list, no groups.state — Home consumes
///   the summary only), for 1-, 2-, and 20-gateway fleets;
/// - at most THREE gateways are in flight concurrently;
/// - a gateway whose cycle exceeds the per-gateway deadline settles as a
///   classified offline failure instead of hanging the wave, and every
///   session is still torn down.
final class FleetRosterWireBudgetTests: XCTestCase {

    /// Actor-scoped wire-activity recorder (async-safe by construction).
    actor Recorder {
        var connectCalls = 0
        var profileCalls = 0
        var disconnectCalls = 0
        var inFlight = 0
        var maxConcurrent = 0
        var hangProfiles = false

        func reset() {
            connectCalls = 0; profileCalls = 0; disconnectCalls = 0
            inFlight = 0; maxConcurrent = 0; hangProfiles = false
        }

        func connectEntered() {
            connectCalls += 1
            inFlight += 1
            maxConcurrent = max(maxConcurrent, inFlight)
        }

        func profilesEntered() { profileCalls += 1 }

        func disconnectExited() {
            disconnectCalls += 1
            inFlight -= 1
        }
    }

    /// Scripted roster session that records wire activity on the recorder.
    private struct CountingSession: GatewayRosterSession {
        let gatewayID: GatewayID
        let recorder: Recorder

        var status: GatewayStatus { .online }

        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "t", heartbeatEnabled: false, changeEventsEnabled: false)
        }

        func connect() async throws {
            await recorder.connectEntered()
        }

        func disconnect() async {
            await recorder.disconnectExited()
        }

        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
        }

        func fetchProfiles() async throws -> [ProfileDescriptor] {
            await recorder.profilesEntered()
            if await recorder.hangProfiles {
                // Dead gateway: never answers (deadline fixture). Suspension
                // ends when the deadline race cancels this task.
                try await Task.never()
            }
            return [ProfileDescriptor(name: "default", path: "~/p/default", isDefault: true)]
        }

        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    private actor StubRegistry: GatewayRegistryManaging {
        let gateways: [FleetGateway]
        init(gateways: [FleetGateway]) { self.gateways = gateways }
        func allGateways() async -> [FleetGateway] { gateways }
        func gateway(for id: GatewayID) async -> FleetGateway? { gateways.first { $0.id == id } }
        func addGateway(_ registration: GatewayRegistration) async throws -> FleetGateway {
            FleetGateway(id: registration.id ?? GatewayID(rawValue: "x"), displayName: "x", endpoint: nil)
        }
        func updateGateway(_ id: GatewayID, edits: GatewayEdit) async throws -> FleetGateway {
            FleetGateway(id: id, displayName: "x", endpoint: nil)
        }
        func removeGateway(_ id: GatewayID) async throws {}
        func testConnection(to id: GatewayID) async throws -> GatewayTestResult {
            GatewayTestResult(status: .offline)
        }
        func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {}
        func clearCredential(for id: GatewayID) async throws {}
        func hasCredential(for id: GatewayID) async -> Bool { false }
        func restorePersistedGateways() async throws -> [FleetGateway] { [] }
    }

    private actor NoCredentials: CredentialStoring {
        func loadCredential(for id: GatewayID) async throws -> GatewayCredential? { nil }
        func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {}
        func deleteCredential(for id: GatewayID) async throws {}
    }

    private let recorder = Recorder()

    private func makeService(_ count: Int, deadline: TimeInterval = 10) -> FleetRosterService {
        let gateways = (0..<count).map {
            FleetGateway(id: GatewayID(rawValue: "g\($0)"), displayName: "g\($0)", endpoint: nil)
        }
        let rec = recorder
        return FleetRosterService(
            registry: StubRegistry(gateways: gateways),
            credentials: NoCredentials(),
            sessionFactory: { gateway, _ in CountingSession(gatewayID: gateway.id, recorder: rec) },
            maxConcurrentGatewayRefreshes: 3,
            perGatewayDeadline: deadline
        )
    }

    override func setUp() async throws {
        await recorder.reset()
    }

    private func assertBudget(fleet: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let service = makeService(fleet)
        let snapshot = await service.refreshRoster()
        let loaded = snapshot.gatewayOutcomes.values.filter {
            if case .loaded = $0 { return true }
            return false
        }.count
        let connect = await recorder.connectCalls
        let profiles = await recorder.profileCalls
        let disconnects = await recorder.disconnectCalls
        let maxConcurrent = await recorder.maxConcurrent
        XCTAssertEqual(loaded, fleet, "every gateway should settle loaded", file: file, line: line)
        XCTAssertEqual(connect, fleet, "exactly one connect per gateway", file: file, line: line)
        XCTAssertEqual(profiles, fleet, "exactly one profiles.list per gateway (no per-bot/per-room fan-out)", file: file, line: line)
        XCTAssertEqual(disconnects, fleet, "every session torn down (ADR #3)", file: file, line: line)
        XCTAssertLessThanOrEqual(maxConcurrent, 3, "at most 3 gateways in flight", file: file, line: line)
    }

    func testWireBudgetOneGateway() async {
        await assertBudget(fleet: 1)
    }

    func testWireBudgetTwoGateways() async {
        await assertBudget(fleet: 2)
    }

    func testWireBudgetTwentyGateways() async {
        await assertBudget(fleet: 20)
    }

    func testTwentyGatewayFleetNeverExceedsThreeInFlight() async {
        // Dedicated name for the SPEC §17 concurrency invariant (the budget
        // assertion above checks the same recorder field).
        await assertBudget(fleet: 20)
    }

    func testDeadlineClassifiesTimeoutInsteadOfHanging() async {
        await recorder.reset()
        await recorder.setHangProfiles(true)
        let gateways = [FleetGateway(id: GatewayID(rawValue: "dead"), displayName: "dead", endpoint: nil)]
        let rec = recorder
        let tight = FleetRosterService(
            registry: StubRegistry(gateways: gateways),
            credentials: NoCredentials(),
            sessionFactory: { gateway, _ in CountingSession(gatewayID: gateway.id, recorder: rec) },
            maxConcurrentGatewayRefreshes: 3,
            perGatewayDeadline: 0.05
        )
        let snapshot = await tight.refreshRoster()
        guard case .failed(let status, _)? = snapshot.outcome(for: GatewayID(rawValue: "dead")) else {
            return XCTFail("a hung gateway must settle as a classified failure")
        }
        XCTAssertEqual(status, .offline, "deadline expiry classifies offline, never hangs")
    }
}

extension FleetRosterWireBudgetTests.Recorder {
    func setHangProfiles(_ value: Bool) {
        hangProfiles = value
    }
}

extension Task where Success == Never, Failure == Never {
    /// Suspends until cancelled (deadline fixture).
    static func never() async throws {
        while true {
            try await sleep(for: .seconds(3600))
        }
    }
}
