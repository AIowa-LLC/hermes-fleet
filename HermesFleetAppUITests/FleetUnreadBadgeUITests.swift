import XCTest

/// Dogfood r4 (ChatGPT parity): unread dots on Chats rows and drawer
/// Recents, the menu-button badge, drawer-only search, and neutral chrome.
/// Deterministic scripted-fleet suite: no live gateway.
final class FleetUnreadBadgeUITests: XCTestCase {

    func testMenuButtonRendersGlassWithThemeBadge() throws {
        let app = launchApp()
        UITabNavigation.selectTab(app, label: "Chats")
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "fleet.chats.unread."))
                .firstMatch
                .waitForExistence(timeout: 10),
            "Chats must load the unread fixture before the menu aggregate is checked")
        XCTAssertTrue(app.buttons["fleet.drawer.open"].waitForExistence(timeout: 10),
                      "the menu button must render")
        XCTAssertTrue(
            app.buttons["fleet.drawer.open"].label.localizedCaseInsensitiveContains("unread conversations"),
            "the menu button must expose the unread aggregate")
        attachScreenshot(of: app, name: "r4-menu-button")
    }

    func testSearchIsDrawerOnlyAndDrawerCircleOpensCommandCenter() throws {
        let app = launchApp()
        // The retired toolbar button must be GONE on every root.
        UITabNavigation.shellReady(app)
        XCTAssertFalse(app.buttons["fleet.command-center.open"].exists,
                       "the toolbar search button must be retired (drawer-only)")
        UITabNavigation.openCommandCenter(app)
        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 10))
        attachScreenshot(of: app, name: "r4-drawer-search")
    }

    func testSettingsExposesManageGatewaysRowRoutingToFleetStack() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)
        let row = app.buttons["fleet.settings.gateways"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Settings must expose the Manage Gateways row")
        if !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.navigationBars["Gateways"].waitForExistence(timeout: 10),
                      "the Settings row must route to the registry cockpit")
        attachScreenshot(of: app, name: "r4-settings-gateways")
    }

    func testChatsUnreadDotRendersAndClearsOnOpen() throws {
        let app = launchApp()
        UITabNavigation.selectTab(app, label: "Chats")
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))

        // The unread fixture deliberately skips first-observation baselining so
        // the scripted lastActive row exercises the indicator and clear path.
        let dotPrefix = "fleet.chats.unread."
        let dotQuery = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", dotPrefix)).firstMatch
        XCTAssertTrue(dotQuery.waitForExistence(timeout: 10),
                      "at least one Chats row must render an unread dot")

        // Capture the dotted id as a STRING (never hold a stale element proxy
        // across a navigation round-trip).
        let dotID = try XCTUnwrap(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", dotPrefix))
                .allElementsBoundByIndex.first?.identifier)
        let sessID = dotID.replacingOccurrences(of: dotPrefix, with: "")
        let row = app.buttons["fleet.chats.session.\(sessID)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the dotted session row must exist")
        row.tap()

        let back = app.buttons["fleet.conversation.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10),
                      "the conversation's custom back control must render")
        back.tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))

        // Re-query by the exact identifier each poll; disappearance is the
        // pass condition.
        var stillThere = true
        for _ in 0..<10 where stillThere {
            stillThere = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@", dotID)).firstMatch.exists
            if stillThere { usleep(500_000) }
        }
        XCTAssertFalse(stillThere, "opening the conversation must clear its unread dot")
        attachScreenshot(of: app, name: "r4-chats-dot")
    }

    func testDrawerRecentsUnreadDotRendersAndClearsOnOpen() throws {
        let app = launchApp()
        UITabNavigation.selectTab(app, label: "Chats")
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        usleep(1_000_000)

        UITabNavigation.openDrawer(app)
        let dotPrefix = "fleet.drawer.recent.unread."
        let dot = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", dotPrefix)).firstMatch
        XCTAssertTrue(dot.waitForExistence(timeout: 10),
                      "drawer Recents must render an unread dot")
        let dotID = try XCTUnwrap(dot.identifier)
        let entryID = dotID.replacingOccurrences(of: dotPrefix, with: "")
        let row = app.buttons["fleet.drawer.recent.\(entryID)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "the unread drawer Recents row must exist")
        row.tap()

        let back = app.buttons["fleet.conversation.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        UITabNavigation.openDrawer(app)

        var stillThere = true
        for _ in 0..<10 where stillThere {
            stillThere = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@", dotID)).firstMatch.exists
            if stillThere { usleep(500_000) }
        }
        XCTAssertFalse(stillThere, "opening from drawer Recents must clear its unread dot")
        attachScreenshot(of: app, name: "r4-drawer-recents-dot")
    }

    // MARK: - Helpers

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_UNREAD_FIXTURE"] = "1"
        app.launch()
        UITabNavigation.shellReady(app)
        return app
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
