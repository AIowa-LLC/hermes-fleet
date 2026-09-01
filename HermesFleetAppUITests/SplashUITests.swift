import XCTest

/// P0-1 — the launch splash (Tony's artwork) must appear, hold for a minimum
/// window, then cross-fade into the app UI (no instant tear into the roster).
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
        app.launch()

        // Query any element carrying the splash identifier (SwiftUI may
        // surface the artwork as an image or another element type).
        let splash = app.descendants(matching: .any)["fleet.splash.artwork"].firstMatch

        // The splash artwork must be on screen at launch (registers before
        // the app tears into the main UI).
        XCTAssertTrue(splash.waitForExistence(timeout: 8),
                      "splash artwork should appear at launch")
        attachScreenshot(of: app, name: "p0-1-splash-visible")

        // P0-6 crop regression: the artwork must be UNCROPPED (aspect-fit,
        // never aspect-fill) and centered on the full screen. The asset is
        // 941x1672 (~0.563 w/h) — WIDER than a ~19.5:9 phone screen (~0.46),
        // so the correct fit is width-limited: full screen WIDTH with
        // symmetric top/bottom letterbox bars. (An aspect-FILL layout would
        // instead render at the screen's ~0.46 ratio — the two are far apart,
        // so a band on the asset ratio cleanly separates fit from fill.)
        // Verified against live pixel evidence: 1320x2868 screenshot renders
        // the artwork at 1320px wide (full width) x 2349px tall.
        let frame = splash.frame
        let screen = app.frame
        let frameAspect = frame.width / frame.height
        let assetAspect = 941.0 / 1672.0 // LaunchArtwork.png
        XCTAssertEqual(frameAspect, assetAspect, accuracy: 0.06,
                       "splash artwork aspect \(frameAspect) must match the asset \(assetAspect) — cropped/aspect-fill regression")
        // Full-bleed horizontally: a width-limited fit touches both edges.
        XCTAssertGreaterThan(frame.width, screen.width * 0.99,
                             "aspect-fit artwork (wider than screen) must span the full screen width")
        // Centered vertically with (imperceptible, near-black) letterbox
        // bars above and below: equal margins, both > 0.
        let topBar = frame.minY - screen.minY
        let bottomBar = screen.maxY - frame.maxY
        XCTAssertEqual(topBar, bottomBar, accuracy: 2.0,
                       "splash artwork must be centered (top bar \(topBar) vs bottom bar \(bottomBar))")
        XCTAssertGreaterThan(min(topBar, bottomBar), 0,
                             "width-limited fit must letterbox vertically — filling the height would crop the artwork width")
        attachScreenshot(of: app, name: "p0-6-splash-uncropped")

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
            "splash on-screen \(window)s from launch — expected a held minimum window, not an instant tear")

        // After the splash, the app must be interactive — roster renders.
        XCTAssertTrue(app.staticTexts["MacBook M5"].waitForExistence(timeout: 10),
                      "roster should render after the splash fades")
        attachScreenshot(of: app, name: "p0-1-roster-after-splash")
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
