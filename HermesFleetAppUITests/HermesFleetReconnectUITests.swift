import XCTest

/// G1 debt (supplemental) + §32 walkthrough steps 8-9: "briefly lose
/// connectivity, reconnect without corrupting/duplicating".
///
/// Drives the DEBUG build's gateway lifecycle controls on the Gateways screen:
/// open the per-row menu → Disconnect → the row badge flips to "Disconnected";
/// open the menu → Reconnect → the row returns to a healthy state. The
/// conversation-level mid-stream drop + reconnect + replay dedupe (no
/// duplicated assistant rows/text) is proven by the hosted
/// ConversationFixtureLoopTests (real transport + in-process gateway) — this
/// UI test covers the observable lifecycle the user actually touches.
final class HermesFleetReconnectUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testGatewayDisconnectThenReconnectLifecycle() throws {
        let app = XCUIApplication()
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10),
                      "Gateways screen should list Workstation")

        // Open the row menu, tap Disconnect.
        let menu = app.descendants(matching: .any)["fleet.gateways.row.workstation.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "row menu should exist")
        menu.tap()
        let disconnect = app.buttons["Disconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5), "Disconnect menu item should appear")
        disconnect.tap()

        // Row badge should flip to Disconnected (brief loss of connectivity).
        let disconnected = app.staticTexts["Disconnected"].firstMatch
        XCTAssertTrue(disconnected.waitForExistence(timeout: 10),
                      "row badge should show Disconnected after disconnect")

        // Reconnect via the same menu.
        let menuAgain = app.descendants(matching: .any)["fleet.gateways.row.workstation.menu"]
        XCTAssertTrue(menuAgain.waitForExistence(timeout: 10))
        menuAgain.tap()
        let reconnect = app.buttons["Reconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5), "Reconnect menu item should appear")
        reconnect.tap()

        // Healthy state returns (Online / Connected / Idle badge).
        let deadline = Date().addingTimeInterval(10)
        var healthy = false
        while Date() < deadline {
            if app.staticTexts["Online"].exists || app.staticTexts["Connected"].exists {
                healthy = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(healthy,
                      "row badge should return to a healthy state after reconnect")
    }
}
