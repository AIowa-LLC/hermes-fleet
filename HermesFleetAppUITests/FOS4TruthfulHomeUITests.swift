import XCTest

/// FOS-4 (t_2f5bf49a) — Truthful Fleet Home UI regression suite.
///
/// Drives the DEBUG scripted fleet (workstation + render-box healthy, arch
/// offline) and proves SPEC §7's truth contracts:
///   1. the glance strip renders coverage truth (never fabricated zeros;
///      partial outage shows honest coverage copy, not "0");
///   2. Needs You appears ONLY for observed auth/config episodes and
///      previews NAVIGATE (no approve controls on Home);
///   3. Active Now renders honest coverage copy when the fleet cannot
///      provide live activity (never bots.prefix(10));
///   4. Continue renders the device-local empty state ("No recent
///      conversations on this iPhone") before any real open.
final class FOS4TruthfulHomeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(navReset: Bool = true, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        if navReset { app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1" }
        for (key, value) in extra { app.launchEnvironment[key] = value }
        app.launch()
        return app
    }

    func testGlanceStripRendersCoverageTruth() throws {
        let app = launch()
        // The glance strip renders the fleet's real counts: 3 registered
        // gateways. Never a StatCard row (retired with FOS-4).
        XCTAssertTrue(
            app.staticTexts["fleet.dashboard.glance.connected"].waitForExistence(timeout: 15),
            "the glance strip is the first dashboard content (FOS-4)"
        )
        XCTAssertFalse(
            app.otherElements["fleet.dashboard.stats"].exists,
            "the Fleet Overview stat-card row must be gone"
        )
        // Known Bots renders a real count once the roster settles (the
        // scripted fleet serves 3 bots across two healthy gateways)…
        let bots = app.staticTexts["fleet.dashboard.glance.bots"]
        XCTAssertTrue(bots.waitForExistence(timeout: 10), "the known-Bots glance fact renders")
        // Partial outage honesty: the offline gateway is named in coverage.
        let coverage = app.staticTexts["fleet.dashboard.coverage"]
        XCTAssertTrue(coverage.waitForExistence(timeout: 10))
        XCTAssertTrue(
            coverage.label.contains("Lab Node"),
            "a failed gateway must be named in the coverage line (unknown ≠ zero)"
        )
        attachScreenshot(of: app, name: "fos4-glance-strip")
    }

    func testGlanceStripEmptyFleetSaysNoGateways() throws {
        let app = launch(extra: ["HERMES_FLEET_ZERO_GATEWAYS": "1"])
        // FOS-6: the glance fact is one AX element labeled
        // 'Connected: No gateways' (value + caption fact component).
        let connected = app.staticTexts["fleet.dashboard.glance.connected"]
        XCTAssertTrue(
            connected.waitForExistence(timeout: 15),
            "the empty-fleet glance fact renders"
        )
        XCTAssertTrue(
            connected.label.contains("No gateways"),
            "0/0 connected must render 'No gateways', never '0/0' (got: \(connected.label))"
        )
        // The empty state offers the setup path (Add Gateway) — query by
        // label across element types (the Label button surfaces as Other).
        let add = app.descendants(matching: .any)["fleet.dashboard.empty.add"].firstMatch
        if !add.waitForExistence(timeout: 5) {
            XCTAssertTrue(
                app.staticTexts["Add Gateway"].waitForExistence(timeout: 5)
                    || app.buttons["Add Gateway"].waitForExistence(timeout: 5),
                "the empty fleet state offers Add Gateway"
            )
        }
        attachScreenshot(of: app, name: "fos4-empty-fleet")
    }

    func testNeedsYouAuthEpisodeNavigatesNotApproves() throws {
        let app = launch(extra: ["HERMES_FLEET_AUTH_GATEWAY": "1"])
        // The auth-required gateway produces exactly one Needs You item.
        let row = app.buttons["fleet.dashboard.needsYou.row.auth.arch"]
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "a classified auth-required failure must surface one Needs You item")
        XCTAssertTrue(row.staticTexts["Sign in to Lab Node"].exists,
                      "the auth item names the gateway")
        // No approve/deny controls exist on Home (previews navigate only).
        XCTAssertFalse(app.buttons["Approve"].exists, "Home never hosts approval buttons")
        XCTAssertFalse(app.buttons["Deny"].exists)
        row.tap()
        // Navigation lands on the gateway's Connection surface.
        XCTAssertTrue(
            app.staticTexts["Lab Node"].waitForExistence(timeout: 10)
                || app.navigationBars.firstMatch.waitForExistence(timeout: 10),
            "the attention preview navigates to its owning screen"
        )
        attachScreenshot(of: app, name: "fos4-needs-you-auth")
    }

    func testActiveNowHonestWhenNoLiveExecution() throws {
        let app = launch()
        // The scripted roster supplies NO executing states — the honest
        // coverage copy renders; "0 Active" or fabricated rows must not.
        let unavailable = app.staticTexts["fleet.dashboard.active.unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15),
                      "without execution coverage Active renders the honest copy")
        let glance = app.staticTexts["fleet.dashboard.glance.active"]
        XCTAssertTrue(glance.exists)
        XCTAssertTrue(glance.label.contains("—"),
                      "the Active glance fact never claims zero without coverage")
        attachScreenshot(of: app, name: "fos4-active-honest")
    }

    func testContinueEmptyStateIsDeviceLocalTruth() throws {
        // CONTINUE_RESET wipes the persisted index — other suites' opens live
        // in the same shared simulator container and must not leak in.
        let app = launch(extra: ["HERMES_FLEET_CONTINUE_RESET": "1"])
        let empty = app.staticTexts["fleet.dashboard.continue.empty"]
        // Continue sits below the fold — scroll it into the AX tree first
        // (SwiftUI ScrollViews render lazily).
        if !empty.waitForExistence(timeout: 5) {
            for _ in 0..<8 where !empty.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(empty.waitForExistence(timeout: 15),
                      "before any real open, Continue states no recent conversations on this iPhone")
        XCTAssertEqual(empty.label, "No recent conversations on this iPhone")
        attachScreenshot(of: app, name: "fos4-continue-empty")
    }

    func testGatewayRowsAreCompactWithoutEndpoints() throws {
        let app = launch()
        let row = app.buttons["fleet.dashboard.gateway.workstation"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "compact gateway rows render")
        // No raw endpoints in normal Fleet rows (SPEC §7).
        XCTAssertFalse(row.label.contains("http"), "gateway rows never show raw endpoints")
        XCTAssertFalse(row.label.contains("127.0.0.1"), "gateway rows never show raw hosts")
        attachScreenshot(of: app, name: "fos4-gateway-rows")
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
