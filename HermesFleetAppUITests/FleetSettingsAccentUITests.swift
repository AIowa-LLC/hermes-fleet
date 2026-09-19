import XCTest

/// ChatGPT-style accent picker (dogfood: replaces the full theme editor).
///
/// The class name stays in the FOS inventory so the canonical UI matrix
/// keeps running this settings lane.
final class FleetSettingsAccentUITests: XCTestCase {

    func testAccentRowRendersAndMenuOffersSevenColors() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)

        let row = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "accent row must render")
        row.tap()

        // All seven curated colors are offered (ChatGPT's set).
        for name in ["Blue", "Green", "Yellow", "Pink", "Orange", "Purple", "Black"] {
            let option = app.buttons[name].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5),
                          "the \(name) option must be offered")
        }
    }

    func testSelectingPurpleAppliesLiveAndPersistsAfterRelaunch() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)

        let row = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let purple = app.buttons["Purple"].firstMatch
        XCTAssertTrue(purple.waitForExistence(timeout: 5))
        purple.tap()

        // The row's accessibility value adopts the pick immediately.
        let adopted = NSPredicate(format: "label CONTAINS %@", "Accent, Purple")
        let exp = XCTNSPredicateExpectation(predicate: adopted, object: row)
        XCTAssertTrue(XCTWaiter().wait(for: [exp], timeout: 5) == .completed,
                      "the accent row must reflect Purple immediately (got \(row.label))")

        // Persisted across relaunch.
        app.terminate()
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openSettings(app)
        let relaunched = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(relaunched.waitForExistence(timeout: 10))
        XCTAssertTrue(relaunched.label.contains("Purple"),
                      "Purple must survive relaunch (got \(relaunched.label))")

        // Leave the simulator on the default for the next deterministic case.
        relaunched.tap()
        let def = app.buttons["Purple"].firstMatch
        if def.waitForExistence(timeout: 3) { app.buttons["Black"].firstMatch.tap() }
    }

    func testBlackAccentApplies() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)

        let row = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let black = app.buttons["Black"].firstMatch
        XCTAssertTrue(black.waitForExistence(timeout: 5))
        black.tap()

        let adopted = NSPredicate(format: "label CONTAINS %@", "Accent, Black")
        let exp = XCTNSPredicateExpectation(predicate: adopted, object: row)
        XCTAssertTrue(XCTWaiter().wait(for: [exp], timeout: 5) == .completed,
                      "Black applies immediately (got \(row.label))")

        // Restore the default for the next case.
        row.tap()
        if app.buttons["Purple"].firstMatch.waitForExistence(timeout: 3) {
            app.buttons["Purple"].firstMatch.tap()
        }
    }

    // MARK: - Helpers

    private func launchApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        if !extraArguments.isEmpty { app.launchArguments += extraArguments }
        app.launch()
        return app
    }
}
