import XCTest

/// RT4 P2-5 UI regression: an all-healthy, zero-bot roster must show the
/// "No Bots" state instead of a row of empty section headers.
///
/// Drives the DEBUG build with `HERMES_FLEET_ZERO_BOTS=1`, which makes every
/// scripted gateway report a healthy roster with zero bots. RED (old): the
/// roster rendered empty section headers (sections non-empty whenever gateways
/// existed), so `fleet.roster.no-bots` never appeared. GREEN (fix): healthy
/// zero-bot gateways contribute no section → the No Bots state renders.
final class RT4RosterEmptyStateUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAllHealthyZeroBotRosterShowsNoBotsState() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_ZERO_BOTS"] = "1"
        app.launch()

        // The fleet still lists the seeded gateways (Home tab, real data).
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10),
                      "Home should list Workstation from the scripted fleet")

        // Open the fleet roster (Bots tab under the U3 tab shell).
        UITabNavigation.openBotsTab(app)

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
