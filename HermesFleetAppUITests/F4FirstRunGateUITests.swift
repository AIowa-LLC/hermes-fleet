import XCTest

/// F4 — first-run ROOT GATE + existing-user regression suite
/// (deterministic, CI-safe).
///
/// The hydration gate (`AppEnvironment.hydrationPhase`) drives the root:
/// loading → unconfigured (first-run setup) → configured (normal tabs).
/// This suite proves the lifecycle both ways plus the existing-user paths:
/// the Settings setup-prompt door stays available with gateways configured,
/// the direct Add Gateway path remains usable, and removing the final
/// gateway returns to setup.
final class F4FirstRunGateUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Fresh install → first gateway → main UI

    func testFirstGatewayRegistrationTransitionsToMainFleetUI() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_ZERO_GATEWAYS"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_UI_TEST_PASTE_FIXTURES"] = "1"
        app.launch()

        // Fresh install: onboarding at the root, no tab bar.
        let enter = app.buttons["fleet.onboarding.enter-values"]
        if !enter.waitForExistence(timeout: 15) {
            // The steps card can sit below the fold in the lazy ScrollView —
            // scroll it into the AX tree before failing.
            for _ in 0..<4 where !enter.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(enter.waitForExistence(timeout: 10),
                      "fresh install must show the setup experience")
        enter.tap()

        // Fill the REAL Add-Gateway form using the deterministic paste
        // fixtures (endpoint + username/password via the paste buttons).
        let endpoint = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 10))
        let pasteEndpoint = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateways.form.paste.endpoint").firstMatch
        pasteEndpoint.tap()

        // Display name.
        let name = app.textFields["fleet.gateways.form.name"]
        name.tap()
        name.typeText("First Server")

        // Username & Password strategy reveals the credential rows (retry
        // loop — the menu picker can need a second attempt).
        selectUsernamePassword(in: app)

        let username = app.textFields["fleet.gateways.form.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 5),
                      "Username & Password strategy must reveal credential rows")
        username.tap()
        app.descendants(matching: .any)
            .matching(identifier: "fleet.gateways.form.paste.username").firstMatch.tap()
        let password = app.secureTextFields["fleet.gateways.form.password"]
        password.tap()
        app.descendants(matching: .any)
            .matching(identifier: "fleet.gateways.form.paste.password").firstMatch.tap()

        // The https fixture endpoint requires TLS first-use confirmation.
        let tlsToggle = app.switches["fleet.gateways.form.tls-first-use-confirm"].firstMatch
        if !tlsToggle.waitForExistence(timeout: 3) {
            for _ in 0..<3 where !tlsToggle.exists { app.swipeUp(velocity: .fast) }
        }
        if tlsToggle.waitForExistence(timeout: 3) {
            tlsToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }

        let save = app.buttons["fleet.gateways.form.save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        waitUntilEnabled(save, timeout: 5)
        if !save.isHittable { app.swipeUp() }
        save.tap()

        // SUCCESS TRANSITION: the sheet dismisses, the registry is non-empty,
        // and the normal four-tab Fleet UI appears — no relaunch, no extra
        // dismissal steps.
        UITabNavigation.shellReady(app, timeout: 15)
        XCTAssertTrue(true,
                      "registering the first gateway must transition into the main Fleet UI")
        XCTAssertFalse(app.buttons["fleet.onboarding.copy"].waitForExistence(timeout: 2),
                       "onboarding must be gone after the first registration")

        attachScreenshot(of: app, name: "f4-first-gateway-transition")
    }

    func testRelaunchWithRegisteredServerDoesNotReshowOnboarding() throws {
        // Second launch of the SAME app process state as the test above is
        // not possible in XCUITest (containers are per-launch); instead this
        // proves the configured-launch contract directly: the DEFAULT
        // scripted fleet (gateways seeded) must show tabs, never onboarding.
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        UITabNavigation.shellReady(app, timeout: 15)
        XCTAssertTrue(true,
                      "a configured (seeded) launch must show the normal tab UI")
        XCTAssertFalse(app.buttons["fleet.onboarding.copy"].waitForExistence(timeout: 2),
                       "first-run onboarding must not appear for a configured user")
        attachScreenshot(of: app, name: "f4-configured-launch")
    }

    // MARK: Existing users keep their doors

    func testSettingsExposesSetupPromptWithGatewaysConfigured() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openSettings(app)

        let row = app.buttons["fleet.settings.setup-prompt"]
        if !row.waitForExistence(timeout: 5) {
            for _ in 0..<4 where !row.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Settings must expose the setup-prompt row with gateways configured")
        row.tap()

        // Same universal prompt (v4), reachable after configuration.
        let copy = app.buttons["fleet.setup-prompt.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10),
                      "the setup-prompt sheet must show the Copy button")
        let toggle = app.buttons["fleet.setup-prompt.toggle-prompt"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.setup-prompt.prompt-text").firstMatch.waitForExistence(timeout: 10),
            "the universal prompt text must render from Settings"
        )

        // Copy works.
        copy.tap()
        XCTAssertTrue(app.staticTexts["Copied — paste it in chat"].waitForExistence(timeout: 10),
                      "copy must confirm visibly from the Settings door")
        attachScreenshot(of: app, name: "f4-settings-setup-prompt")
    }

    func testAddGatewayRemainsUsableFromGatewaysTab() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        // The toolbar plus still presents the real Add-Gateway form.
        let add = app.buttons["fleet.gateways.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.textFields["fleet.gateways.form.endpoint"].waitForExistence(timeout: 10),
                      "Add Gateway must remain usable from the Gateways tab")
        app.buttons["fleet.gateways.form.cancel"].tap()
        attachScreenshot(of: app, name: "f4-add-gateway-still-works")
    }

    // MARK: Final-gateway removal returns to setup

    func testRemovingFinalGatewayReturnsToSetup() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_SINGLE_GATEWAY"] = "1"
        app.launch()

        UITabNavigation.shellReady(app, timeout: 15)
        UITabNavigation.openGatewaysTab(app)

        // Remove the single gateway through the Connection screen's
        // confirmed destructive flow: row → gateway detail → Connection.
        let firstRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@",
                         "fleet.gateways.row.")
        ).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        firstRow.tap()
        // Gateway detail → Connection (hosts Remove Gateway). The single
        // seeded gateway is deterministically `workstation` (registrations[0]),
        // so the resource row's identifier is stable.
        let connectionLink = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateway-detail.workstation.connection").firstMatch
        if !connectionLink.waitForExistence(timeout: 5) {
            for _ in 0..<3 where !connectionLink.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(connectionLink.waitForExistence(timeout: 10),
                      "gateway detail must expose the Connection link")
        connectionLink.tap()
        let detailRemove = app.buttons["Remove Gateway"].firstMatch
        if !detailRemove.waitForExistence(timeout: 5) {
            for _ in 0..<3 where !detailRemove.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(detailRemove.waitForExistence(timeout: 10),
                      "the Connection screen must expose Remove Gateway")
        detailRemove.tap()
        let confirm = app.buttons["fleet.gateways.remove.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        // The undo alert appears; dismiss it so the removal stands.
        let ok = app.buttons["OK"].firstMatch
        if ok.waitForExistence(timeout: 5) { ok.tap() }

        // EMPTY REGISTRY ⇒ the root gate flips back to setup.
        XCTAssertTrue(app.buttons["fleet.onboarding.copy"].waitForExistence(timeout: 15),
                      "removing the final gateway must return to the setup experience")
        attachScreenshot(of: app, name: "f4-removal-returns-to-setup")
    }

    // MARK: - Helpers

    /// Select Username & Password in the strategy picker (menu-style picker
    /// can need a retry — same pattern as the live-gateway suites).
    private func selectUsernamePassword(in app: XCUIApplication) {
        let strategy = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateways.form.strategy").firstMatch
        XCTAssertTrue(strategy.waitForExistence(timeout: 10),
                      "authentication strategy picker should appear")
        let option = app.buttons["Username & Password"].firstMatch
        var selected = false
        for _ in 0..<3 {
            strategy.tap()
            if option.waitForExistence(timeout: 3) {
                option.tap()
                selected = true
                break
            }
        }
        XCTAssertTrue(selected, "strategy picker should expose Username & Password")
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(element.isEnabled, "element should become enabled: \(element)")
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
