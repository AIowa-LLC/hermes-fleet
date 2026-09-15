import XCTest

/// F3 — first-run onboarding UI regression suite (deterministic, CI-safe).
///
/// Drives the DEBUG simulator build with `HERMES_FLEET_ZERO_GATEWAYS=1`,
/// which suppresses the scripted seed fleet so the app launches with an
/// EMPTY registry. Under the first-run hydration gate the app presents the
/// setup experience AT THE ROOT — before any tab UI. Proves: onboarding is
/// the first meaningful surface; the copy button confirms visibly; the
/// prompt preview renders the universal (v4) text with no environment
/// assumptions; and the already-have-details hand-off routes into the REAL
/// Add-Gateway form (URL/username/password entry).
final class F3OnboardingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchEmptyFleet() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_ZERO_GATEWAYS"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        return app
    }

    func testFreshInstallLandsOnOnboardingAsRootSurface() throws {
        let app = launchEmptyFleet()

        // The first-run setup experience is the ROOT surface — no tab bar
        // before the first gateway is registered.
        let copy = app.buttons["fleet.onboarding.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 15),
                      "a fresh zero-gateway install must land on the setup experience")
        XCTAssertFalse(app.tabBars.firstMatch.exists,
                      "no tab bar before the first gateway is registered")

        // The universal copy is present: connect your first Hermes server.
        XCTAssertTrue(app.staticTexts["Connect your first Hermes server"].exists
                      || app.descendants(matching: .any)
                          .matching(identifier: "fleet.onboarding.headline").firstMatch.exists,
                      "the setup headline renders")

        attachScreenshot(of: app, name: "f3-onboarding-root")
    }

    func testCopyFlowConfirmsVisiblyAndPreviewIsUniversal() throws {
        let app = launchEmptyFleet()

        let copy = app.buttons["fleet.onboarding.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 15))
        copy.tap()

        // One tap copies — visible confirmation appears.
        let confirmation = app.staticTexts["Copied — paste it in chat"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10),
                      "copy must show a visible confirmation")

        // The prompt preview renders the full versioned text (review path).
        let toggle = app.buttons["fleet.onboarding.toggle-prompt"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(app.staticTexts["The prompt you'll send"].waitForExistence(timeout: 10),
                      "prompt preview must open")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.onboarding.prompt-text").firstMatch.exists,
            "full prompt text must render"
        )

        // Neutrality on-device: the rendered prompt carries no environment
        // assumptions (the stale v3 legs named Wi-Fi sideloading/TestFlight).
        let promptText = app.descendants(matching: .any)
            .matching(identifier: "fleet.onboarding.prompt-text").firstMatch.label
        for banned in ["sideload", "Wi-Fi", "TestFlight", "Mac", "tailnet", "Tailscale", "dogfood"] {
            XCTAssertFalse(promptText.contains(banned),
                           "rendered prompt must not contain environment assumption \"\(banned)\"")
        }

        // Docs link is present.
        XCTAssertTrue(app.buttons["fleet.onboarding.docs"].exists,
                      "docs link must be present")

        attachScreenshot(of: app, name: "f3-onboarding-copy")
    }

    func testOnboardingHandsOffToAddGatewayForm() throws {
        let app = launchEmptyFleet()

        let enter = app.buttons["fleet.onboarding.enter-values"]
        XCTAssertTrue(enter.waitForExistence(timeout: 15),
                      "onboarding must offer the already-have-details hand-off")
        enter.tap()

        // The hand-off must present the REAL Add-Gateway sheet (same draft +
        // Keychain path as manual entry).
        let endpoint = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 10),
                      "hand-off must present the real Add-Gateway form")
        XCTAssertTrue(app.buttons["fleet.gateways.form.paste.endpoint"].exists ||
                      app.buttons["fleet.gateways.form.paste.username"].exists,
                      "the form's paste affordances must be reachable for the returned values")

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
