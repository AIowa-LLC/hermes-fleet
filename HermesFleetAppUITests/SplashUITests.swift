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
        XCTAssertTrue(splash.waitForExistence(timeout: 5),
                      "splash artwork should appear at launch")
        attachScreenshot(of: app, name: "p0-1-splash-visible")

        // It must hold for the minimum window, then fade out and release the
        // app UI (it must NOT linger forever). The named minimum is 1.8s +
        // 0.35s fade ≈ 2.15s; assert well above an instant swap.
        let gone = splash.waitForNonExistence(timeout: 8)
        XCTAssertTrue(gone, "splash must fade out and leave the hierarchy")
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
