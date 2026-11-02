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
        // DEV14: the sheet leads with an explanation; the report text lives
        // behind the "Preview report" disclosure.
        XCTAssertTrue(app.descendants(matching: .any)["fleet.diagnostics.explanation"].waitForExistence(timeout: 5),
                      "the sheet must explain what is and is not collected")
        let previewToggle = app.buttons["Preview report"].firstMatch
        XCTAssertTrue(previewToggle.waitForExistence(timeout: 5), "a Preview report disclosure must be offered")
        previewToggle.tap()
        let text = app.descendants(matching: .any)["fleet.diagnostics.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), "report text must render once previewed")

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
        XCTAssertTrue(app.descendants(matching: .any)["fleet.diagnostics.share"].exists, "Share must be offered")

        app.buttons["Done"].firstMatch.tap()
    }

    /// DEV14: typed description is included in the previewed report (with
    /// URLs masked), Copy confirms only after copying, and nothing is
    /// claimed as sent.
    func testReportAProblemDescriptionPreviewAndCopy() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)

        let row = app.descendants(matching: .any)["fleet.settings.report-problem"]
        for _ in 0..<6 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let field = app.textViews["fleet.diagnostics.description"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "a What happened? field must be offered")
        attach(app, "dev14-report-top")
        field.tap()
        field.typeText("Chat froze at https://private.example:9000/x?token=abc123 yesterday")
        app.buttons["fleet.diagnostics.hide-keyboard"].firstMatch.tap()

        let previewToggle = app.buttons["Preview report"].firstMatch
        XCTAssertTrue(previewToggle.waitForExistence(timeout: 5))
        previewToggle.tap()
        let text = app.descendants(matching: .any)["fleet.diagnostics.text"]
        for _ in 0..<4 where !text.exists { app.swipeUp() }
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let hasDescription = NSPredicate(format: "label CONTAINS %@", "Chat froze at")
        XCTAssertTrue(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: hasDescription, object: text)], timeout: 10) == .completed,
            "the typed description must appear in the previewed report")
        XCTAssertFalse(text.label.contains("private.example"), "URLs in the description must be masked: \(text.label)")
        XCTAssertFalse(text.label.contains("abc123"), "tokens in the description must be masked")

        let copy = app.buttons["fleet.diagnostics.copy"].firstMatch
        for _ in 0..<4 where !copy.isHittable { app.swipeUp() }
        XCTAssertFalse(app.descendants(matching: .any)["fleet.diagnostics.copied"].exists,
                       "nothing is 'Copied' before the user copies")
        attach(app, "dev14-report-preview")
        copy.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fleet.diagnostics.copied"].waitForExistence(timeout: 5),
                      "Copy must confirm once the report is on the pasteboard")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "submitted")).firstMatch.exists)
        app.buttons["Done"].firstMatch.tap()
    }

    /// Refinement Phase 3: the Theme row (identifier kept as
    /// `fleet.settings.accent`) offers the five contrast-gated curated themes;
    /// the retired accent names are gone.
    func testThemeRowRendersAndMenuOffersAllCuratedThemes() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)

        let row = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "theme row must render")
        row.tap()

        for name in ["Fleet", "Violet", "Ocean", "Orchid", "Graphite"] {
            let option = app.buttons[name].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5),
                          "the \(name) theme must be offered")
        }
        for retired in ["Yellow", "Orange", "Green"] {
            XCTAssertFalse(app.buttons[retired].firstMatch.exists,
                           "the retired \(retired) accent must not be offered")
        }
        app.buttons["Fleet"].firstMatch.tap()
    }

    func testSelectingOceanAppliesLiveAndPersistsAfterRelaunch() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)

        let row = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        selectTheme("Ocean", from: row, in: app)

        // The row's accessibility label adopts the pick immediately.
        waitForLabel(of: row, containing: "Theme, Ocean")

        // Persisted across relaunch.
        let relaunched = relaunchToSettingsRow(app)
        XCTAssertTrue(relaunched.label.contains("Ocean"),
                      "Ocean must survive relaunch (got \(relaunched.label))")

        // Leave the simulator on the default for the next deterministic case.
        selectTheme("Fleet", from: relaunched, in: app)
    }

    func testGraphiteThemeApplies() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)

        let row = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        selectTheme("Graphite", from: row, in: app)
        waitForLabel(of: row, containing: "Theme, Graphite")

        selectTheme("Fleet", from: row, in: app)
        waitForLabel(of: row, containing: "Theme, Fleet")
    }

    /// The per-appearance curated mode (`adaptiveCurated`) survives relaunch.
    func testSelectingOrchidPersistsAfterRelaunch() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)

        let row = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        selectTheme("Orchid", from: row, in: app)
        waitForLabel(of: row, containing: "Theme, Orchid")

        let relaunched = relaunchToSettingsRow(app)
        XCTAssertTrue(relaunched.label.contains("Orchid"),
                      "Orchid must survive relaunch (got \(relaunched.label))")
        selectTheme("Fleet", from: relaunched, in: app)
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

        // Select Ocean through Settings, reopen the drawer, capture again.
        UITabNavigation.closeDrawer(app)
        UITabNavigation.openSettings(app)
        let row = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let ocean = app.buttons["Ocean"].firstMatch
        XCTAssertTrue(ocean.waitForExistence(timeout: 5))
        ocean.tap()

        let app2 = app // same XCUIApplication handle; back out to the shell
        _ = UITabNavigation.openDrawer(app2)
        XCTAssertTrue(
            app2.buttons["fleet.drawer.new-chat"].firstMatch.waitForExistence(timeout: 10))
        attachScreenshot(of: app2, name: "drawer-pill-ocean-theme")

        // Restore the default theme, matching the other tests.
        UITabNavigation.closeDrawer(app2)
        UITabNavigation.openSettings(app2)
        let restore = app2.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10))
        restore.tap()
        if app2.buttons["Fleet"].firstMatch.waitForExistence(timeout: 3) {
            app2.buttons["Fleet"].firstMatch.tap()
        }
    }

    // MARK: - Helpers

    private func selectTheme(_ name: String, from row: XCUIElement, in app: XCUIApplication) {
        row.tap()
        let option = app.buttons[name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "the \(name) theme must be offered")
        option.tap()
    }

    private func waitForLabel(of row: XCUIElement, containing text: String) {
        let adopted = NSPredicate(format: "label CONTAINS %@", text)
        let exp = XCTNSPredicateExpectation(predicate: adopted, object: row)
        XCTAssertTrue(XCTWaiter().wait(for: [exp], timeout: 5) == .completed,
                      "the theme row must read \(text) (got \(row.label))")
    }

    private func relaunchToSettingsRow(_ app: XCUIApplication) -> XCUIElement {
        app.terminate()
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openSettings(app)
        let row = app.descendants(matching: .any)["fleet.settings.accent"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        return row
    }

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

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
