import XCTest

/// P0-7 LIVE verification (t_8a7f3dce): the two dogfood defects from
/// TestFlight 0.1.0(3) over the tailnet gateway, reproduced against the REAL
/// gateway through the P3-accepted loopback forwarder (sim local-network
/// privacy workaround):
///
///   (1) "invalid gateway connection state: connect() from open" when opening
///       an EXISTING session and sending after the conversation screen had
///       been entered once before (re-entry against the shared open
///       transport);
///   (2) no UI to create a new session.
///
/// Flow (Release build, real Keychain + live WebSocket transport):
///   add tailnet gateway → connect → drill Default bot → open session
///   "default" → send → reply streams → POP → RE-ENTER → send again → reply
///   streams again, no state error → back → New Session → send → reply
///   streams (session.create path).
///
/// Credential safety: username/password are read at runtime from
/// /tmp/hermes_lan_surface/.cred (0600) and NEVER printed, logged, or
/// committed. Run via the live LAN/tailnet forwarder pattern (scripts/h2_uitest.sh) +
/// evidence export).
final class P0_7LiveTailnetUITests: XCTestCase {

    private let tailnetEndpoint = "http://127.0.0.1:19120"
    private let tailnetName = "P0-7 Tailnet"
    private let tailnetID = "127.0.0.1:19120"

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

