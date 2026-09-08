import XCTest

/// P0-1 / V7 re-pin (t_9ce36690 / D5 §4) — the launch splash: system
/// background with the white-wing identity mark centered. The mark must
/// appear, hold for a minimum window, then cross-fade into the app UI (no
/// instant tear into the roster). No wordmark, no teal, no gold — the old
/// full-bleed artwork pins (teal field + gold mark) are retired with the
/// V6 artwork and live in git history.
///
/// Drives the DEBUG build (scripted fleet, deterministic). The splash is a
/// testable seam: `HERMES_FLEET_SPLASH=on` forces the overlay on even under
/// XCUITest (which otherwise skips it to keep the other suites fast).
final class SplashUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSplashAppearsHoldsThenFadesIntoApp() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_SPLASH"] = "on"
        // Deterministic hold for the test: a cold CI simulator can take >2s to
        // attach its first accessibility query, so we extend the product hold
        // (1.8s, locked by the unit test) to a generous 4s window. The product
        // default is exercised/asserted separately by SplashConfigurationTests.
        app.launchEnvironment["HERMES_FLEET_SPLASH_HOLD"] = "4.0"

        // Anchor the window from BEFORE launch: app.launch() returns once the
        // first frame (and the in-app splash) is on screen, so the elapsed
        // time to disappearance is the true splash window. Measuring from
        // waitForExistence instead would under-count by XCUITest's query
        // resolution latency and make the hold assertion flaky.
        let launched = Date()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // V7 pin: the white-wing identity mark is on screen at launch
        // (registers before the app tears into the main UI).
        let splash = app.descendants(matching: .any)["fleet.splash.artwork"].firstMatch
        XCTAssertTrue(splash.waitForExistence(timeout: 8),
                      "splash white-wing mark should appear at launch")
        attachScreenshot(of: app, name: "v7-splash-wing-mark")

        // The mark is a centered modest mark (not a full-bleed artwork): its
        // frame must sit INSIDE the screen, roughly centered horizontally.
        let frame = splash.frame
        let screen = app.frame
        XCTAssertTrue(screen.insetBy(dx: -2, dy: -2).contains(frame),
                      "splash mark frame (\(frame)) should sit inside the screen (\(screen))")
        XCTAssertEqual(
            frame.midX, screen.midX, accuracy: 4,
            "splash mark should be horizontally centered (midX \(frame.midX) vs \(screen.midX))"

        )

        // Then it must cross-fade OUT and release the app UI (it must NOT
        // linger forever). Budget: 4s hold + 0.35s fade + slack.
        let gone = splash.waitForNonExistence(timeout: 8)
        XCTAssertTrue(gone, "splash must fade out and leave the hierarchy")

        // The on-screen window, anchored from BEFORE launch, is the splash's
        // real display time (launch() returns once the first frame — and the
        // in-app splash — is up). Assert it's a held window, not an instant
        // tear. (Anchoring inside waitForExistence would under-count by
        // XCUITest query latency; that's why we don't sleep-and-check mid-hold.)
        let window = Date().timeIntervalSince(launched)
        XCTAssertGreaterThan(
            window, 1.5,
            "splash on-screen \(window)s from launch — expected a held minimum window, not an instant tear"
        )

        // After the splash, the app must be interactive — roster renders.
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10),
                      "roster should render after the splash fades")
        attachScreenshot(of: app, name: "v7-roster-after-splash")
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
