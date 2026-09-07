import XCTest
import FleetCore
@testable import HermesFleetApp

/// Hosted verification of the simulator create-visible flow: a profile
/// created through the scripted Bot Mode profile seam must appear in the
/// scripted roster fixtures on the next refresh.
final class ScriptedCreateFlowTests: XCTestCase {

    @MainActor
    func testCreatedProfileJoinsScriptedRoster() async throws {
        let gatewayID = GatewayID(rawValue: "workstation")
        let seam = ScriptedBotProfileSeam(gatewayID: gatewayID)

        // Baseline: fixture bots only.
        let before = ScriptedFleet.profiles(on: gatewayID).map(\.name)
        XCTAssertEqual(before, ["default", "researcher"])

        // Create through the seam (what BotManagementController drives).
        _ = try await seam.createProfile(BotCreateSpec(name: "scribe-unit", title: "Scribe"))

        let after = ScriptedFleet.profiles(on: gatewayID).map(\.name)
        XCTAssertEqual(after, ["default", "researcher", "scribe-unit"],
                       "created profile joins the scripted roster fixtures")

        // Other gateways unaffected.
        XCTAssertFalse(
            ScriptedFleet.profiles(on: GatewayID(rawValue: "render-box"))
                .contains { $0.name == "scribe-unit" })
    }
}
