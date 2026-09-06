import XCTest

/// RT2 UI regression tests (t_2c13bdb3):
/// - P1-8: gateway removal requires an explicit, named confirmation that
///   explains credential deletion; removal succeeds after confirm; a bounded
///   undo restores the gateway.
/// - P1-6: the add-gateway form treats the endpoint as an ORIGIN — a pasted
///   `user:pass@host` endpoint is rejected (Save stays disabled), so
///   credential material never leaves the field.
///
/// Drives the DEBUG build (scripted fleet — workstation, render-box, arch),
/// so the flows are deterministic.
final class RT2RemovalAndEndpointSanitizationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - P1-8 removal confirmation + undo

    func testRemovalRequiresConfirmationAndCanUndo() throws {
        let app = XCUIApplication()
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        // Seed fleet present.
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10),
                      "Gateways screen should list Workstation")

        // Swipe the row left to reveal the destructive Remove action.
        let row = firstMatch(in: app, identifier: "fleet.gateways.row.workstation")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()

        let remove = firstMatch(in: app, identifier: "fleet.gateways.row.workstation.remove")
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "Remove action should appear after swipe")
        remove.tap()

        // A named confirmation dialog explaining credential deletion must
        // appear — the gateway must NOT be removed by the swipe alone.
        let confirmTitle = app.staticTexts["Remove Gateway?"]
        XCTAssertTrue(confirmTitle.waitForExistence(timeout: 5),
                      "P1-8: removal must require a named confirmation dialog")
        XCTAssertTrue(app.staticTexts["Keychain"].exists ||
                      app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'credential'")).firstMatch.exists,
                      "confirmation must explain credential deletion")

        // Cancel first: the gateway stays.
        let cancel = firstMatch(in: app, identifier: "fleet.gateways.remove.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Cancel button should appear")
        cancel.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Cancel keeps the gateway")

        // Swipe again and confirm removal.
        row.swipeLeft()
        let removeAgain = firstMatch(in: app, identifier: "fleet.gateways.row.workstation.remove")
        XCTAssertTrue(removeAgain.waitForExistence(timeout: 5))
        removeAgain.tap()
        let confirm = firstMatch(in: app, identifier: "fleet.gateways.remove.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirm button should appear")
        confirm.tap()

        // Gateway gone from the list.
        XCTAssertTrue(waitForGone(row, timeout: 5), "confirmed removal should delete the gateway")

        // Bounded undo restores the gateway.
        let undo = firstMatch(in: app, identifier: "fleet.gateways.remove.undo")
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "undo affordance should appear after removal")
        undo.tap()
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10),
                      "undo should restore the gateway")
        attachScreenshot(of: app, name: "rt2-p1-8-removal-confirm-undo")
    }

    // MARK: - P1-6 form rejects user-info endpoint

    func testFormRejectsUserInfoEndpoint() throws {
        let app = XCUIApplication()
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        nameField.tap()
        nameField.typeText("Tainted Gateway")
        endpointField.tap()

        // user:pass@host is not a valid ORIGIN — Save must stay disabled so
        // credential material never leaves the text field.
        endpointField.typeText("http://alice:supersecret@192.168.50.58:9120")
        let save = app.buttons["fleet.gateways.form.save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled,
                       "P1-6: Save must be disabled when the endpoint carries user-info")
        attachScreenshot(of: app, name: "rt2-p1-6-userinfo-save-disabled")
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

    @discardableResult
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
