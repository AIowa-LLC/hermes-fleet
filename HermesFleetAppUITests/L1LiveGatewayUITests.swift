import XCTest

/// L1 live gateway dogfood — PHASE 2 + 3.
///
/// Drives the RELEASE app (production graph: real Keychain + live transport)
/// on the simulator against a REAL Hermes gateway surface (`hermes serve` on
/// loopback :9119, started by scripts/l1_start_serve.sh). This is the first
/// live-connection validation: the app adds a real gateway via the U2
/// gateway-management UI (no hardcoding), then attempts the §32 walkthrough
/// steps against the live gateway.
///
/// Credential safety: the loopback test token is read at runtime from
/// /tmp/l1_live_test/.token (written by l1_start_serve.sh, chmod 600) and is
/// NEVER printed, logged, or asserted. It is a throwaway test token for a
/// local throwaway serve instance.
final class L1LiveGatewayUITests: XCTestCase {

    private let endpoint = "http://127.0.0.1:9119"
    private let displayName = "Mac Live"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: §32 step 1 — open the app

    func testAddRealGatewayViaU2UIAndAttemptLiveWalkthrough() throws {
        let app = XCUIApplication()
        // H1 (R4): app lock defaults ON in Release; opt out for this live suite.
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launch()

        // Step 1: open the app — U3 tab shell; the registry cockpit is the
        // Gateways tab (Release, empty registry, production graph).
        UITabNavigation.openGatewaysTab(app)
        attachScreenshot(of: app, name: "l1-step1-open-gateways")

        // Step 2/Phase 2: add the REAL gateway via the U2 add-gateway sheet.
        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        nameField.tap()
        nameField.typeText(displayName)
        endpointField.tap()
        endpointField.typeText(endpoint)
        attachScreenshot(of: app, name: "l1-step2-add-form-filled")

        // Select the Loopback Token strategy (the live `?token=` path that the
        // real serve accepts) and enter the test token from the token file.
        tap(firstMatch(in: app, identifier: "fleet.gateways.form.strategy"))
        // Picker rows surface as buttons with the strategy label.
        let loopback = app.buttons["Loopback Token"]
        if loopback.waitForExistence(timeout: 5) { loopback.tap() }

        let tokenField = app.secureTextFields["fleet.gateways.form.token"]
        if tokenField.waitForExistence(timeout: 5) {
            let token = readTestToken()
            if !token.isEmpty {
                tokenField.tap()
                tokenField.typeText(token)
            }
        }
        attachScreenshot(of: app, name: "l1-step2-add-form-strategy-token")

        tap(firstMatch(in: app, identifier: "fleet.gateways.form.save"))

        // The gateway row should now appear (registry + Keychain write).
        let row = firstMatch(in: app, identifier: "fleet.gateways.row.127.0.0.1:9119")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "real gateway row should appear after add")
        // A system "Save Password?" prompt may overlay after the SecureField;
        // dismiss it so it can't steal subsequent taps.
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 4) {
            notNow.tap()
            sleep(1)
        }
        attachScreenshot(of: app, name: "l1-step3-gateway-added-row")

        // §32 test connection (§13 probe) via the row's menu, so the app
        // attempts a REAL probe against the live serve and classifies it.
        let menuBtn = app.buttons["fleet.gateways.row.127.0.0.1:9119.menu"]
        if menuBtn.waitForExistence(timeout: 5) {
            menuBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let testConn = app.buttons["Test Connection"]
            if testConn.waitForExistence(timeout: 5) {
                testConn.tap()
            }
        }
        sleep(5)
        attachScreenshot(of: app, name: "l1-step3-test-connection-result")

        // §32 step 2 — see which bots/machines are available: open the Roster
        // (Bots tab under the U3 tab shell).
        UITabNavigation.openBotsTab(app)
        sleep(4)
        attachScreenshot(of: app, name: "l1-step4-roster-live")

        // §32 step 3/4 — drill into the real gateway (Bots screen).
        UITabNavigation.openGatewaysTab(app)
        if firstMatch(in: app, identifier: "fleet.gateways.row.127.0.0.1:9119").waitForExistence(timeout: 5) {
            firstMatch(in: app, identifier: "fleet.gateways.row.127.0.0.1:9119")
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(4)
            attachScreenshot(of: app, name: "l1-step5-bots-live")
        }

        // §32 steps 5-7 would send a prompt and watch the streamed reply; the
        // companion evidence (scripts/l1_live_contract*.sh) exercises the live
        // gateway JSON-RPC directly. In-app auth behavior is captured by the
        // screenshots + classified status above.
        attachScreenshot(of: app, name: "l1-final-state")
    }

    // MARK: Helpers

    private func readTestToken() -> String {
        // Test-only token for a local throwaway serve; never printed/logged.
        (try? String(contentsOfFile: "/tmp/l1_live_test/.token", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
