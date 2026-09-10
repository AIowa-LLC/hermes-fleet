import XCTest

/// Issue #6 — deterministic coverage for the V1 custom theme editor.
///
/// The class name remains in the existing FOS-7 inventory so the canonical UI
/// matrix keeps running this settings lane. The old accent-picker assertions
/// were retired because the product now exposes one applied three-color
/// palette instead of the five-value accent enum.
final class FleetSettingsAccentUITests: XCTestCase {

    func testThemeEditorIsReachableAndOffersNativeColorPickers() throws {
        let app = launchApp()
        UITabNavigation.openSettings(app)
        openThemeEditor(app)

        for identifier in [
            "fleet.theme.highlight",
            "fleet.theme.text",
            "fleet.theme.background"
        ] {
            let picker = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(picker.waitForExistence(timeout: 5),
                          "native ColorPicker (identifier) should render")
        }

        XCTAssertTrue(app.descendants(matching: .any)["fleet.theme.preview"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["fleet.theme.contrast.text"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["fleet.theme.apply"]
            .waitForExistence(timeout: 5))

        // Reset and Apply are explicit, user-visible actions in the editor.
        scrollToEditorAction(app, identifier: "fleet.theme.reset")
        app.buttons["fleet.theme.reset"].tap()
        app.buttons["fleet.theme.apply"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    func testThemeEditorShowsLowContrastWarningAndCanReset() throws {
        let app = launchApp(arguments: ["-issue6-low-contrast"])
        UITabNavigation.openSettings(app)
        openThemeEditor(app)

        let warning = app.descendants(matching: .any)["fleet.theme.contrast.warning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5),
                      "the deterministic low-contrast fixture should warn")

        scrollToEditorAction(app, identifier: "fleet.theme.reset")
        app.buttons["fleet.theme.reset"].tap()
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5),
                      "Reset should remove the low-contrast warning")
        app.buttons["fleet.theme.apply"].tap()
    }

    func testArbitraryPaletteAppliesAndPersistsAfterRelaunch() throws {
        let app = launchApp(arguments: ["-issue6-arbitrary-theme"])
        UITabNavigation.openSettings(app)
        openThemeEditor(app)

        let highlight = app.descendants(matching: .any)["fleet.theme.highlight"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 5))
        XCTAssertEqual(highlight.value as? String, "#1F74C9")
        app.buttons["fleet.theme.apply"].tap()

        app.terminate()
        app.launchArguments = []
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openSettings(app)
        openThemeEditor(app)

        let persistedHighlight = app.descendants(matching: .any)["fleet.theme.highlight"]
        XCTAssertTrue(persistedHighlight.waitForExistence(timeout: 5))
        XCTAssertEqual(persistedHighlight.value as? String, "#1F74C9",
                       "Apply must persist the arbitrary highlight palette value")
    }

    private func launchApp(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        return app
    }

    private func openThemeEditor(_ app: XCUIApplication) {
        let entry = app.buttons["fleet.settings.theme"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5),
                      "Settings should expose the V1 theme editor")
        entry.tap()
        XCTAssertTrue(app.navigationBars["Theme"].waitForExistence(timeout: 5))
    }

    private func scrollToEditorAction(_ app: XCUIApplication, identifier: String) {
        let action = app.buttons[identifier]
        for _ in 0..<6 where !action.exists {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(action.waitForExistence(timeout: 5),
                      "Theme editor action (identifier) should be reachable")
    }
}
