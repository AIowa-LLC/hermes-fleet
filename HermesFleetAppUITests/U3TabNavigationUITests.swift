import XCTest

/// U3 (Gold Fleet) — root tab-bar navigation regression suite.
///
/// Drives the DEBUG build (scripted fleet, deterministic) and proves the
/// four-tab structure of the current shell (the old five-tab shell with
/// Activity and Settings tabs is retired — those surfaces moved under
/// Fleet/Gateways; see docs/navigation.md):
///   1. cold launch lands on Fleet with all four tabs in the tab bar;
///   2. each tab opens its real screen (roster on Bots, registry on
///      Gateways, connection activity via Gateways → Connection history,
///      App Lock toggle in the Settings sheet);
///   3. Gateways → Bots drill-in still pushes bot detail + conversation on
///      the tab's own NavigationStack, and switching tabs preserves it.
final class U3TabNavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testColdLaunchShowsFourTabsOnFleet() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // The tab bar exposes the four current tabs by label.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15), "the root shell must render a tab bar")
        for label in ["Fleet", "Chats", "Bots", "Gateways"] {
            XCTAssertTrue(tabBar.buttons[label].exists, "tab bar must include \(label)")
        }

        // Fleet is the initial tab and shows the real dashboard (the scripted
        // fleet's gateways render in the summary section — real data only).
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 15),
                      "Fleet should render the fleet dashboard with real scripted-fleet data")
        XCTAssertTrue(app.navigationBars["Fleet"].exists, "Fleet tab is initially selected")
        attachScreenshot(of: app, name: "u3-fleet-four-tabs")
    }

    func testBotsTabOpensFleetRoster() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        UITabNavigation.openBotsTab(app)
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10),
                      "the roster should list the scripted fleet's gateway sections")
        attachScreenshot(of: app, name: "u3-bots-roster")
    }

    func testGatewaysTabHostsRegistryCockpit() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        UITabNavigation.openGatewaysTab(app)
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.gateways.add").waitForExistence(timeout: 10),
                      "the Gateways toolbar must keep the Add entry")
        attachScreenshot(of: app, name: "u3-gateways-registry")
    }

    func testActivityTabShowsRealConnectionSummary() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        openActivityTab(app)
        // Real data only: the scripted fleet's gateways render a row each —
        // with honest "no activity recorded yet" lines until real connection
        // events accumulate (no fabricated timeline).
        let row = firstMatch(in: app, identifier: "fleet.activity.row.workstation")
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Connection activity must list the scripted fleet's gateways from real data")
        attachScreenshot(of: app, name: "u3-activity-real-summary")
    }

    func testSettingsTabHostsAppLockToggle() throws {
        let app = XCUIApplication()
        // Reset the persisted toggle so default-ON is deterministic even when
        // a previous suite left it OFF (same pattern as H1AppLockUITests).
        app.launchEnvironment["HERMES_FLEET_LOCK_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        openSettingsTab(app)
        let toggle = app.switches["fleet.settings.app-lock.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15),
                      "the Settings sheet must host the App Lock toggle")
        XCTAssertEqual(toggle.value as? String, "1",
                       "App Lock toggle must default to ON in the Settings sheet")
        attachScreenshot(of: app, name: "u3-settings-app-lock")
    }

    func testGatewaysDrillInPreservedAcrossTabSwitch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // Drill in on the Gateways tab: gateway → bots → bot detail.
        UITabNavigation.openGatewaysTab(app)
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10))
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        app.buttons["fleet.gateway-detail.workstation.bots"].tap()
        XCTAssertTrue(app.staticTexts["Default"].waitForExistence(timeout: 10))
        tap(firstMatch(in: app, identifier: "fleet.roster.row.workstation#default"))
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10),
            "Bot detail should render")

        // Switch away and back — the pushed detail must survive the tab
        // switch (each tab keeps its own NavigationStack). Plain tap on the
        // return trip: with bot detail pushed, the top bar is the detail's,
        // not "Hermes Fleet", so the verified-open helper does not apply.
        tapTab(app, "Fleet")
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))
        tapTab(app, "Bots")
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10),
            "Bot detail should render")
        attachScreenshot(of: app, name: "u3-tab-switch-preserves-stack")
    }

    // MARK: - Tab helpers (verified switch, one retry on a dropped tap)

    private func tapTab(_ app: XCUIApplication, _ label: String) {
        let tab = app.tabBars.firstMatch.buttons[label]
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "\(label) tab should exist")
        tab.tap()
    }

    private func openActivityTab(_ app: XCUIApplication) {
        UITabNavigation.openActivity(app)
    }

    private func openSettingsTab(_ app: XCUIApplication) {
        UITabNavigation.openSettings(app)
    }

    // MARK: - Helpers

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let any = app.descendants(matching: .any)[identifier]
        if any.exists { return any }
        if app.buttons[identifier].exists { return app.buttons[identifier] }
        if app.cells[identifier].exists { return app.cells[identifier] }
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
