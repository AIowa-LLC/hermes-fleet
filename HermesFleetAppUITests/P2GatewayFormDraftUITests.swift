import XCTest
import UIKit

/// P0-2 — Add-Gateway form survives the H1 FaceID lock + paste-friendly
/// credential entry (Tony dogfood defect, TestFlight build 2).
///
/// The defect: to add a gateway the user switches to another app to copy
/// username/password (42+ char generated strings); on return the H1 biometric
/// app lock engages and `FleetTabView` tears the whole navigation stack
/// (sheet + form `@State`) down, discarding every typed field.
///
/// FIX under test: the form binds to a root-owned `GatewayFormDraftStore`, so
/// the draft survives the lock / scenePhase teardown and `GatewaysView`
/// re-presents the sheet on unlock. Plus explicit paste buttons next to the
/// URL / username / password fields.
///
/// Deterministic (DEBUG scripted fleet + scripted biometric auth):
///   - `HERMES_FLEET_APP_LOCK=enabled` + `HERMES_FLEET_LOCK_AUTH=success`:
///     cold launch is gated, scripted Face ID success unlocks to the roster.
///     Backgrounding (`XCUIDevice press(.home)`) re-locks; `activate()` +
///     scripted success unlocks again — reproducing the exact user flow.
final class P2GatewayFormDraftUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Tap the real application paste button once. In canonical UI tests the
    /// app is launched with an explicit DEBUG fixture provider, so this path
    /// does not depend on SpringBoard's OS-owned paste permission prompt.
    private func paste(into button: XCUIElement, app: XCUIApplication) {
        button.tap()
    }

    // MARK: - Draft survives background + FaceID relock (dogfood acceptance)

    func testAddFormSurvivesBackgroundAndFaceIDRelock() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "enabled"
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_LOCK_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        // Scripted Face ID success unlocks to the fleet (DEBUG fleet's first
        // gateway is Workstation).
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 15),
                      "roster should render after scripted biometric unlock")

        // Open the Add-Gateway form and fill it in (the user's real workflow:
        // long generated credentials copied from elsewhere).
        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        nameField.tap()
        nameField.typeText("Tailnet Gateway")
        endpointField.tap()
        endpointField.typeText("http://100.100.200.61:8642")

        // Username & Password strategy + credentials.
        tap(firstMatch(in: app, identifier: "fleet.gateways.form.strategy"))
        let userPass = app.buttons["Username & Password"]
        if userPass.waitForExistence(timeout: 5) { userPass.tap() }
        let usernameField = app.textFields["fleet.gateways.form.username"]
        let passwordField = app.secureTextFields["fleet.gateways.form.password"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 5), "username field should appear")
        usernameField.tap()
        usernameField.typeText("fleet-operator")
        passwordField.tap()
        passwordField.typeText("7f3a9c21e8b04d5f6a2c9e7b1d4f8a3c5e6b2d9f0a1c3e5b7")
        attachScreenshot(of: app, name: "p0-2-before-background")

        // THE defect: background the app (user switches to copy / verify),
        // which re-locks it; then return via Face ID.
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.activate()

        // P0-2: the sheet must re-present with EVERY typed field intact.
        XCTAssertTrue(nameField.waitForExistence(timeout: 15),
                      "P0-2: Add-Gateway sheet must re-present after FaceID relock")
        XCTAssertEqual(nameField.value as? String, "Tailnet Gateway",
                       "P0-2: display name must survive the lock")
        XCTAssertEqual(endpointField.value as? String, "http://100.100.200.61:8642",
                       "P0-2: endpoint must survive the lock")
        XCTAssertEqual(usernameField.value as? String, "fleet-operator",
                       "P0-2: username must survive the lock")
        // SecureFields mask their value in XCUITest (bullets), so we cannot
        // read the plaintext back — but a reset form would be EMPTY, so a
        // non-empty masked value proves the password survived the relock.
        XCTAssertFalse((passwordField.value as? String)?.isEmpty ?? true,
                       "P0-2: password must survive the lock (non-empty after relock)")
        attachScreenshot(of: app, name: "p0-2-after-faceid-relock")

        // Cancel wipes the draft cleanly (no resurrection on a later appear).
        let cancel = app.buttons["fleet.gateways.form.cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Cancel should exist")
        cancel.tap()
        XCTAssertTrue(waitForGone(nameField, timeout: 5),
                      "Cancel must dismiss the sheet")
        XCTAssertFalse(nameField.exists, "draft must not resurrect after Cancel")
    }

    // MARK: - Paste buttons fill URL / username / password fields

    func testPasteButtonsFillCredentialFields() throws {
        let app = XCUIApplication()
        // Lock disabled so the test focuses purely on paste affordances.
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launchEnvironment["HERMES_FLEET_UI_TEST_PASTE_FIXTURES"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 15),
                      "roster should render (lock disabled)")

        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")

        // Endpoint paste button.
        let pasteEndpoint = firstMatch(in: app, identifier: "fleet.gateways.form.paste.endpoint")
        XCTAssertTrue(pasteEndpoint.waitForExistence(timeout: 5), "endpoint paste button should exist")
        paste(into: pasteEndpoint, app: app)
        XCTAssertEqual(endpointField.value as? String, "http://192.168.50.58:8642",
                       "endpoint paste button must fill the URL field")

        // Username & Password strategy → paste buttons for both.
        tap(firstMatch(in: app, identifier: "fleet.gateways.form.strategy"))
        let userPass = app.buttons["Username & Password"]
        if userPass.waitForExistence(timeout: 5) { userPass.tap() }
        let usernameField = app.textFields["fleet.gateways.form.username"]
        let passwordField = app.secureTextFields["fleet.gateways.form.password"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 5), "username field should appear")

        let pasteUsername = firstMatch(in: app, identifier: "fleet.gateways.form.paste.username")
        XCTAssertTrue(pasteUsername.waitForExistence(timeout: 5), "username paste button should exist")
        paste(into: pasteUsername, app: app)
        XCTAssertEqual(usernameField.value as? String, "fleet-operator",
                       "username paste button must fill the username field")

        let pastePassword = firstMatch(in: app, identifier: "fleet.gateways.form.paste.password")
        XCTAssertTrue(pastePassword.waitForExistence(timeout: 5), "password paste button should exist")
        paste(into: pastePassword, app: app)
        // SecureFields mask their value in XCUITest (bullets) — a non-empty
        // masked value proves the paste landed (a reset field would be empty).
        XCTAssertFalse((passwordField.value as? String)?.isEmpty ?? true,
                       "password paste button must fill the password field")
        attachScreenshot(of: app, name: "p0-2-paste-buttons-filled")
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

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "element \(element) should appear")
        element.tap()
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return !element.exists
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
