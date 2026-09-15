import XCTest

/// End-to-end regression for the dogfood defect where a repaired gateway
/// remained offline in Bots until the user pressed Refresh.
@MainActor
final class BotsPresenceSyncUITests: XCTestCase {
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    private func firstMatch(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testBotsPresenceRecoversAfterConnectWithoutManualRefresh() throws {
        let app = XCUIApplication()
        self.app = app
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_CONNECT_SYNC"] = "1"
        app.launch()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))
        app.tabBars.buttons["Bots"].tap()
        let outage = firstMatch(app, "fleet.roster.outage.workstation")
        let ghost = firstMatch(app, "fleet.roster.row.workstation#researcher")
        XCTAssertTrue(outage.waitForExistence(timeout: 15) || ghost.waitForExistence(timeout: 5))

        app.tabBars.buttons["Gateways"].tap()
        let row = firstMatch(app, "fleet.gateways.row.workstation")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let connect = firstMatch(app, "fleet.gateway-detail.connect.workstation")
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        connect.tap()

        app.tabBars.buttons["Bots"].tap()
        let recovered = firstMatch(app, "fleet.roster.row.workstation#researcher")
        XCTAssertTrue(recovered.waitForExistence(timeout: 20))
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "Online")
        expectation(for: predicate, evaluatedWith: recovered)
        waitForExpectations(timeout: 20)

        // Manual refresh remains available; it is no longer required to make
        // a successful connection's roster truth appear.
        XCTAssertTrue(firstMatch(app, "fleet.roster.refresh").exists)
    }
}
