import XCTest
import FleetCore
import FleetUI
@testable import HermesFleetApp

/// Reproduces the UI-test create flow at the controller level against the
/// REAL simulator environment wiring (FleetServiceGraph.makeSimulatorEnvironment)
/// to prove the created bot becomes roster-visible end-to-end.
@MainActor
final class SimulatorCreateFlowTests: XCTestCase {

    func testCreateViaSimulatorEnvironmentShowsInRoster() async throws {
        let environment = FleetServiceGraph.makeSimulatorEnvironment()
        await environment.load()
        await environment.refreshRoster()

        guard let workstation = environment.gateways.first(where: { $0.id.rawValue == "workstation" }) else {
            return XCTFail("scripted fleet has the workstation gateway")
        }
        let before = environment.rosterSnapshot?.roster.bots(on: workstation.id)
            .map { $0.profileSlug.rawValue } ?? []
        XCTAssertTrue(before.contains("default") && before.contains("researcher"))
        XCTAssertFalse(before.contains("scribe-flow"), "the new name starts unused")

        // The exact CreateBotSheet submit path.
        let name = try await environment.botManagement.createBot(
            BotCreateSpec(name: "scribe-flow", title: "Scribe"), on: workstation.id)
        XCTAssertEqual(name, "scribe-flow")
        await environment.refreshRoster()

        let after = environment.rosterSnapshot?.roster.bots(on: workstation.id)
            .map { $0.profileSlug.rawValue } ?? []
        XCTAssertTrue(
            after.contains("scribe-flow"),
            "created bot visible after refresh — got \(after)")
    }
}
