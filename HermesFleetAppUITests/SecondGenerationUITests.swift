import XCTest

/// New navigation and Desktop-inspired workflows, using only the simulator fixture.
final class SecondGenerationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
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
    func testWorkspaceAndCommandCenter() {
        let app = launch()
        app.tabBars.buttons["Workspace"].tap()
        XCTAssertTrue(app.navigationBars["Workspace"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["fleet.workspace.gateway.workstation"].exists)
        capture("revamp-workspace")
        app.buttons["fleet.command-center.open"].tap()
        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 5))
        capture("revamp-command-center")
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("Memory")
        XCTAssertTrue(app.buttons["Memory Graph"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Memory Graph"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Memory Graph"].waitForExistence(timeout: 10))
    }
    func testControlAndChatsPreserveTabStacks() {
        let app = launch()
        app.tabBars.buttons["Control"].tap()
        XCTAssertTrue(app.navigationBars["Control"].waitForExistence(timeout: 5))
        capture("revamp-control")
        app.buttons["Gateways"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Hermes Fleet"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Chats"].tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 5))
        capture("revamp-chats")
        app.tabBars.buttons["Control"].tap()
        XCTAssertTrue(app.navigationBars["Hermes Fleet"].waitForExistence(timeout: 5))
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
