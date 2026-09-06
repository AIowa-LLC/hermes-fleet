import XCTest

/// P3 fix (t_eb5455f2): prove the app reaches **Connected** against the REAL
/// live LAN gateway using the **Username & Password** strategy.
///
/// Drives the RELEASE app (production graph: real Keychain + live transport)
/// on the simulator against the real LAN gateway at 192.168.50.37:9120 (the
/// same code path P3 used). Adds the gateway via the U2 UI with username +
/// password, then asserts the in-app live probe classifies it **Connected**
/// (not Unreachable/offline) — the exact acceptance the installed app
/// (71023f9) failed.
///
/// Credential safety: the real username/password are read at runtime from
/// /tmp/hermes_lan_surface/.cred (0600, written by the operator) and are
/// NEVER printed, logged, asserted, or committed.
final class P3FixLANGatewayUITests: XCTestCase {

    private let endpoint = "http://192.168.50.37:9120"
    private let displayName = "Mac LAN"
    private let gatewayID = "192.168.50.37:9120"

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The iOS Local Network permission is a SYSTEM alert hosted by a
        // separate process (SpringBoard / SafariViewService) — `app.alerts`
        // cannot see it. Register ONE interruption monitor that taps Allow on
        // any system alert; it fires on the next interaction whenever the
        // prompt appears.
        addUIInterruptionMonitor(withDescription: "Local Network permission") { alert in
            let allow = alert.buttons["Allow"]
            if allow.exists {
                allow.tap()
                return true
            }
            return false
        }
    }

    /// Trigger the interruption monitor so any pending system alert is
    /// handled (tap Allow). Runs up to `seconds`; returns true when the
    /// monitor consumed an alert.
    @discardableResult
    private func handleLocalNetworkPrompt(within seconds: TimeInterval = 8) -> Bool {
        let app = XCUIApplication()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            app.tap()
            sleep(1)
        }
        return true
    }

    /// Handles the alert appearing specifically right after Test Connection
    /// is tapped (the FIRST LAN access moment).
    private func handleLocalNetworkPromptAfterTestConnection() {
        _ = handleLocalNetworkPrompt(within: 6)
    }

    func testLANGatewayUsernamePasswordReachesConnected() throws {
        let app = XCUIApplication()
        // H1 (R4): the app lock defaults ON in Release; this live-gateway suite
        // cold-launches straight into the registry, so opt out of the gate.
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launch()

        // Release starts at the Gateways screen (empty registry).
        UITabNavigation.openGatewaysTab(app)
        // iOS 14+ local-network permission: it can fire at first LAN access
        // (the permission prompt is a system alert).
        handleLocalNetworkPrompt()
        attachScreenshot(of: app, name: "p3fix-step1-open-gateways")

        // Add the REAL LAN gateway via the U2 add-gateway sheet.
        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        nameField.tap()
        nameField.typeText(displayName)
        endpointField.tap()
        endpointField.typeText(endpoint)
        attachScreenshot(of: app, name: "p3fix-step2-add-form-filled")

        // Username & Password strategy.
        tap(firstMatch(in: app, identifier: "fleet.gateways.form.strategy"))
        let userPass = app.buttons["Username & Password"]
        if userPass.waitForExistence(timeout: 5) { userPass.tap() }

        // Enter the real username + password from the operator's .cred file.
        let (username, password) = readCreds()
        let usernameField = app.textFields["fleet.gateways.form.username"]
        let passwordField = app.secureTextFields["fleet.gateways.form.password"]
        if usernameField.waitForExistence(timeout: 5) {
            usernameField.tap()
            usernameField.typeText(username)
        }
        if passwordField.waitForExistence(timeout: 5) {
            passwordField.tap()
            passwordField.typeText(password)
        }
        attachScreenshot(of: app, name: "p3fix-step2-add-form-userpass")

        tap(firstMatch(in: app, identifier: "fleet.gateways.form.save"))

        // The gateway row appears (registry + Keychain write of user+pass).
        let row = firstMatch(in: app, identifier: "fleet.gateways.row.\(gatewayID)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "LAN gateway row should appear after add")
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 4) {
            notNow.tap()
            sleep(1)
        }
        attachScreenshot(of: app, name: "p3fix-step3-gateway-added-row")

        // Test Connection via the row's menu → REAL probe against the LAN
        // gateway: password-login → session cookie → ws-ticket → WS connect.
        let menuBtn = app.buttons["fleet.gateways.row.\(gatewayID).menu"]
        if menuBtn.waitForExistence(timeout: 5) {
            menuBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let testConn = app.buttons["Test Connection"]
            if testConn.waitForExistence(timeout: 5) {
                testConn.tap()
            }
        }
        // The local-network permission prompt fires on the FIRST LAN connect
        // attempt (a SpringBoard system alert); grant it now if present.
        handleLocalNetworkPrompt()
        sleep(8)
        attachScreenshot(of: app, name: "p3fix-step3-test-connection-result")

        // ACCEPTANCE: the row shows Connected (Reachable), not Unreachable.
        let connected = app.staticTexts["Connected"]
        XCTAssertTrue(connected.waitForExistence(timeout: 15),
                      "LAN gateway must classify CONNECTED after the username/password fix")
        XCTAssertFalse(app.staticTexts["Unreachable"].exists,
                       "LAN gateway must NOT be offline after the username/password fix")

        attachScreenshot(of: app, name: "p3fix-final-state")
    }

    // MARK: Helpers

    /// Reads username= / password= lines from /tmp/hermes_lan_surface/.cred.
    /// Values are used only to fill the secure form fields — never printed,
    /// logged, or asserted.
    private func readCreds() -> (String, String) {
        guard let text = try? String(contentsOfFile: "/tmp/hermes_lan_surface/.cred", encoding: .utf8) else {
            return ("", "")
        }
        var username = ""
        var password = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("username=") { username = String(line.dropFirst("username=".count)) }
            if line.hasPrefix("password=") { password = String(line.dropFirst("password=".count)) }
        }
        return (username, password)
    }

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
