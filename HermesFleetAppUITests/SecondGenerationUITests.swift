import XCTest

/// New navigation workflows, using only the simulator fixture.
/// FOS-1/§6 migration: the retired Control/Workspace roots now live under
/// Gateways → Gateway Detail (resource rows); Command Center is unchanged.
final class SecondGenerationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        return app
    }
    func testChatsPreserveRouteAndOpenSession() {
        let app = launch()
        app.tabBars.buttons["Chats"].tap()
        let session = app.buttons["fleet.chats.session.workstation#default/workstation.default.s1"]
        XCTAssertTrue(session.waitForExistence(timeout: 20))
        session.tap()
        XCTAssertTrue(app.textFields["fleet.conversation.composer"].waitForExistence(timeout: 15) || app.textViews["fleet.conversation.composer"].exists)
        let composer = app.textFields["fleet.conversation.composer"].exists ? app.textFields["fleet.conversation.composer"] : app.textViews["fleet.conversation.composer"]
        composer.tap()
        composer.typeText("Show the timeline")
        app.buttons["fleet.conversation.send"].tap()
        capture("revamp-conversation")
        let timeline = app.buttons["fleet.conversation.timeline.open"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        timeline.tap()
        XCTAssertTrue(app.navigationBars["Timeline"].waitForExistence(timeout: 5))
        capture("revamp-timeline")
        let turn = app.collectionViews.buttons.firstMatch
        if turn.exists { turn.tap() } else { app.buttons["Done"].tap() }
    }
    /// Workspace successor: Projects + Kanban live beneath Gateway Detail
    /// (§11), reached from the Gateways tab.
    func testGatewayResourcesAndCommandCenter() {
        let app = launch()
        // Projects beneath the workstation cockpit (explicit scope).
        UITabNavigation.openScopedPane(app, resource: "projects", profile: "default")
        XCTAssertTrue(firstMatchOrNil(app, "fleet.projects.row.proj-fleet").waitForExistence(timeout: 15))
        capture("revamp-projects-scoped")
        // Command Center (global launcher) unchanged — it lives on the
        // Fleet root toolbar (§6).
        app.tabBars.firstMatch.buttons["Fleet"].tap()
        let commandCenter = app.buttons["fleet.command-center.open"]
        XCTAssertTrue(commandCenter.waitForExistence(timeout: 10))
        commandCenter.tap()
        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 5))
        capture("revamp-command-center")
    }
    /// Control successor: the Gateways tab owns machine operations, and tab
    /// stacks stay independent across switches.
    func testGatewaysAndChatsPreserveTabStacks() {
        let app = launch()
        UITabNavigation.openGatewaysTab(app)
        capture("revamp-gateways")
        app.tabBars.buttons["Chats"].tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 5))
        capture("revamp-chats")
        app.tabBars.buttons["Gateways"].tap()
        XCTAssertTrue(app.navigationBars["Hermes Fleet"].waitForExistence(timeout: 5))
    }
    private func firstMatchOrNil(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
