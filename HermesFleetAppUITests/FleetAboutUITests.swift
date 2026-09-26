import XCTest

/// ADR-0011: the About tab — identity, version, and the official legal
/// surface (Terms of Use / Privacy Policy on hermes-fleet.aiowa.dev,
/// Support unchanged). Dogfood round 2: About's entry point is the Settings
/// root's About row (the drawer circle is retired).
/// Deterministic scripted-fleet suite: no live gateway.
final class FleetAboutUITests: XCTestCase {

    func testAboutTabRendersIdentityVersionAndLegalRows() throws {
        let app = launchApp()
        UITabNavigation.openAbout(app)

        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 10),
                      "About renders as a tab with its own nav bar")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "fleet.about").firstMatch.waitForExistence(timeout: 10),
            "the About surface identifier must render")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "fleet.about.identity").firstMatch.waitForExistence(timeout: 10),
            "the identity block must render")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "fleet.about.version").firstMatch.waitForExistence(timeout: 10),
            "the version row must render on About")
        XCTAssertTrue(app.staticTexts["Hermes Fleet"].exists,
                      "the identity block names the app")

        for identifier in ["fleet.about.terms", "fleet.about.privacy-policy", "fleet.about.support"] {
            XCTAssertTrue(app.descendants(matching: .any)
                .matching(identifier: identifier).firstMatch.waitForExistence(timeout: 10),
                "About must expose \(identifier)")
        }
        attachScreenshot(of: app, name: "about-tab")
    }

    func testAboutReachableFromSettingsRow() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)
        // Dogfood round 2: About's entry point is the Settings root's About
        // row (the drawer circle is retired).
        let aboutRow = app.buttons["fleet.settings.about"].firstMatch
        XCTAssertTrue(aboutRow.waitForExistence(timeout: 10),
                      "the Settings root must carry the About row")
        for _ in 0..<4 where !(aboutRow.exists && aboutRow.isHittable) {
            app.swipeUp(velocity: .fast)
        }
        aboutRow.tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 10),
                      "the Settings About row must select the About tab")
        // The retired drawer control must be gone.
        _ = UITabNavigation.openDrawer(app)
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "fleet.drawer.destination.about").firstMatch.exists,
            "the drawer About circle must be retired")
        UITabNavigation.closeDrawer(app)
        attachScreenshot(of: app, name: "about-from-settings")
    }

    func testSettingsSecurityAndDataSubScreensPush() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)

        // Security push
        let security = app.descendants(matching: .any)
            .matching(identifier: "fleet.settings.security").firstMatch
        XCTAssertTrue(security.waitForExistence(timeout: 10),
                      "Settings must expose the Security chevron row")
        security.tap()
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 10),
                      "Security must push its sub-screen")
        XCTAssertTrue(app.switches["fleet.settings.app-lock.toggle"].waitForExistence(timeout: 10),
                      "the App Lock toggle lives in the Security sub-screen")
        attachScreenshot(of: app, name: "settings-security-subscreen")

        // Back to the Settings root, then Data & Storage push
        app.buttons["BackButton"].firstMatch.tap() /* Back to Settings */
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let data = app.descendants(matching: .any)
            .matching(identifier: "fleet.settings.data").firstMatch
        XCTAssertTrue(data.waitForExistence(timeout: 10),
                      "Settings must expose the Data & Storage chevron row")
        data.tap()
        XCTAssertTrue(app.navigationBars["Data & Storage"].waitForExistence(timeout: 10),
                      "Data & Storage must push its sub-screen")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "fleet.settings.delete-local-cache").firstMatch
            .waitForExistence(timeout: 10),
            "the cache-clear action lives in the Data & Storage sub-screen")
        attachScreenshot(of: app, name: "settings-data-subscreen")
    }

    func testSettingsAppearanceMenuRowAppliesSelection() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)

        // ADR-0011 W2: one-row value picker; options render in the menu.
        let row = app.descendants(matching: .any)
            .matching(identifier: "fleet.settings.appearance").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "the Appearance row must render on the Settings root")
        row.tap()
        let dark = app.buttons["Dark"].firstMatch
        XCTAssertTrue(dark.waitForExistence(timeout: 5), "the menu must offer Dark")
        dark.tap()
        // The row value adopts the pick.
        let adopted = NSPredicate(format: "label CONTAINS %@", "Appearance, Dark")
        let exp = XCTNSPredicateExpectation(predicate: adopted, object: row)
        XCTAssertTrue(XCTWaiter().wait(for: [exp], timeout: 5) == .completed,
                      "the Appearance row must reflect Dark immediately (got \(row.label))")
        // Restore System for the following suites.
        row.tap()
        let system = app.buttons["System"].firstMatch
        if system.waitForExistence(timeout: 5) { system.tap() }
    }

    // MARK: - Helpers

    private func launchApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        if !extraArguments.isEmpty { app.launchArguments += extraArguments }
        app.launch()
        UITabNavigation.shellReady(app)
        return app
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
