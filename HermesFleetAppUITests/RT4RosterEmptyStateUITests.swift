import XCTest

/// RT4 P2-5 UI regression: an all-healthy, zero-bot roster must show the
/// "No Bots" state instead of a row of empty section headers.
///
/// Drives the DEBUG build with `HERMES_FLEET_ZERO_BOTS=1`, which makes every
/// scripted gateway report a healthy roster with zero bots. RED (old): the
/// roster rendered empty section headers (sections non-empty whenever gateways
/// existed), so `fleet.roster.no-bots` never appeared. GREEN (fix): healthy
/// zero-bot gateways contribute no section → the No Bots state renders.
///
/// FOS-6 migration (t_9d259409): FOS-5 merged Groups into the roster
/// collection. With zero bots the workstation gateway still hosts Groups
/// (rooms), so the default All scope legitimately renders the Groups
/// section instead of the global No-Bots state — the empty-state check
/// moves to the Bots scope, where the no-bots state is the honest render
/// (verified the failure reproduces identically on the approved FOS-5
/// commit f4e1a16 — stale expectation, not a FOS-6 regression).
final class RT4RosterEmptyStateUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAllHealthyZeroBotRosterShowsNoBotsState() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_ZERO_BOTS"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // The fleet still lists the seeded gateways (Home tab, real data).
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10),
                      "Home should list Workstation from the scripted fleet")

        // Open the fleet roster (Bots tab under the U3 tab shell).
        UITabNavigation.openBotsTab(app)

        // FOS-6: default All scope legitimately renders the workstation's
        // Groups (rooms survive a zero-bot roster). Switch to the Bots
        // scope — there the all-healthy zero-bot roster must render the
        // "No Bots" state.
        let scope = app.segmentedControls["fleet.roster.scope"].firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 10), "the roster scope picker renders")
        scope.buttons["Bots"].tap()

        // P2-5: the all-healthy zero-bot roster must render the "No Bots" state
        // (a ContentUnavailableView). Its children carry the roster's `fleet.roster`
        // identifier, so assert on the visible state text rather than a flattened
        // identifier.
        let noBots = app.staticTexts["No Bots"]
        XCTAssertTrue(noBots.waitForExistence(timeout: 10),
                      "P2-5: all-healthy zero-bot roster must show the No Bots state")
        XCTAssertTrue(app.staticTexts["No profiles reported. Refresh to re-probe every gateway."].exists,
                      "P2-5: the No Bots empty state should include its description")
        attachScreenshot(of: app, name: "rt4-p2-5-zero-bots-no-bots-state")
    }

    // MARK: - Helpers

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let any = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if any.exists { return any }
        let btn = app.buttons[identifier].firstMatch
        if btn.exists { return btn }
        let cell = app.cells[identifier].firstMatch
        if cell.exists { return cell }
        return any
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "element \(element) should appear")
        element.tap()
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