    func testTailnetExistingSessionReentryAndNewSession() throws {
        let app = XCUIApplication()
        // H1 (R4): app lock defaults ON in Release; opt out for this live suite.
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launch()
        UITabNavigation.openGatewaysTab(app)
        handleLocalNetworkPrompt()

        // ---- 1. Add + connect the tailnet gateway --------------------------
        addGateway(in: app, name: tailnetName, endpoint: tailnetEndpoint)
        testConnection(in: app, gatewayID: tailnetID)
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 40),
                      "tailnet gateway must classify CONNECTED")
        attachScreenshot(of: app, name: "p07-step1-tailnet-connected")

        // ---- 2. Drill to Default bot detail --------------------------------
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.\(tailnetID)"))
        UITabNavigation.openGatewayBots(app, gateway: tailnetID)
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 10))
        // BotsView reads the union roster snapshot — refresh it so the tailnet
        // gateway's bots load (mirrors the T2 roster-refresh step).
        tapRefreshOnBots(app)
        let botRow = firstMatch(in: app, identifier: "fleet.roster.row.\(tailnetID)#default")
        XCTAssertTrue(botRow.waitForExistence(timeout: 30),
                      "tailnet default bot should appear after roster refresh")
        tap(botRow)
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 15),
            "Bot detail should render")

        // ---- 3. Open the EXISTING "default" session (first entry) ---------
        let defaultRow = firstMatch(in: app, identifier: "fleet.bot-detail.sessions.row.")
        XCTAssertTrue(defaultRow.waitForExistence(timeout: 20),
                      "a session row must exist for the default bot")
        tap(defaultRow)
        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20),
                      "conversation canvas should open with a composer")
        waitUntilEnabled(composer, timeout: 30)
        attachScreenshot(of: app, name: "p07-step3-existing-session-opened")

        // First send on the existing session.
        sendAndAssertReply(app, text: "Reply with exactly: P0-7 FIRST",
                           expected: "P0-7 FIRST", screenshot: "p07-step4-first-send-reply")

        // ---- 4. POP + RE-ENTER the same session (the dogfood defect) ------
        tapBack(app)
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 15),
            "Bot detail should render")
        attachScreenshot(of: app, name: "p07-step5-popped-to-bot-detail")
        tap(defaultRow)
        XCTAssertTrue(composer.waitForExistence(timeout: 20),
                      "re-entered conversation canvas opens")
        waitUntilEnabled(composer, timeout: 30)

        // THE P0-7 assertions: re-entered send streams a reply and NO
        // "invalid gateway connection state" error renders anywhere.
        sendAndAssertReply(app, text: "Reply with exactly: P0-7 REENTRY",
                           expected: "P0-7 REENTRY", screenshot: "p07-step6-reentry-send-reply")
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@",
                                      "invalid gateway connection state"))
                .firstMatch.exists,
            "no 'invalid gateway connection state' error may render after re-entry")

        // ---- 5. NEW SESSION affordance (the second gap) --------------------
        tapBack(app)
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 15))
        let newSession = firstMatch(in: app, identifier: "fleet.bot-detail.sessions.new")
        XCTAssertTrue(newSession.waitForExistence(timeout: 10),
                      "New Session affordance must exist on the live sessions list")
        tap(newSession)
        XCTAssertTrue(composer.waitForExistence(timeout: 20),
                      "new session conversation canvas opens with a composer")
        waitUntilEnabled(composer, timeout: 30)
        attachScreenshot(of: app, name: "p07-step7-new-session-opened")

        sendAndAssertReply(app, text: "Reply with exactly: P0-7 NEWSESSION",
                           expected: "P0-7 NEWSESSION", screenshot: "p07-step8-new-session-send-reply")

        // ---- 6. Pop back: the new session appears in the list --------------
        tapBack(app)
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 15))
        // Sessions refresh on entry (P0-7); give the read-only session.list
        // a moment, then look for a second session row.
        sleep(3)
        let rowCount = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                  "fleet.bot-detail.sessions.row."))
            .allElementsBoundByIndex.count
        XCTAssertGreaterThanOrEqual(rowCount, 2,
              "sessions list should now show the created session (was 1 before)")
        attachScreenshot(of: app, name: "p07-step9-list-shows-new-session")
    }

    // MARK: Helpers

    private func sendAndAssertReply(_ app: XCUIApplication, text: String,
                                    expected: String, screenshot: String) {
        let composer = app.textFields["fleet.conversation.composer"]
        waitUntilEnabled(composer, timeout: 30)
        composer.tap()
        composer.typeText(text)
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))
        let answer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", expected))
            .firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 180),
                      "streamed reply containing '\(expected)' must render over the tailnet gateway")
        attachScreenshot(of: app, name: screenshot)
    }

    private func addGateway(in app: XCUIApplication, name: String, endpoint: String) {
        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        nameField.tap()
        nameField.typeText(name)
        endpointField.tap()
        endpointField.typeText(endpoint)

        tap(firstMatch(in: app, identifier: "fleet.gateways.form.strategy"))
        selectStrategyUsernamePassword(in: app)

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
        // S3 cleartext gate: the forwarder endpoint is 127.0.0.1 (loopback),
        // so no warning is expected — handle either way.
        let confirm = app.switches["fleet.gateways.form.cleartext-confirm"].firstMatch
        if confirm.waitForExistence(timeout: 3) {
            confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertTrue(waitUntilValue(confirm, isOn: true, timeout: 5),
                          "cleartext confirmation toggle should read ON after tap")
        }
        let save = app.buttons["fleet.gateways.form.save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save should exist")
        waitUntilEnabled(save, timeout: 5)
        save.tap()
        handleLocalNetworkPrompt()
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 4) {
            notNow.tap()
            sleep(1)
        }
    }

    private func selectStrategyUsernamePassword(in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let opt = firstOption(in: app, label: "Username & Password")
            if opt.waitForExistence(timeout: 4) {
                opt.tap()
            }
            if app.textFields["fleet.gateways.form.username"].waitForExistence(timeout: 4) {
                return
            }
            app.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if firstMatch(in: app, identifier: "fleet.gateways.form.strategy").exists {
                firstMatch(in: app, identifier: "fleet.gateways.form.strategy").tap()
            }
        }
        XCTFail("could not select Username & Password strategy")
    }

    private func firstOption(in app: XCUIApplication, label: String) -> XCUIElement {
        let buttons = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        if buttons.exists { return buttons }
        let cells = app.cells.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        if cells.exists { return cells }
        return app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    private func testConnection(in app: XCUIApplication, gatewayID: String) {
        let menuBtn = app.buttons["fleet.gateways.row.\(gatewayID).menu"]
        if menuBtn.waitForExistence(timeout: 5) {
            menuBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let testConn = app.buttons["Test Connection"]
            if testConn.waitForExistence(timeout: 5) {
                testConn.tap()
            }
        }
        handleLocalNetworkPrompt()
        sleep(12)
    }

    private func waitUntilValue(_ element: XCUIElement, isOn: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.value as? String == (isOn ? "1" : "0") { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return element.value as? String == (isOn ? "1" : "0")
    }

    private func readCreds() -> (String, String) {
        guard let data = FileManager.default.contents(atPath: "/tmp/hermes_lan_surface/.cred"),
              let text = String(data: data, encoding: .utf8) else {
            return ("", "")
        }
        var username = ""
        var password = ""
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "username": username = String(parts[1])
            case "password": password = String(parts[1])
            default: break
            }
        }
        return (username, password)
    }

    private func tapRefreshOnBots(_ app: XCUIApplication) {
        let refresh = app.buttons["Refresh"].firstMatch
        if refresh.waitForExistence(timeout: 5) {
            refresh.tap()
            // Roster refresh connects + fetches profiles.list/session.list
            // over the forwarder; give it time to populate.
            sleep(6)
        }
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing element: \(element)")
        element.tap()
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", identifier))
            .firstMatch
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(element.isEnabled, "Element never became enabled: \(element)")
    }

    private func tapBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Back button must exist")
        back.tap()
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
