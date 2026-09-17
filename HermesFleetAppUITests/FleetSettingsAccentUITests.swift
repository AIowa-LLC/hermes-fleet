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

    /// B41: a white-highlight palette (the new dark default) must be
    /// APPLYABLE — the invisible-pair guard refuses only literally
    /// invisible pairs, and white over the dark default background is
    /// 19.3:1. Applying then relaunching must persist it.
    func testWhiteHighlightPaletteAppliesAndPersistsAfterRelaunch() throws {
        let app = launchApp(arguments: ["-b41-white-highlight"])
        UITabNavigation.openSettings(app)
        openThemeEditor(app)

        let highlight = app.descendants(matching: .any)["fleet.theme.highlight"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 5))
        XCTAssertEqual(highlight.value as? String, "#FFFFFF",
                       "the white-highlight fixture must seed the draft")

        app.buttons["fleet.theme.apply"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5),
                      "Apply must succeed — white on the dark default background is not invisible")

        app.terminate()
        app.launchArguments = []
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openSettings(app)
        openThemeEditor(app)

        let persisted = app.descendants(matching: .any)["fleet.theme.highlight"]
        XCTAssertTrue(persisted.waitForExistence(timeout: 5))
        XCTAssertEqual(persisted.value as? String, "#FFFFFF",
                       "the white highlight must survive relaunch")

        // Leave the simulator preference clean for the next deterministic UI case.
        scrollToEditorAction(app, identifier: "fleet.theme.reset")
        app.buttons["fleet.theme.reset"].tap()
        app.buttons["fleet.theme.apply"].tap()
    }

    /// B41: the apply boundary refuses a literally invisible pair. The
    /// fixture sets a WHITE highlight over a WHITE light-mode background;
    /// Apply must fail with the visible error and persist nothing.
    func testInvisibleWhiteOnWhitePaletteIsRefusedAtApply() throws {
        let app = launchApp(arguments: ["-b41-invisible-palette"])
        UITabNavigation.openSettings(app)
        openThemeEditor(app)

        let highlight = app.descendants(matching: .any)["fleet.theme.highlight"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 5))
        XCTAssertEqual(highlight.value as? String, "#FFFFFF")

        scrollToEditorAction(app, identifier: "fleet.theme.apply")
        app.buttons["fleet.theme.apply"].tap()

        // The error row renders at the END of the lazy Form — swipe it into
        // the materialized window before querying (iOS 26 lazy Forms only
        // materialize rows near the viewport).
        let error = app.descendants(matching: .any)["fleet.theme.apply-error"]
        for _ in 0..<6 where !error.exists {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(error.waitForExistence(timeout: 5),
                      "the invisible palette must be refused with a visible error")
        XCTAssertTrue(app.navigationBars["Theme"].waitForExistence(timeout: 5),
                      "the editor must stay open — nothing was applied")

        app.buttons["fleet.theme.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
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
        let highlightPicker = app.descendants(matching: .any)["fleet.theme.highlight"]
        XCTAssertTrue(highlightPicker.waitForExistence(timeout: 10),
                      "the theme editor must render its Highlight picker")
        XCTAssertEqual(highlightPicker.value as? String, "#1F74C9")
        XCTAssertEqual(appliedHighlight.label, before,
                       "draft edits must not mutate the app-wide applied theme")

        app.buttons["fleet.theme.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertEqual(appliedHighlight.label, before,
                       "Cancel must leave applied theme and persistence untouched")

        openThemeEditor(app)
        app.buttons["fleet.theme.apply"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        // Build 43: Settings is a tab — leave via the Bots tab (no Done).
        UITabNavigation.selectTab(app, label: "Bots")

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

        // Reset the persisted arbitrary palette so later suites start
        // clean. The Apply dismissal returned to Settings, then Bots was
        // tapped — land back on Settings through the shared,
        // engagement-verified helper (Build 41 selectTab retries a dropped
        // drawer/tab tap and waits for the screen; no arbitrary sleeps).
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
        // Build 43: Settings is a TAB. Ensure the Settings screen is
        // frontmost first (the theme entry only exists there), with a
        // retry — the first tab tap can be dropped during the splash
        // overlay's cross-fade window.
        let settingsBar = app.navigationBars["Settings"]
        for _ in 0..<3 where !settingsBar.exists {
            UITabNavigation.selectTab(app, label: "Settings")
            _ = settingsBar.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 10),
                      "the Settings tab must host the theme editor")
        let entry = app.buttons["fleet.settings.theme"]
        let themeBar = app.navigationBars["Theme"]
        // The entry tap can be dropped while the tab-switch transition is
        // still settling (iOS 26): tap, verify the editor actually pushed,
        // and re-tap while it did not — engagement over sleeps.
        for _ in 0..<3 where !themeBar.exists {
            XCTAssertTrue(entry.waitForExistence(timeout: 5),
                          "Settings should expose the V1 theme editor")
            scrollToEditorAction(app, identifier: "fleet.settings.theme")
            entry.tap()
            _ = themeBar.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(themeBar.waitForExistence(timeout: 5),
                      "the theme editor must open after the entry tap")
    }

    /// iOS 26 lazy Forms materialize rows only near the viewport — scroll
    /// the target row into the AX tree before tapping/querying it.
    private func scrollToThemeRow(_ app: XCUIApplication, identifier: String) {
        let row = app.descendants(matching: .any)[identifier]
        for _ in 0..<6 where !row.exists {
            app.swipeUp(velocity: .fast)
        }
    }

    private func scrollToEditorAction(_ app: XCUIApplication, identifier: String) {
        let action = app.buttons[identifier]
        for _ in 0..<6 where !(action.exists && action.isHittable) {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(action.waitForExistence(timeout: 5),
                      "Theme editor action (identifier) should be reachable")
    }
}
