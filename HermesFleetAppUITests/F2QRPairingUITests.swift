import XCTest

/// F2 — QR-code gateway pairing: one scan fills the Add-Gateway form.
///
/// Deterministic on the simulator (and CI): VisionKit's live scanner reports
/// unsupported on simulators, so the scanner sheet shows its fallback body,
/// which — in DEBUG, opted in via launch environment — exposes the SAME
/// decode + apply entry point the camera uses ("Simulate Scanned Code").
/// The test therefore drives production logic end to end:
///
///   Add Gateway → Scan Pairing Code → (simulated) scan → form filled → Save
///   → gateway registered.
final class F2QRPairingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// C1 hardening: the scanner sheet must render its camera-denied
    /// recovery state — real copy + Open Settings — and never a dead
    /// spinner or a camera surface. Driven via the DEBUG-only
    /// `HERMES_FLEET_PAIRING_CAMERA_DENIED` seam (the simulator camera is
    /// unsupported, so the real denied path is unreachable there).
    func testScannerDeniedStateShowsRecoveryCopyAndSettingsLink() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_PAIRING_CAMERA_DENIED"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        let add = app.buttons["fleet.gateways.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()

        let nameField = app.textFields["fleet.gateways.form.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))

        let scan = app.buttons["fleet.gateways.form.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()

        let denied = app.staticTexts["fleet.gateways.scan.denied"]
        XCTAssertTrue(denied.waitForExistence(timeout: 10),
                      "denied state must surface real copy, not a dead spinner")
        let settings = app.buttons["fleet.gateways.scan.denied.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5),
                      "denied state must offer the Settings deep link")
        // The manual path stays reachable: cancel back to the form.
        let cancel = app.buttons["fleet.gateways.scan.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(nameField.waitForExistence(timeout: 10),
                      "cancel must return to the manual-entry form")
    }

    /// C1 IA re-order: the scanner must be demoted BELOW the manual entry
    /// fields with a clear "requires pairing support" label — manual entry
    /// is the tier-1 primary path.
    func testScannerEntryIsDemotedBelowManualEntryWithSupportLabel() throws {
        let app = XCUIApplication()
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        let add = app.buttons["fleet.gateways.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()

        let nameField = app.textFields["fleet.gateways.form.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        let scan = app.buttons["fleet.gateways.form.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        // The scan button must come AFTER the manual endpoint field in the
        // accessible element order — manual entry is tier 1.
        XCTAssertTrue(nameField.frame.maxY < scan.frame.minY,
                      "scanner entry must render below the manual entry fields")
        let supportLabel = app.staticTexts["fleet.gateways.form.scan.support-note"]
        XCTAssertTrue(supportLabel.waitForExistence(timeout: 5),
                      "scanner section must carry the pairing-support caveat")
        attachScreenshotF2(of: app, name: "c1-scanner-demoted")
    }

    /// The raw QR text the gateway side would render (F2 v1 payload).
    private var simulatedScan: String {
        "{\"password\":\"7f3a9c21e8b04d5f6a2c9e7b1d4f8a3c\",\"url\":\"http://192.168.50.37:8642\",\"username\":\"fleet-operator\",\"v\":1}"
    }

    func testScanFillsFormAndSaveRegistersGateway() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_PAIRING_SIMULATED_SCAN"] = simulatedScan
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        // Open the Add-Gateway form (DEBUG scripted fleet renders the roster).
        let add = app.buttons["fleet.gateways.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "Add Gateway toolbar button should appear")
        add.tap()

        let nameField = app.textFields["fleet.gateways.form.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "Add-Gateway form should appear")

        // Open the pairing scanner.
        let scan = app.buttons["fleet.gateways.form.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5), "Scan Pairing Code button should be in the form")
        scan.tap()

        // On the simulator the live scanner is unavailable → fallback body
        // with the DEBUG simulated-scan hook (same decode+apply path).
        let simulate = app.buttons["fleet.gateways.scan.simulate"]
        XCTAssertTrue(simulate.waitForExistence(timeout: 10),
                      "simulator fallback should expose the simulated scan (DEBUG + launch env)")
        simulate.tap()

        // Back on the form: every field filled from ONE scan.
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "scanner should dismiss back to the form")
        XCTAssertEqual(nameField.value as? String, "192.168.50.37",
                       "display name derives from the endpoint host")
        let endpoint = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertEqual(endpoint.value as? String, "http://192.168.50.37:8642")
        let username = app.textFields["fleet.gateways.form.username"]
        XCTAssertEqual(username.value as? String, "fleet-operator")
        // Password is a secure field — assert presence, never the value.
        XCTAssertTrue(app.secureTextFields["fleet.gateways.form.password"].exists,
                      "password field filled (value never asserted)")

        // Save: the gateway lands in the registry.
        let save = app.buttons["fleet.gateways.form.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "scanned draft must satisfy form validity")
        save.tap()

        XCTAssertTrue(app.staticTexts["192.168.50.37"].waitForExistence(timeout: 15),
                      "saved gateway row should appear in the list")
        attachScreenshotF2(of: app, name: "f2-paired-gateway-row")
    }

    func testScanRejectsNonPairingCodeWithoutClobberingForm() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_PAIRING_SIMULATED_SCAN"] = "{\"hello\":\"world\"}"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        let add = app.buttons["fleet.gateways.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()

        let nameField = app.textFields["fleet.gateways.form.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText("Typed Name")

        let scan = app.buttons["fleet.gateways.form.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()

        let simulate = app.buttons["fleet.gateways.scan.simulate"]
        XCTAssertTrue(simulate.waitForExistence(timeout: 10))
        simulate.tap()

        // The scanner stays up with a non-secret error; typed state intact.
        XCTAssertTrue(app.staticTexts["fleet.gateways.scan.error"].waitForExistence(timeout: 5)
                      || app.otherElements["fleet.gateways.scan.error"].waitForExistence(timeout: 5)
                      || app.images["fleet.gateways.scan.error"].waitForExistence(timeout: 5),
                      "a rejected scan should surface a non-secret error")
        let cancel = app.buttons["fleet.gateways.scan.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()

        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        XCTAssertEqual(nameField.value as? String, "Typed Name",
                       "a rejected scan must never clobber typed fields")
    }
}

/// Bounded screenshot evidence helper (F2-local; mirrors the P0-2 pattern).
extension XCTestCase {
    func attachScreenshotF2(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
