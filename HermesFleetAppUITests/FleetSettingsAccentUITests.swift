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

        // Leave the simulator preference clean for the next deterministic UI
        // case after proving relaunch persistence.
        scrollToEditorAction(app, identifier: "fleet.theme.reset")
        app.buttons["fleet.theme.reset"].tap()
        app.buttons["fleet.theme.apply"].tap()
    }

    func testDraftCancelLeavesAppThemeUntouchedAndApplyReachesRichMarkdownAndStatuses() throws {
        let app = launchApp(arguments: ["-issue6-arbitrary-theme", "-issue6-theme-proof"])
        let appliedHighlight = app.staticTexts["fleet.theme.proof.applied-highlight"]
        XCTAssertTrue(appliedHighlight.waitForExistence(timeout: 10))
        let before = appliedHighlight.label

        UITabNavigation.openSettings(app)
        openThemeEditor(app)
        XCTAssertEqual(app.descendants(matching: .any)["fleet.theme.highlight"].value as? String, "#1F74C9")
        XCTAssertEqual(appliedHighlight.label, before,
                       "draft edits must not mutate the app-wide applied theme")

        app.buttons["fleet.theme.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertEqual(appliedHighlight.label, before,
                       "Cancel must leave applied theme and persistence untouched")

        openThemeEditor(app)
        app.buttons["fleet.theme.apply"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["fleet.settings.done"].tap()

        XCTAssertTrue(appliedHighlight.waitForExistence(timeout: 10))
        XCTAssertTrue(appliedHighlight.label.contains("#1F74C9"),
                      "Apply must update the environment-backed app surface")
        XCTAssertTrue(app.descendants(matching: .any)["fleet.theme.proof.rich-markdown"]
            .waitForExistence(timeout: 10),
                      "the applied palette must reach the rich Markdown renderer")
        XCTAssertTrue(app.descendants(matching: .any)["fleet.theme.proof.semantic-statuses"]
            .waitForExistence(timeout: 10))
        for label in [
            "Online", "Working", "Thinking", "Using tool", "Waiting", "Needs you",
            "Sign in required", "Degraded", "Offline", "Unknown"
        ] {
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
                .waitForExistence(timeout: 5), "semantic status remains visible: \(label)")
        }

        UITabNavigation.openSettings(app)
        openThemeEditor(app)
        scrollToEditorAction(app, identifier: "fleet.theme.reset")
        app.buttons["fleet.theme.reset"].tap()
        app.buttons["fleet.theme.apply"].tap()
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
