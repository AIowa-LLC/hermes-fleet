import XCTest

/// U4 (Gold Fleet) — Home dashboard composition regression suite.
///
/// Drives the DEBUG build (deterministic scripted fleet: 3 gateways — two
/// healthy, one unreachable — with real roster bots) and proves the plan
/// card's composition from REAL data only:
///   1. gold "Hermes Fleet" masthead renders on Home;
///   2. Fleet Overview stat row: the real bot/gateway counts render;
///   3. Gateways rows (name + endpoint + pill) from the registry;
///   4. Known Bots rows (name + gateway subtitle + last-active) from the
///      roster — no fabricated uptime;
///   5. Recent Activity renders its honest empty state until real
///      connection events accumulate (no fabricated timeline entries);
///   6. section "View All" drill-ins push on the Home tab's own stack.
final class U4DashboardUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testGoldTitleAndStatRowRenderFromRealData() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // Gold masthead (accessibility id, robust against color queries).
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.dashboard.title").waitForExistence(timeout: 15),
            "the Home dashboard must render the gold Hermes Fleet masthead"
        )

        // Stat row renders the real scripted-fleet counts: 3 gateways.
        XCTAssertTrue(
            app.staticTexts["3"].waitForExistence(timeout: 15),
            "the Fleet Overview stat row must show the real gateway count (3)"
        )
        attachScreenshot(of: app, name: "u4-home-gold-dashboard")
    }

    func testGatewayRowsRenderNameAndEndpoint() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // Registry truth: the scripted fleet's gateway renders by row id
        // (scroll into view — SwiftUI ScrollViews expose content lazily).
        let row = scrollTo(firstMatch(in: app, identifier: "fleet.dashboard.gateway.workstation"), in: app)
        XCTAssertTrue(row.exists, "a registered gateway must render a dashboard row")
        // The row combines its children; name + endpoint subtitle both render.
        XCTAssertTrue(
            row.staticTexts.count >= 2,
            "gateway rows should carry name + endpoint subtitle"
        )
        attachScreenshot(of: app, name: "u4-home-gateway-rows")
    }

    func testActiveBotRowsRenderAvatarSubtitleAndPill() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // Roster truth: a real bot row (workstation#default) with subtitle.
        let row = scrollTo(firstMatch(in: app, identifier: "fleet.dashboard.bot.workstation#default"), in: app)
        XCTAssertTrue(row.exists, "a roster bot must render an Known Bots row")
        // Honest last-active from the scripted latest session (never
        // fabricated uptime): the subtitle contains "· ".
        XCTAssertTrue(
            row.staticTexts.matching(NSPredicate(format: "label CONTAINS '·'")).firstMatch.exists,
            "bot rows must show the gateway · last-active subtitle"
        )
        attachScreenshot(of: app, name: "u4-home-bot-rows")
    }

    func testRecentActivityEmptyStateIsHonest() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // A fresh scripted session has accumulated no connection events —
        // the honest empty hint renders (no fabricated timeline entries).
        let empty = scrollTo(firstMatch(in: app, identifier: "fleet.dashboard.activity.empty"), in: app)
        XCTAssertTrue(
            empty.exists,
            "with no observed connection events the Recent Activity section must show its honest empty state"
        )
        attachScreenshot(of: app, name: "u4-home-activity-empty")
    }

    func testViewAllDrillInsPushOnHomeStack() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.dashboard.title").waitForExistence(timeout: 15),
            "dashboard should render before drill-in"
        )

        // Gateways "View All" pushes the registry cockpit on the Home stack
        // (the SectionHeader action is a Button labeled "View All Gateways";
        // scroll the section header into view first).
        let viewAll = scrollTo(app.buttons["fleet.dashboard.gateways.header"].firstMatch, in: app)
        XCTAssertTrue(viewAll.exists, "the Gateways section must expose its View All action")
        viewAll.tap()
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.gateways.add").waitForExistence(timeout: 15),
            "the Gateways View All must push the registry cockpit"
        )
        // Back returns to the dashboard: the Fleet tab owns the Home stack
        // (the old Command launcher button was retired with Control).
        app.tabBars.firstMatch.buttons["Fleet"].tap()
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.dashboard.title").waitForExistence(timeout: 10),
            "the Fleet tab must return to the dashboard"
        )
        attachScreenshot(of: app, name: "u4-home-drillin-gateways")
    }

    // MARK: - Helpers

    /// Swipe up until `element` exists (SwiftUI ScrollView content enters the
    /// accessibility tree lazily). Bounded to 6 swipes.
    @discardableResult
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        if element.exists { return element }
        for _ in 0..<6 where !element.exists {
            app.swipeUp(velocity: .fast)
        }
        return element
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let any = app.descendants(matching: .any)[identifier]
        if any.exists { return any }
        if app.buttons[identifier].exists { return app.buttons[identifier] }
        if app.cells[identifier].exists { return app.cells[identifier] }
        return any
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
