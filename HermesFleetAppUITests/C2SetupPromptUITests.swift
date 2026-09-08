import XCTest

/// C2 — Settings ▸ Agent Setup Prompt door regression suite (deterministic, CI-safe).
///
/// The nav rebuild orphaned the onboarding screen behind the empty-gateways
/// state, so the setup prompt silently vanished for anyone with a configured
/// gateway. These tests assert POSITIVELY (QA discipline) that the door
/// exists on the Settings screen and opens the sheet — with the DEFAULT
/// seeded fleet (a configured gateway), i.e. exactly the state where the old
/// door disappeared. If this row is ever orphaned again, CI fails.
final class C2SetupPromptUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Settings shows the Agent Setup Prompt row (default scripted fleet —
    /// gateways EXIST, the state where the old door was unreachable).
    func testSettingsShowsSetupPromptRow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openSettings(app)

        let row = app.buttons["fleet.settings.setup-prompt"]
        // FOS-3: the Appearance section (picker + accents) sits above the
        // Agent group — scroll the row into the AX tree if needed.
        if !row.waitForExistence(timeout: 5) {
            for _ in 0..<4 where !row.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Settings must expose the Agent Setup Prompt row — the door was orphaned once; never again")
        XCTAssertTrue(app.staticTexts["Agent Setup Prompt"].exists || row.exists)
        attachScreenshot(of: app, name: "c2-settings-row")
    }

    /// The row opens the sheet: copy button, share affordance, and the
    /// versioned prompt preview are all present and work.
    func testSetupPromptRowOpensSheetWithCopyShareAndPreview() throws {
        let app = XCUIApplication()
        app.launch()
        UITabNavigation.openSettings(app)

        let row = app.buttons["fleet.settings.setup-prompt"]
        if !row.waitForExistence(timeout: 5) {
            for _ in 0..<4 where !row.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        if !row.isHittable { app.swipeUp() }
        row.tap()

        // Sheet appears with the copy + share affordances.
        let copy = app.buttons["fleet.setup-prompt.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10),
                      "the setup-prompt sheet must show the Copy button")
        XCTAssertTrue(app.buttons["fleet.setup-prompt.share"].exists,
                      "the setup-prompt sheet must show the Share affordance")
        XCTAssertTrue(app.navigationBars["Agent Setup Prompt"].waitForExistence(timeout: 5))

        // Copy confirms visibly.
        copy.tap()
        XCTAssertTrue(app.buttons["fleet.setup-prompt.copy"]
            .waitForExistence(timeout: 5))
        let confirmed = app.staticTexts["Copied — paste it in chat"].waitForExistence(timeout: 10)
            || app.buttons["fleet.setup-prompt.copy"].label.contains("Copied")
        XCTAssertTrue(confirmed, "copy must show a visible confirmation")

        // Preview renders the full versioned prompt text (v2: tunnel flow).
        let toggle = app.buttons["fleet.setup-prompt.toggle-prompt"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(app.staticTexts["The prompt you'll send"].waitForExistence(timeout: 10),
                      "prompt preview must open")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.setup-prompt.prompt-text").firstMatch.exists
                || app.staticTexts["2. Network: the gateway must be reachable"].exists,
            "the v2 prompt text must render")

        // Close dismisses back to Settings.
        app.buttons["fleet.setup-prompt.close"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Close must dismiss the sheet back to Settings")
        attachScreenshot(of: app, name: "c2-setup-prompt-sheet")
    }

    // MARK: - Helpers

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
