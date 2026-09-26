import XCTest

/// ChatGPT-style accent picker (dogfood: replaces the full theme editor).
///
/// The class name stays in the FOS inventory so the canonical UI matrix
/// keeps running this settings lane.
final class FleetSettingsAccentUITests: XCTestCase {

    /// RC-84 P0-A: the diagnostics door — "Report a Problem" opens the
    /// sanitized report sheet (identity header + Copy), built from this
    /// process's real facts.
    func testReportAProblemSheetRendersSanitizedReport() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)

        let row = app.descendants(matching: .any)["fleet.settings.report-problem"]
        for _ in 0..<6 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Report a Problem row must render")
        row.tap()

        let sheet = app.descendants(matching: .any)["fleet.diagnostics.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "diagnostics sheet must open")
        let text = app.descendants(matching: .any)["fleet.diagnostics.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), "report text must render")

        // The report carries its generated identity + honest sections.
        let hasReportID = NSPredicate(format: "label CONTAINS %@", "Report ID: DF-")
        XCTAssertTrue(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: hasReportID, object: text)], timeout: 10) == .completed,
            "report must carry its generated identity")
        let hasContext = NSPredicate(format: "label CONTAINS %@", "Settings · Report a Problem")
        XCTAssertTrue(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: hasContext, object: text)], timeout: 5) == .completed,
            "report must name its surface context")
        XCTAssertTrue(app.descendants(matching: .any)["fleet.diagnostics.copy"].exists, "Copy must be offered")

        app.buttons["Done"].firstMatch.tap()
    }

    func testAccentRowRendersAndMenuOffersAllCuratedAccents() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)

        let row = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "accent row must render")
        row.tap()

        // All eight curated colors are offered (ChatGPT's set + the Fleet
        // mono White, ADR-0009).
        for name in ["Blue", "Green", "Yellow", "Pink", "Orange", "Purple", "Black", "White"] {
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

    /// ADR-0009: White is the mono accent — applies live, persists across
    /// relaunch, and the Settings row reflects it.
    func testSelectingWhiteAppliesMonoAndPersistsAfterRelaunch() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)

        let row = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let white = app.buttons["White"].firstMatch
        XCTAssertTrue(white.waitForExistence(timeout: 5), "the White option must be offered")
        white.tap()

        let adopted = NSPredicate(format: "label CONTAINS %@", "Accent, White")
        let exp = XCTNSPredicateExpectation(predicate: adopted, object: row)
        XCTAssertTrue(XCTWaiter().wait(for: [exp], timeout: 5) == .completed,
                      "the accent row must reflect White immediately (got \(row.label))")

        app.terminate()
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openSettings(app)
        let relaunched = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(relaunched.waitForExistence(timeout: 10))
        XCTAssertTrue(relaunched.label.contains("White"),
                      "White must survive relaunch (got \(relaunched.label))")

        // Leave the simulator on the same post-class state as before
        // (Black), matching the Purple test's cleanup contract.
        relaunched.tap()
        if app.buttons["White"].firstMatch.waitForExistence(timeout: 3) {
            app.buttons["Black"].firstMatch.tap()
        }
    }

    /// ADR-0009 visual evidence: the drawer compose pill follows the active
    /// theme highlight. Attaches screenshots of the drawer (pill region)
    /// under the default palette, for the current appearance. Runs in the
    /// existing accent lane so no new UI matrix row is required.
    func testDrawerPillFollowsThemeEvidence() throws {
        let app = launchApp()
        _ = UITabNavigation.openDrawer(app)
        XCTAssertTrue(
            app.buttons["fleet.drawer.new-chat"].firstMatch.waitForExistence(timeout: 10),
            "the drawer compose pill must render")
        attachScreenshot(of: app, name: "drawer-pill-default-accent")

        // Select Blue through Settings, reopen the drawer, capture again.
        UITabNavigation.closeDrawer(app)
        UITabNavigation.openSettings(app)
        let row = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let blue = app.buttons["Blue"].firstMatch
        XCTAssertTrue(blue.waitForExistence(timeout: 5))
        blue.tap()

        let app2 = app // same XCUIApplication handle; back out to the shell
        _ = UITabNavigation.openDrawer(app2)
        XCTAssertTrue(
            app2.buttons["fleet.drawer.new-chat"].firstMatch.waitForExistence(timeout: 10))
        attachScreenshot(of: app2, name: "drawer-pill-blue-accent")

        // Restore the post-class state (Black), matching the other tests.
        UITabNavigation.closeDrawer(app2)
        UITabNavigation.openSettings(app2)
        let restore = app2.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10))
        restore.tap()
        if app2.buttons["Blue"].firstMatch.waitForExistence(timeout: 3) {
            app2.buttons["Black"].firstMatch.tap()
        }
    }

    // MARK: - Helpers

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        if !extraArguments.isEmpty { app.launchArguments += extraArguments }
        app.launch()
        return app
    }
}
