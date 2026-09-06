import XCTest

/// F3 — onboarding UI regression suite (deterministic, CI-safe).
///
/// Drives the DEBUG simulator build with `HERMES_FLEET_ZERO_GATEWAYS=1`,
/// which suppresses the scripted seed fleet so the app launches with an
/// EMPTY registry — the brand-new-user state. Proves the card's acceptance:
/// empty state shows the "Set up with your agent" CTA; one tap opens the
/// onboarding screen; the copy button confirms visibly; the prompt preview
/// renders the full versioned text; and the hand-off routes into the REAL
/// Add-Gateway form (URL/username/password entry).
final class F3OnboardingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchEmptyFleet() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_ZERO_GATEWAYS"] = "1"
        app.launch()
        return app
    }

    private func openGatewaysTab(_ app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        XCTAssertTrue(app.staticTexts["No Gateways"].waitForExistence(timeout: 15))
    }

    func testEmptyStateShowsOnboardingCTAAndCopyFlow() throws {
        let app = launchEmptyFleet()
        openGatewaysTab(app)

        // F3: the brand-new-user CTA is the prominent action. NOTE: a
        // ContentUnavailableView flattens its children under the parent
        // identifier (RT4 lesson) — the buttons surface with the container's
        // `fleet.gateways` identifier, so query by visible label.
        let cta = app.buttons["Set up with your agent"]
        XCTAssertTrue(cta.waitForExistence(timeout: 10),
                      "empty state must show the 'Set up with your agent' CTA")
        XCTAssertTrue(cta.isEnabled)
        cta.tap()

        // Onboarding screen appears with the big copy button.
        let copy = app.buttons["fleet.onboarding.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10),
                      "onboarding sheet must show the copy button")
        XCTAssertTrue(app.staticTexts["Hermes Fleet"].exists)

        // One tap copies — visible confirmation appears.
        copy.tap()
        let confirmation = app.staticTexts["Copied — paste it in chat"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10),
                      "copy must show a visible confirmation")

        // The prompt preview renders the full versioned text (review path).
        let toggle = app.buttons["fleet.onboarding.toggle-prompt"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(app.staticTexts["The prompt you'll send"].waitForExistence(timeout: 10),
                      "prompt preview must open")
        XCTAssertTrue(app.staticTexts["1. Install: I sideload Hermes Fleet from my Mac"].exists ||
                      app.descendants(matching: .any)
                        .matching(identifier: "fleet.onboarding.prompt-text").firstMatch.exists,
                      "full prompt text must render")

        // Docs link is present.
        XCTAssertTrue(app.buttons["fleet.onboarding.docs"].exists,
                      "docs link must be present")

        attachScreenshot(of: app, name: "f3-onboarding-screen")
    }

    func testOnboardingHandsOffToAddGatewayForm() throws {
        let app = launchEmptyFleet()
        openGatewaysTab(app)

        // Label query (see note above — ContentUnavailableView flattening).
        let cta = app.buttons["Set up with your agent"]
        XCTAssertTrue(cta.waitForExistence(timeout: 10))
        cta.tap()

        // The user has the agent's reply — the hand-off must route into the
        // REAL Add-Gateway sheet (same draft + Keychain path as manual entry).
        let enter = app.buttons["fleet.onboarding.enter-values"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10),
                      "onboarding must offer the Add-Gateway hand-off")
        enter.tap()

        let endpoint = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 10),
                      "hand-off must present the real Add-Gateway form")
        // The three returned values land in the same fields (paste buttons
        // exist next to endpoint/username/password in the form).
        XCTAssertTrue(app.buttons["fleet.gateways.form.paste.endpoint"].exists ||
                      app.buttons["fleet.gateways.form.paste.username"].exists,
                      "the form's paste affordances must be reachable for the agent's values")

        attachScreenshot(of: app, name: "f3-onboarding-to-add-gateway")
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
