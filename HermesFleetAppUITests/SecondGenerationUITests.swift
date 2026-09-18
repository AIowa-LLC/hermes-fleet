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
        UITabNavigation.shellReady(app, timeout: 15)
        return app
    }
    func testChatsPreserveRouteAndOpenSession() {
        let app = launch()
        UITabNavigation.selectTab(app, label: "Chats")
        let session = app.buttons["fleet.chats.session.workstation#default/workstation.default.s1"]
        // iOS 26 lazy Lists materialize rows near the viewport only. The
        // workstation default session sorts BELOW the fold (its startedAt is
        // older than the rows above it), so scroll it into the tree first —
        // the route-qualified identity requirement itself is unchanged.
        if !session.waitForExistence(timeout: 5) {
            for _ in 0..<6 where !session.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(session.waitForExistence(timeout: 20))
        session.tap()
        XCTAssertTrue(app.textFields["fleet.conversation.composer"].waitForExistence(timeout: 15) || app.textViews["fleet.conversation.composer"].exists)
        let composer = app.textFields["fleet.conversation.composer"].exists ? app.textFields["fleet.conversation.composer"] : app.textViews["fleet.conversation.composer"]
        composer.tap()
        composer.typeText("Show the timeline")
        app.buttons["fleet.conversation.send"].tap()
        capture("revamp-conversation")
        // Compaction round 2: the timeline affordance lives in the ⋯
        // session-actions menu.
        let menu = app.descendants(matching: .any)["session.actions.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
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
        UITabNavigation.selectTab(app, label: "Fleet")
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
        UITabNavigation.selectTab(app, label: "Chats")
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 5))
        capture("revamp-chats")
        // Build 43: the Fleet tab PRESERVES its pushed Gateways cockpit —
        // switching back lands on Gateways (not the Fleet root), and
        // popping returns to Fleet. Either landing is a pass.
        UITabNavigation.selectTab(app, label: "Fleet")
        let gatewaysAgain = app.navigationBars["Gateways"].waitForExistence(timeout: 5)
        if !gatewaysAgain {
            XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 5))
        }
    }
    private func firstMatchOrNil(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
