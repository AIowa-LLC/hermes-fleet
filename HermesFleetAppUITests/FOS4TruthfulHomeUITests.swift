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

    private func launch(navReset: Bool = true, selectFleet: Bool = true, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        if navReset { app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1" }
        for (key, value) in extra { app.launchEnvironment[key] = value }
        app.launch()
        // Build 41+: cold launch lands on BOTS — this suite asserts FLEET
        // dashboard content, so select Fleet first (verified switch, the
        // shared-helper contract). The zero-gateway case skips it: the
        // first-run setup gate owns the whole UI.
        if selectFleet { UITabNavigation.openTabToFleet(app) }
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
        // Zero-gateway fleet: the first-run gate owns the UI (no tab shell
        // at all) — launch WITHOUT the Fleet selection.
        let app = launch(selectFleet: false, extra: ["HERMES_FLEET_ZERO_GATEWAYS": "1"])
        // First-run gate: a hydrated ZERO-gateway fleet never renders the
        // dashboard at all — it lands on the first-server setup experience.
        // The old guarantee (never fabricate "0/0" stats for an empty fleet)
        // is now structural: the dashboard is unreachable with zero gateways.
        let setup = app.otherElements["fleet.root.onboarding"]
        XCTAssertTrue(
            setup.waitForExistence(timeout: 15),
            "an empty fleet must land on setup, never a dashboard with fabricated 0/0 stats"
        )
        let scan = app.buttons["fleet.first-run.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15), "first-server setup offers QR scanning")
        XCTAssertTrue(scan.isEnabled)
        XCTAssertFalse(app.textFields["fleet.onboarding.address"].exists,
                       "the normal first-server flow must not expose the retired address form")
        XCTAssertFalse(
            app.staticTexts["fleet.dashboard.glance.connected"].waitForExistence(timeout: 2),
            "the glance strip must not render for an unconfigured fleet"
        )
        attachScreenshot(of: app, name: "fos4-empty-fleet-setup")
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

    /// DEV14: two recent conversations with the same bot on the same gateway
    /// are distinguishable by their own titles (not both "default"), and a
    /// row opens the exact conversation it names: re-opening the OLDER row
    /// promotes that same conversation to the top.
    func testContinueRowsDistinguishSameBotSessionsAndOpenTheIntendedOne() throws {
        let app = launch(extra: ["HERMES_FLEET_CONTINUE_SEED": "same-bot"])
        let first = app.buttons["fleet.dashboard.continue.row.0"]
        if !first.waitForExistence(timeout: 5) {
            for _ in 0..<8 where !first.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(first.waitForExistence(timeout: 15), "seeded recent conversations render")
        let second = app.buttons["fleet.dashboard.continue.row.1"]
        XCTAssertTrue(second.exists)
        XCTAssertTrue(first.label.contains("Fleet setup"), "newest row names its own session: \(first.label)")
        XCTAssertTrue(second.label.contains("Replay plan review"), "older row names its own session: \(second.label)")
        XCTAssertNotEqual(first.label, second.label)
        for row in [first, second] {
            XCTAssertTrue(row.label.contains("Default"), "rows name the bot: \(row.label)")
            XCTAssertTrue(row.label.contains("Workstation"), "rows name the gateway: \(row.label)")
        }
        attachScreenshot(of: app, name: "dev14-continue-distinct")

        second.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 20)
                      || app.textFields.firstMatch.waitForExistence(timeout: 5),
                      "the conversation opens")
        UITabNavigation.openTabToFleet(app)
        let reopened = app.buttons["fleet.dashboard.continue.row.0"]
        for _ in 0..<8 where !reopened.exists { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(reopened.waitForExistence(timeout: 15))
        XCTAssertTrue(reopened.label.contains("Replay plan review"),
                      "opening the older row opened exactly that conversation (now most recent): \(reopened.label)")
    }

    /// DEV14: Home states honestly that nothing needs attention and shows the
    /// "Resume a conversation" header with the device-local empty state.
    func testHomeHierarchyHeadersAndEmptyStates() throws {
        let app = launch(extra: ["HERMES_FLEET_CONTINUE_RESET": "1"])
        XCTAssertTrue(app.staticTexts["fleet.dashboard.status"].waitForExistence(timeout: 15)
                      || app.otherElements["fleet.dashboard.status"].waitForExistence(timeout: 5),
                      "a concise connection status line leads Home")
        let header = app.staticTexts["fleet.dashboard.continue.header"]
        for _ in 0..<8 where !header.exists { app.swipeUp(velocity: .fast) }
        XCTAssertEqual(header.label, "Resume a conversation")
        XCTAssertTrue(app.staticTexts["fleet.dashboard.continue.empty"].exists)
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
