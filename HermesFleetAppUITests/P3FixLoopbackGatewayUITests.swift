import XCTest

/// t_eb5455f2 isolation proof: the FULL app auth+connect code path reaches
/// Connected against the REAL LAN gateway, via a loopback forwarder the
/// simulator CAN reach (127.0.0.1:9120 -> 192.168.50.37:9120). The simulator
/// app is gated from the Mac's own LAN IP by iOS local-network privacy, but
/// 127.0.0.1 is reachable (proven by L1 tests). This drives the same
/// Username & Password flow + real creds through the SAME code path P3 used.
final class P3FixLoopbackGatewayUITests: XCTestCase {
    private let endpoint = "http://127.0.0.1:9120"
    private let displayName = "Mac LAN (loopback)"
    private let gatewayID = "127.0.0.1:9120"

    override func setUpWithError() throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Local Network permission") { alert in
            let allow = alert.buttons["Allow"]
            if allow.exists {
                allow.tap()
                return true
            }
            return false
        }
    }

    @discardableResult
    private func handleLocalNetworkPrompt(within seconds: TimeInterval = 6) -> Bool {
        let app = XCUIApplication()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            app.tap()
            sleep(1)
        }
        return true
    }

    func testLoopbackGatewayUsernamePasswordReachesConnected() throws {
        let app = XCUIApplication()
        // H1 (R4): app lock defaults ON in Release; opt out for this live suite.
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launch()
        UITabNavigation.openGatewaysTab(app)
        handleLocalNetworkPrompt()
        attachScreenshot(of: app, name: "lb-step1-open-gateways")

        // Add the gateway via the U2 add-gateway sheet.
        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        nameField.tap()
        nameField.typeText(displayName)
        endpointField.tap()
        endpointField.typeText(endpoint)

        // Username & Password strategy + real creds from .cred.
        tap(firstMatch(in: app, identifier: "fleet.gateways.form.strategy"))
        let userPass = app.buttons["Username & Password"]
        if userPass.waitForExistence(timeout: 5) { userPass.tap() }
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
        tap(firstMatch(in: app, identifier: "fleet.gateways.form.save"))
        handleLocalNetworkPrompt()

        // Dismiss the iOS "Save Password?" autofill sheet if present.
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 4) {
            notNow.tap()
            sleep(1)
        }

        let row = firstMatch(in: app, identifier: "fleet.gateways.row.\(gatewayID)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "gateway row should appear after add")
        attachScreenshot(of: app, name: "lb-step2-gateway-added")

        // Test Connection via the row's menu.
        let menuBtn = app.buttons["fleet.gateways.row.\(gatewayID).menu"]
        if menuBtn.waitForExistence(timeout: 5) {
            menuBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let testConn = app.buttons["Test Connection"]
            if testConn.waitForExistence(timeout: 5) {
                testConn.tap()
            }
        }
        handleLocalNetworkPrompt()
        sleep(8)
        attachScreenshot(of: app, name: "lb-step3-test-connection-result")

        // ACCEPTANCE: Connected (Reachable), not Unreachable.
        let connected = app.staticTexts["Connected"]
        XCTAssertTrue(connected.waitForExistence(timeout: 15),
                      "gateway must classify CONNECTED through the loopback forwarder")
        XCTAssertFalse(app.staticTexts["Unreachable"].exists,
                       "gateway must NOT be offline")
        attachScreenshot(of: app, name: "lb-final-state")
    }

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
