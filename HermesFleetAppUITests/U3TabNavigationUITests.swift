import XCTest

/// U3 (Gold Fleet) — root tab-bar navigation regression suite.
///
/// Drives the DEBUG build (scripted fleet, deterministic) and proves the
/// five-tab structure from the plan of record:
///   1. cold launch lands on Home with all five tabs in the tab bar;
///   2. each tab opens its real screen (roster on Bots, registry on
///      Gateways, activity on Activity, App Lock toggle on Settings);
///   3. Gateways → Bots drill-in still pushes bot detail + conversation on
///      the tab's own NavigationStack, and switching tabs preserves it.
final class U3TabNavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testColdLaunchShowsFiveTabsOnHome() throws {
        let app = XCUIApplication()
        app.launch()

        // The tab bar exposes the five plan tabs by label.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15), "the root shell must render a tab bar")
        for label in ["Command", "Chats", "Bots", "Workspace", "Control"] {
            XCTAssertTrue(tabBar.buttons[label].exists, "tab bar must include \(label)")
        }

        // Home is the initial tab and shows the real dashboard (the scripted
        // fleet's gateways render in the summary section — real data only).
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 15),
                      "Home should render the fleet dashboard with real scripted-fleet data")
        XCTAssertTrue(app.navigationBars["Command"].exists, "Home tab is initially selected")
        attachScreenshot(of: app, name: "u3-home-five-tabs")
    }

    func testBotsTabOpensFleetRoster() throws {
        let app = XCUIApplication()
        app.launch()

        UITabNavigation.openBotsTab(app)
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10),
                      "the roster should list the scripted fleet's gateway sections")
        attachScreenshot(of: app, name: "u3-bots-roster")
    }

    func testGatewaysTabHostsRegistryCockpit() throws {
        let app = XCUIApplication()
        app.launch()

        UITabNavigation.openGatewaysTab(app)
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.gateways.add").waitForExistence(timeout: 10),
                      "the Gateways toolbar must keep the Add entry")
        attachScreenshot(of: app, name: "u3-gateways-registry")
    }

    func testActivityTabShowsRealConnectionSummary() throws {
        let app = XCUIApplication()
        app.launch()

        openActivityTab(app)
        // Real data only: the scripted fleet's gateways render a row each —
        // with honest "no activity recorded yet" lines until real connection
        // events accumulate (no fabricated timeline).
        let row = firstMatch(in: app, identifier: "fleet.activity.row.workstation")
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Activity must list the scripted fleet's gateways from real data")
        attachScreenshot(of: app, name: "u3-activity-real-summary")
    }

    func testSettingsTabHostsAppLockToggle() throws {
        let app = XCUIApplication()
        // Reset the persisted toggle so default-ON is deterministic even when
        // a previous suite left it OFF (same pattern as H1AppLockUITests).
        app.launchEnvironment["HERMES_FLEET_LOCK_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launch()

        openSettingsTab(app)
        let toggle = app.switches["fleet.settings.app-lock.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15),
                      "the Settings tab must host the App Lock toggle")
        XCTAssertEqual(toggle.value as? String, "1",
                       "App Lock toggle must default to ON in the Settings tab")
        attachScreenshot(of: app, name: "u3-settings-app-lock")
    }

    func testGatewaysDrillInPreservedAcrossTabSwitch() throws {
        let app = XCUIApplication()
        app.launch()

        // Drill in on the Gateways tab: gateway → bots → bot detail.
        UITabNavigation.openGatewaysTab(app)
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10))
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        XCTAssertTrue(app.staticTexts["Default"].waitForExistence(timeout: 10))
        tap(firstMatch(in: app, identifier: "fleet.bots.row.workstation#default"))
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10),
            "Bot detail should render")

        // Switch away and back — the pushed detail must survive the tab
        // switch (each tab keeps its own NavigationStack). Plain tap on the
        // return trip: with bot detail pushed, the top bar is the detail's,
        // not "Hermes Fleet", so the verified-open helper does not apply.
        tapTab(app, "Command")
        XCTAssertTrue(app.navigationBars["Command"].waitForExistence(timeout: 10))
        tapTab(app, "Control")
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
