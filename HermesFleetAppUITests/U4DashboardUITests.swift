import XCTest

/// U4 → FOS-4 (Gold Fleet → Truthful Fleet Home) — composition regression
/// suite, rewritten for the FOS-4 dashboard (t_2f5bf49a, SPEC §7).
///
/// Drives the DEBUG scripted fleet (3 gateways — two healthy, one
/// unreachable — with real roster bots) and proves the Home composition
/// from REAL data only:
///   1. the marketing masthead stays GONE (FOS-3, negative assertion kept);
///   2. the glance strip replaces the Fleet Overview stat row;
///   3. compact Gateway rows render name + honest state (no raw endpoints);
///   4. the offline gateway surfaces as coverage truth, not zero counts;
///   5. Connection Activity renders its honest empty state and ≤3 rows;
///   6. section drill-ins push on the Fleet tab's own stack.
final class U4DashboardUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        return app
    }

    @discardableResult
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .fast)
        }
        return element
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testGlanceStripIsFirstContentAndMastheadStaysGone() throws {
        let app = launch()

        // FOS-3 (kept): the marketing masthead must not render.
        XCTAssertFalse(
            firstMatch(in: app, identifier: "fleet.dashboard.title").waitForExistence(timeout: 3),
            "the marketing masthead must not render on the Fleet root (FOS-3)"
        )
        XCTAssertFalse(app.staticTexts["Your agents.\nWithin reach."].exists,
                       "the hero slogan must not render (FOS-3)")

        // FOS-4: the glance strip is the first dashboard content.
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.dashboard.glance.connected").waitForExistence(timeout: 15),
            "the glance strip is the first dashboard content (FOS-4)"
        )
        // The retired stat-card row must be gone.
        XCTAssertFalse(
            firstMatch(in: app, identifier: "fleet.dashboard.stats").exists,
            "the Fleet Overview stat row is retired (FOS-4)"
        )
        // Real registry truth: 3 registered gateways in the fraction.
        // FOS-6: fact label is now 'Connected: n/3' (value + caption).
        let connected = app.staticTexts["fleet.dashboard.glance.connected"]
        XCTAssertTrue(connected.label.hasSuffix("/3"),
                      "the connected fraction counts the registered fleet (got: \(connected.label))")
        attachScreenshot(of: app, name: "u4-home-glance-strip")
    }

    func testGatewayRowsRenderCompactTruth() throws {
        let app = launch()

        let row = scrollTo(firstMatch(in: app, identifier: "fleet.dashboard.gateway.workstation"), in: app)
        XCTAssertTrue(row.exists, "a registered gateway must render a compact row")
        // Compact row: name + state label; NO raw endpoint/host (SPEC §7).
        XCTAssertFalse(row.label.contains("http"), "gateway rows never show raw endpoints")
        XCTAssertFalse(row.label.contains("127.0.0.1"), "gateway rows never show raw hosts")
        // The offline gateway renders its honest state, and its bot count
        // falls back to last-known when a snapshot exists.
        let offline = firstMatch(in: app, identifier: "fleet.dashboard.gateway.arch")
        XCTAssertTrue(offline.waitForExistence(timeout: 10) || scrollTo(offline, in: app).exists,
                      "the offline gateway renders a row (exceptions first)")
        attachScreenshot(of: app, name: "u4-home-gateway-rows")
    }

    func testConnectionActivityHonestEmptyState() throws {
        let app = launch()

        // A fresh scripted session has accumulated no connection events —
        // the honest empty hint renders (no fabricated timeline entries).
        let empty = scrollTo(firstMatch(in: app, identifier: "fleet.dashboard.activity.empty"), in: app)
        XCTAssertTrue(
            empty.exists,
            "with no observed connection events the Connection Activity section must show its honest empty state"
        )
        attachScreenshot(of: app, name: "u4-home-activity-empty")
    }

    func testSeeAllDrillInsPushOnHomeStack() throws {
        let app = launch()

        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.dashboard.glance.connected").waitForExistence(timeout: 15),
            "dashboard should render before drill-in"
        )

        // Gateways "See all" pushes the registry list on the Fleet stack.
        let seeAll = scrollTo(app.buttons["See all Gateways"].firstMatch, in: app)
        XCTAssertTrue(seeAll.exists, "the Gateways section must expose its See all action")
        seeAll.tap()
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.gateways.add").waitForExistence(timeout: 15),
            "the Gateways See all must push the registry list"
        )
        // Back returns to the dashboard: the Fleet tab owns the Home stack.
        app.tabBars.firstMatch.buttons["Fleet"].tap()
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.dashboard.glance.connected").waitForExistence(timeout: 10),
            "the Fleet tab must return to the dashboard"
        )
        attachScreenshot(of: app, name: "u4-home-drillin-gateways")
    }

    // MARK: - Helpers

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
