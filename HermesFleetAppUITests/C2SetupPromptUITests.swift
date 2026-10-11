import XCTest

/// C2 — existing users can open and cancel owner enrollment from Settings.
/// Keep the registered suite name stable while retiring the former
/// copy/share prompt workflow.
final class C2SetupPromptUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsEnrollmentDoorOpensAndCancels() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openSettings(app)

        let row = app.buttons["fleet.settings.connect-server"]
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "configured users must have a path to connect another server")
        for _ in 0..<8 where !row.isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(row.isHittable, "the Settings enrollment entry must be onscreen before tapping")
        row.tap()
        XCTAssertTrue(app.textFields["fleet.onboarding.address"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.onboarding.dismiss"].exists)
        app.buttons["fleet.onboarding.dismiss"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "cancel returns to Settings")
    }
}
