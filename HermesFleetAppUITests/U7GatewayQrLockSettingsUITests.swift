import XCTest

/// U7 (Gold Fleet) — Add-Gateway form + QR scanner + FaceID lock + settings
/// re-skin regression suite.
///
/// Drives the DEBUG build (deterministic scripted fleet) and proves the
/// plan card's U7 scope renders and still functions:
///   1. the Add-Gateway form keeps every field/paste/scan identifier under
///      the token skin (P0-2/S3/F2 surfaces are unchanged functionally);
///   2. the QR scanner fallback chrome (simulator: no camera) renders with
///      its identifiers intact;
///   3. the FaceID lock screen renders the gold wordmark + unlock actions;
///   4. Settings renders the gold brand header and the App Lock toggle.
///
/// Visual fidelity (gold/magenta tokens actually rendering) is verified by
/// the apple-design review against the attached screenshots + hero mock.
final class U7GatewayQrLockSettingsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Add-Gateway form re-skin keeps every interaction surface

    func testAddGatewayFormRendersTokenSkinWithAllFields() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))

        // Every P0-2/F2 interaction surface must survive the re-skin.
        let nameField = app.textFields["fleet.gateways.form.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should render")
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.gateways.form.endpoint").exists,
            "endpoint field should render"
        )
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.gateways.form.paste.endpoint").exists,
            "endpoint paste button should render (P0-2)"
        )
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.gateways.form.scan").exists,
            "Scan Pairing Code entry should render (F2)"
        )
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.gateways.form.strategy").exists,
            "strategy picker should render"
        )
        XCTAssertTrue(
            app.buttons["fleet.gateways.form.cancel"].exists,
            "Cancel should render"
        )
        XCTAssertTrue(
            app.buttons["fleet.gateways.form.save"].exists,
            "Save should render"
        )
        attachScreenshot(of: app, name: "u7-add-gateway-form")

        // Cancel cleanly (draft wipe path, unchanged).
        app.buttons["fleet.gateways.form.cancel"].tap()
    }

    // MARK: - QR scanner fallback chrome (simulator: camera unsupported)

    func testScannerFallbackChromeRendersAndCancels() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        tap(firstMatch(in: app, identifier: "fleet.gateways.form.scan"))

        // Simulator → VisionKit unsupported → fallback body with the
        // unavailable explainer (U7: gold QR glyph + secondary text).
        let unavailable = firstMatch(in: app, identifier: "fleet.gateways.scan.unavailable")
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10),
                      "scanner fallback body should render on the simulator")
        XCTAssertTrue(
            app.buttons["fleet.gateways.scan.cancel"].exists,
            "scanner Cancel should render"
        )
        attachScreenshot(of: app, name: "u7-scanner-fallback-chrome")

        // Cancel returns to the (still intact) form.
        app.buttons["fleet.gateways.scan.cancel"].tap()
        XCTAssertTrue(app.textFields["fleet.gateways.form.name"].waitForExistence(timeout: 10),
                      "cancel should return to the form")
        app.buttons["fleet.gateways.form.cancel"].tap()
    }

    // MARK: - Lock screen renders the white-wing identity mark + unlock
    //
    // D-1 fix (t_9ce36690 / D5 §3): the lock screen is HIG-native — system
    // background, white-wing identity mark ("lock-identity-mark"), app name
    // in system type ("lock-app-name"), unlock control in system styling.
    // POSITIVE assertions only (apple-qa guardrail: never green-by-deletion).

    func testLockScreenRendersIdentityMarkAndUnlock() throws {
        let app = XCUIApplication()
        // Lock ON + scripted biometric FAILURE with passcode fallback: the
        // lock screen HOLDS (auto-auth at launch fails → passcode fallback
        // renders), so every lock element is queryable deterministically.
        // (With `success` the controller auto-unlocks within milliseconds of
        // launch — the old test never actually asserted the lock screen.)
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "enabled"
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "fail"
        app.launchEnvironment["HERMES_FLEET_LOCK_RESET"] = "1"
        app.launch()

        // The white-wing identity mark (D-1) must be present.
        let mark = app.descendants(matching: .any)
            .matching(identifier: "lock-identity-mark").firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 15),
                      "lock screen should render the white-wing identity mark")

        // The app name renders in system type directly under the mark.
        let appName = app.descendants(matching: .any)
            .matching(identifier: "lock-app-name").firstMatch
        XCTAssertTrue(appName.waitForExistence(timeout: 10),
                      "lock screen should render the app name under the mark")
        XCTAssertTrue(appName.label.contains("Hermes Fleet"),
                      "app-name label should read 'Hermes Fleet' (got: \(appName.label))")

        // The unlock control is present in system styling. Under scripted
        // biometric failure the controller is in passcode fallback, so the
        // PASSCODE unlock control renders (the H1 acceptance surface).
        let unlock = app.buttons["fleet.app-lock.passcode.unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10),
                      "lock screen should render the unlock control")

        attachScreenshot(of: app, name: "v7-lock-screen-identity-mark")

        // Scripted passcode success releases the gate (H1 path unchanged):
        // tap the passcode unlock control — the scripted provider succeeds.
        unlock.tap()
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 15),
                      "scripted passcode success should unlock to the roster")
    }

    // MARK: - Settings renders the gold brand header + App Lock toggle

    func testSettingsRendersBrandHeaderAndToggle() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launch()

        UITabNavigation.openSettings(app)

        // U7: gold brand header on the settings canvas.
        let brand = firstMatch(in: app, identifier: "fleet.settings.brand")
        XCTAssertTrue(brand.waitForExistence(timeout: 10),
                      "settings should render the gold brand header")
        XCTAssertTrue(brand.label.contains("Hermes Fleet"),
                      "brand header should carry the wordmark (label: \(brand.label))")

        // The H1 acceptance surface is untouched.
        let toggle = app.switches["fleet.settings.app-lock.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "App Lock toggle should render")
        attachScreenshot(of: app, name: "u7-settings-brand")
    }

    // MARK: - Helpers

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let any = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if any.exists { return any }
        let btn = app.buttons[identifier].firstMatch
        if btn.exists { return btn }
        return any
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "element \(element) should appear")
        element.tap()
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
