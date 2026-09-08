import XCTest

/// RT4 P2-6 UI regression: a gateway-form save failure must NOT dismiss and
/// discard the entered fields. The sheet stays open, the non-secret fields are
/// preserved for retry, and a non-secret inline error is surfaced.
///
/// Drives the DEBUG build with `HERMES_FLEET_SAVE_FAIL=1`, which makes the
/// scripted registry's save path (add) throw. RED (old): the form dismissed
/// unconditionally after `onSave` and the parent caught the error in a later
/// alert — the sheet vanished and the fields were gone. GREEN (fix): the form
/// sees the thrown error, keeps the sheet open, preserves the fields, and
/// renders `fleet.gateways.form.error`.
final class RT4FormSaveFailureUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSaveFailureKeepsSheetOpenAndPreservesFields() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_SAVE_FAIL"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        // With save-fail enabled, the scripted seed (registry.addGateway) also
        // throws, so the fleet is empty — the Add Gateway entry point must not
        // depend on a seeded gateway. The toolbar + empty state both expose it.
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.gateways.add").waitForExistence(timeout: 10),
                      "Add Gateway entry should appear (empty state or toolbar)")

        // Open the Add Gateway form and enter a name + endpoint.
        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        nameField.tap()
        nameField.typeText("Retry Gateway")
        endpointField.tap()
        endpointField.typeText("http://127.0.0.1:9600")

        let save = app.buttons["fleet.gateways.form.save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "valid form should enable Save")
        save.tap()

        // P2-6: the sheet must STAY open and the non-secret name field must
        // still contain the entered value (preserved for retry).
        XCTAssertTrue(nameField.waitForExistence(timeout: 10),
                      "P2-6: save failure must NOT dismiss the form")
        XCTAssertEqual(nameField.value as? String, "Retry Gateway",
                       "P2-6: non-secret fields must be preserved for retry")

        // The non-secret inline error is surfaced.
        let error = firstMatch(in: app, identifier: "fleet.gateways.form.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5),
                      "P2-6: a non-secret save-failure message must render inline")
        attachScreenshot(of: app, name: "rt4-p2-6-save-failure-keeps-sheet")
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

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
