import XCTest

/// L1 follow-up (t_c0bfc604): prove the app auth-wiring fix end-to-end against
/// a REAL live Hermes gateway.
///
/// Drives the RELEASE app (production graph: real Keychain + live transport)
/// on the simulator against a real `hermes serve` on loopback :9119 (started
/// by scripts/l1_start_serve.sh). Adds a real gateway via the U2 UI with the
/// **loopback token** strategy (the `?token=` path the live serve accepts),
/// then asserts the acceptance criteria:
///   1. the in-app live probe classifies the gateway **Reachable** (Connected),
///      not Unreachable/offline (L1 PHASE 3 previously HOLD);
///   2. the Roster returns **real profiles** against the live gateway
///      (no "No Bots").
///
/// Credential safety: the loopback test token is read at runtime from
/// /tmp/l1_live_test/.token (chmod 600, written by l1_start_serve.sh) and is
/// NEVER printed, logged, or asserted. It is a throwaway test token for a
/// local throwaway serve instance.
final class L1FixLiveGatewayUITests: XCTestCase {

    private let endpoint = "http://127.0.0.1:9119"
    private let displayName = "Mac Live"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddedRealGatewayConnectsAndRosterShowsProfiles() throws {
        let app = XCUIApplication()
        // H1 (R4): app lock defaults ON in Release; opt out for this live suite.
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launch()

        // Release starts at the Gateways screen (empty registry).
        UITabNavigation.openGatewaysTab(app)
        attachScreenshot(of: app, name: "l1fix-step1-open-gateways")

        // Add the REAL gateway via the U2 add-gateway sheet (no hardcode).
        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        nameField.tap()
        nameField.typeText(displayName)
        endpointField.tap()
        endpointField.typeText(endpoint)
        attachScreenshot(of: app, name: "l1fix-step2-add-form-filled")

        // Loopback Token strategy + the real test token from the token file.
        tap(firstMatch(in: app, identifier: "fleet.gateways.form.strategy"))
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
        attachScreenshot(of: app, name: "l1fix-step2-add-form-strategy-token")

        tap(firstMatch(in: app, identifier: "fleet.gateways.form.save"))

        // The gateway row appears (registry + Keychain write).
        let row = firstMatch(in: app, identifier: "fleet.gateways.row.127.0.0.1:9119")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "real gateway row should appear after add")
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 4) {
            notNow.tap()
            sleep(1)
        }
        attachScreenshot(of: app, name: "l1fix-step3-gateway-added-row")

        // Test connection via the row's menu → REAL probe against the live serve.
        let menuBtn = app.buttons["fleet.gateways.row.127.0.0.1:9119.menu"]
        if menuBtn.waitForExistence(timeout: 5) {
            menuBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let testConn = app.buttons["Test Connection"]
            if testConn.waitForExistence(timeout: 5) {
                testConn.tap()
            }
        }
        sleep(6)
        attachScreenshot(of: app, name: "l1fix-step3-test-connection-result")

        // ACCEPTANCE 1: the row shows Connected (Reachable), not Unreachable.
        let connected = app.staticTexts["Connected"]
        XCTAssertTrue(connected.waitForExistence(timeout: 8),
                      "live gateway should classify REACHABLE (Connected) after the auth fix")
        XCTAssertFalse(app.staticTexts["Unreachable"].exists,
                       "live gateway must NOT be offline after the auth fix")

        // ACCEPTANCE 2: the Roster returns REAL profiles against the live serve
        // (Bots tab under the U3 tab shell).
        UITabNavigation.openBotsTab(app)
        // The roster auto-refreshes once at launch (before the gateway was
        // added), so re-probe explicitly — the same action a user takes.
        sleep(2)
        let refresh = app.buttons["fleet.roster.refresh"]
        if refresh.waitForExistence(timeout: 5) { refresh.tap() }
        sleep(6)
        attachScreenshot(of: app, name: "l1fix-step4-roster-live")
        let noBots = firstMatch(in: app, identifier: "fleet.roster.no-bots")
        XCTAssertFalse(noBots.exists,
                       "roster must NOT show 'No Bots' — the live gateway reported profiles")
        let hasBotRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'fleet.roster.row.'"))
            .firstMatch
        XCTAssertTrue(hasBotRow.waitForExistence(timeout: 8),
                      "roster should list at least one real profile from the live gateway")

        attachScreenshot(of: app, name: "l1fix-final-state")
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
