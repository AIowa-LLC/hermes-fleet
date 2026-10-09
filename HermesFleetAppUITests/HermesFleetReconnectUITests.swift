import XCTest

/// G1 debt (supplemental) + §32 walkthrough steps 8-9: "briefly lose
/// connectivity, reconnect without corrupting/duplicating".
///
/// Drives the DEBUG build's gateway lifecycle controls on the Gateways screen:
/// open the per-row menu → Disconnect → the row badge flips to "Disconnected";
/// tap the visible, gateway-specific Reconnect control → the row returns to a healthy state. The
/// conversation-level mid-stream drop + reconnect + replay dedupe (no
/// duplicated assistant rows/text) is proven by the hosted
/// ConversationFixtureLoopTests (real transport + in-process gateway) — this
/// UI test covers the observable lifecycle the user actually touches.
final class HermesFleetReconnectUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// True as soon as any element carrying one of `labels` exists. Labels are
    /// probed fresh on every pass, so this is safe to poll while the screen
    /// rewrites the row between states. The status presentation itself is
    /// width/Dynamic-Type dependent: the full row shows a text badge; when the
    /// full row does not fit, the compact row labels its status icon
    /// "Status: <state>". Both forms carry the same user-visible contract.
    private func waitForStatus(_ app: XCUIApplication, labels: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for label in labels where app.descendants(matching: .any)[label].exists {
                return true
            }
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while true
    }

    func testGatewayDisconnectThenReconnectLifecycle() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
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

        // Row badge should flip to Disconnected (brief loss of connectivity,
        // shown as the text badge or the compact row's labeled status icon).
        let disconnectedShown = waitForStatus(
            app, labels: ["Disconnected", "Status: Disconnected"], timeout: 10)
        XCTAssertTrue(disconnectedShown,
                      "row badge should show Disconnected after disconnect")

        // Reconnect directly from the row; the accessible label names the target.
        let reconnect = app.buttons["fleet.gateways.row.workstation.reconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5), "row reconnect button should appear")
        XCTAssertEqual(reconnect.label, "Reconnect Workstation")
        reconnect.tap()

        // Healthy state returns (Online / Connected / Idle badge).
        let deadline = Date().addingTimeInterval(10)
        var healthy = false
        while Date() < deadline {
            if waitForStatus(
                app, labels: ["Online", "Connected", "Status: Connected"], timeout: 0) {
                healthy = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(healthy,
                      "row badge should return to a healthy state after reconnect")
    }
}
