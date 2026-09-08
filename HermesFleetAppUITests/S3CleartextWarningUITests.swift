import XCTest

/// S3 (B2) — cleartext-warning UI behavior in the gateway form.
///
/// The add/edit gateway sheet must warn before saving an `http://` endpoint
/// whose host is NOT a private/loopback address, and must gate Save on the
/// user explicitly confirming the cleartext send. This suite drives the
/// DEBUG build (scripted fleet, deterministic) through the U2 add-gateway
/// form:
///   - public http host  → warning appears, Save disabled until confirmed
///   - private http host (RFC1918) → no warning, Save enabled
///   - loopback http host → no warning, Save enabled
final class S3CleartextWarningUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Public http endpoint → warning + save-gating

    func testPublicHTTPEndpointShowsWarningAndGatesSave() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        // Open the add-gateway form.
        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        nameField.tap()
        nameField.typeText("Public Gateway")
        endpointField.tap()
        endpointField.typeText("http://gateway.example.com:9120")

        // Prominent warning must appear for a public http host.
        let warning = firstMatch(in: app, identifier: "fleet.gateways.form.cleartext-warning")
        XCTAssertTrue(warning.waitForExistence(timeout: 5),
                      "cleartext warning should appear for public http endpoint")

        // Save must be gated until the user confirms. Query the toolbar
        // BUTTON element directly — a disabled SwiftUI toolbar item surfaces
        // as an "Other" container via descendants(.any), and that container
        // reports isEnabled=true even when the button is disabled.
        let save = saveButton(in: app)
        XCTAssertTrue(save.waitForExistence(timeout: 5), "save button should exist")
        XCTAssertFalse(save.isEnabled,
                       "Save must be disabled while cleartext warning is unconfirmed")

        // Explicit confirmation unlocks Save. Tap the switch KNOB (right edge
        // of the Form row) — tapping the row's center can land on the label
        // area and miss the SwiftUI Toggle control.
        let confirm = app.switches["fleet.gateways.form.cleartext-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation toggle should appear")
        confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        // The switch must actually flip to ON (value "1") — proof the user
        // explicitly confirmed the cleartext send.
        XCTAssertTrue(waitUntilValue(confirm, isOn: true, timeout: 5),
                      "confirmation toggle should read ON after tap")
        XCTAssertTrue(waitUntilEnabled(save, timeout: 5),
                      "Save should be enabled after explicit cleartext confirmation")
        attachScreenshot(of: app, name: "s3-public-http-warning-confirmed")
    }

    // MARK: - Private (RFC1918) http endpoint → no warning, Save enabled

    func testPrivateHTTPEndpointShowsNoWarning() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        nameField.tap()
        nameField.typeText("LAN Gateway")
        endpointField.tap()
        endpointField.typeText("http://192.168.50.37:9120")

        // No warning for an RFC1918 private host; Save enabled immediately.
        let warning = firstMatch(in: app, identifier: "fleet.gateways.form.cleartext-warning")
        XCTAssertFalse(warning.waitForExistence(timeout: 2),
                       "no cleartext warning for a private RFC1918 host")

        let save = saveButton(in: app)
        XCTAssertTrue(waitUntilEnabled(save, timeout: 5),
                      "Save should be enabled for a private endpoint without confirmation")
        attachScreenshot(of: app, name: "s3-private-http-no-warning")
    }

    // MARK: - Loopback http endpoint → no warning

    func testLoopbackHTTPEndpointShowsNoWarning() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        nameField.tap()
        nameField.typeText("Local Gateway")
        endpointField.tap()
        endpointField.typeText("http://127.0.0.1:8642")

        let warning = firstMatch(in: app, identifier: "fleet.gateways.form.cleartext-warning")
        XCTAssertFalse(warning.waitForExistence(timeout: 2),
                       "no cleartext warning for a loopback host")

        let save = saveButton(in: app)
        XCTAssertTrue(waitUntilEnabled(save, timeout: 5),
                      "Save should be enabled for a loopback endpoint without confirmation")
    }

    // MARK: - Helpers

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let any = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if any.exists { return any }
        let btn = app.buttons[identifier].firstMatch
        if btn.exists { return btn }
        let cell = app.cells[identifier].firstMatch
        if cell.exists { return cell }
        return any
    }

    /// The Save toolbar button, queried as a BUTTON. A disabled SwiftUI
    /// toolbar item surfaces as an "Other" container under descendants(.any)
    /// whose isEnabled is always true — so enabled-state assertions must
    /// query the button type directly.
    private func saveButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["fleet.gateways.form.save"].firstMatch
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "element \(element) should appear")
        element.tap()
    }

    @discardableResult
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.isEnabled
    }

    /// Poll a switch until its `value` reads "1" (ON) — proves the toggle
    /// actually committed (a missed tap leaves value "0").
    @discardableResult
    private func waitUntilValue(_ element: XCUIElement, isOn: Bool, timeout: TimeInterval) -> Bool {
        let wanted = isOn ? "1" : "0"
        let deadline = Date().addingTimeInterval(timeout)
        while (element.value as? String) != wanted && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return (element.value as? String) == wanted
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
