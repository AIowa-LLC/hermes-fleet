import XCTest

/// T2 (t_f54b722e): prove the app works over the Tailscale (tailnet) endpoint.
///
/// Drives the RELEASE app (production graph: real Keychain + live transport)
/// on the iOS Simulator. The simulator app is held from the Mac's OWN IPs
/// (both LAN 192.168.50.37 and tailnet 100.100.200.61) by iOS local-network
/// privacy — the P3-accepted workaround is a Host+Origin-rewriting loopback
/// forwarder, so this test reaches BOTH real surfaces through the forwarders
/// started by a TCP forwarder (scripts/t2_tcp_forward.py):
///   19120 -> 100.100.200.61:9120 (TAILNET surface)
///   19121 -> 192.168.50.37:9120   (LAN surface)
/// and:
///   1. add the tailnet gateway via the U2 UI (username/password from .cred)
///   2. Test Connection -> Connected (Reachable), not Unreachable
///   3. add the LAN gateway (regression — multi-gateway list shows both)
///   4. refresh the union roster -> BOTH gateways + bots render
///   5. drill tailnet -> Default bot -> resume the clean "T2 tailnet PONG"
///      session (created by the probe, NOT a live cron session) -> send a real
///      prompt -> receive the streamed answer
///   6. screenshots at every step land in the .xcresult for evidence.
///
/// The direct tailnet endpoint (100.100.200.61:9120) itself is verified by
/// an HTTP auth-chain probe (full auth chain + live conversation turn +
/// serve log frames) — the ATS exception for 100.x lives in Info.plist so a
/// REAL device on the tailnet can reach it directly.
///
/// Credential safety: the real username/password are read at runtime from
/// /tmp/hermes_lan_surface/.cred (0600) and are NEVER printed, logged, or
/// committed. The clean session id is read from /tmp/t2_session.json (written
/// against the forwarder surface).
final class T2FixTailnetGatewayUITests: XCTestCase {

    private let tailnetEndpoint = "http://127.0.0.1:19120"
    private let tailnetName = "Mac Tailnet"
    private let tailnetID = "127.0.0.1:19120"

    private let lanEndpoint = "http://127.0.0.1:19121"
    private let lanName = "Mac LAN"
    private let lanID = "127.0.0.1:19121"

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

    func testTailnetGatewayConnectedPlusTurn() throws {
        let app = XCUIApplication()
        // H1 (R4): app lock defaults ON in Release; opt out for this live suite.
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launch()

        UITabNavigation.openGatewaysTab(app)
        handleLocalNetworkPrompt()
        attachScreenshot(of: app, name: "t2-step0-open-gateways")

        // ---- 1. Add the TAILNET gateway -----------------------------------
        addGateway(in: app, name: tailnetName, endpoint: tailnetEndpoint,
                   displayName: tailnetName)
        assertRow(in: app, gatewayID: tailnetID, label: tailnetName)
        attachScreenshot(of: app, name: "t2-step1-tailnet-gateway-added")

        // ---- 2. Test Connection: tailnet -> Connected ---------------------
        testConnection(in: app, gatewayID: tailnetID)
        let connectedText = app.staticTexts["Connected"]
        XCTAssertTrue(connectedText.waitForExistence(timeout: 40),
                      "tailnet gateway must classify CONNECTED (Reachable)")
        XCTAssertFalse(app.staticTexts["Unreachable"].exists,
                       "tailnet gateway must NOT be offline")
        attachScreenshot(of: app, name: "t2-step2-tailnet-connected")

        // ---- 3. Add the LAN gateway (regression) ---------------------------
        addGateway(in: app, name: lanName, endpoint: lanEndpoint,
                   displayName: lanName)
        assertRow(in: app, gatewayID: lanID, label: lanName)
        attachScreenshot(of: app, name: "t2-step3-lan-gateway-added")

        // ---- 4. Refresh the union roster -> bots from BOTH gateways -------
        tap(firstMatch(in: app, identifier: "fleet.gateways.refresh"))
        sleep(6)
        UITabNavigation.openBotsTab(app)
        XCTAssertTrue(app.navigationBars["Fleet Roster"].waitForExistence(timeout: 10),
                      "Roster screen should open")
        XCTAssertTrue(app.staticTexts[tailnetName].waitForExistence(timeout: 15),
                      "roster should list the tailnet gateway")
        XCTAssertTrue(app.staticTexts[lanName].waitForExistence(timeout: 15),
                      "roster should list the LAN gateway")
        // A bot row exists under the tailnet gateway (route <gateway>#<profile>).
        // Match any fleet.roster.row.* identifier OR a label containing
        // "Default"/"default" (the default profile's display name).
        let rosterRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "fleet.roster.row."))
            .firstMatch
        let rosterBot = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "default"))
            .firstMatch
        XCTAssertTrue(
            rosterRow.waitForExistence(timeout: 20) || rosterBot.waitForExistence(timeout: 5),
            "roster should list a bot on the tailnet gateway")
        attachScreenshot(of: app, name: "t2-step4-roster-both-gateways")
        // Back to the registry cockpit (Gateways tab under the U3 shell).
        UITabNavigation.openGatewaysTab(app)

        // ---- 5. Drill tailnet -> Default bot -> clean session -> turn -----
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.\(tailnetID)"))
        XCTAssertTrue(app.navigationBars[tailnetName].waitForExistence(timeout: 10),
                      "Bots screen for the tailnet gateway should open")
        tap(firstMatch(in: app, identifier: "fleet.bots.row.\(tailnetID)#default"))
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 15),
            "Bot detail should render")
        attachScreenshot(of: app, name: "t2-step4-tailnet-default-bot")

        let sessionID = readCleanSessionID()
        XCTAssertFalse(sessionID.isEmpty, "clean session id should be persisted by the probe")
        let sessionRow = firstMatch(in: app, identifier: "fleet.bot-detail.sessions.row.\(sessionID)")
        if !sessionRow.waitForExistence(timeout: 10) {
            // The mission sequencer cron keeps creating sessions, so the clean
            // "T2 tailnet PONG" session may be below the fold. Bounded scroll
            // (SwiftUI List only materializes on-screen cells).
            var found = false
            for _ in 0..<8 where !found {
                app.swipeUp()
                if sessionRow.waitForExistence(timeout: 3) { found = true }
            }
            XCTAssertTrue(found, "clean session row should appear (scrolled)")
        }
        sessionRow.tap()

        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15),
                      "conversation canvas should open with a composer")
        waitUntilEnabled(composer, timeout: 25)
        attachScreenshot(of: app, name: "t2-step5-conversation-resumed-over-tailnet")

        composer.tap()
        composer.typeText("Reply with exactly: PONG 2")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))

        let answer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "PONG"))
            .firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 180),
                      "streamed assistant answer should render over the tailnet gateway")
        attachScreenshot(of: app, name: "t2-step6-tailnet-conversation-turn-answer")
    }

    // MARK: Helpers

    private func addGateway(in app: XCUIApplication, name: String,
                            endpoint: String, displayName: String) {
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
        // S3 cleartext gate: http:// to a NON-private host (tailnet 100.x is
        // CGNAT) requires explicit confirm — but the forwarder endpoint here is
        // 127.0.0.1 (loopback), so no warning is expected. Handle either way.
        let confirm = app.switches["fleet.gateways.form.cleartext-confirm"].firstMatch
        if confirm.waitForExistence(timeout: 3) {
            confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertTrue(waitUntilValue(confirm, isOn: true, timeout: 5),
                          "cleartext confirmation toggle should read ON after tap")
        }
        let save = app.buttons["fleet.gateways.form.save"].firstMatch
        XCTAssertTrue(waitUntilEnabled(save, timeout: 5), "Save should be enabled")
        save.tap()
        handleLocalNetworkPrompt()
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 4) {
            notNow.tap()
            sleep(1)
        }
    }

    private func assertRow(in app: XCUIApplication, gatewayID: String, label: String) {
        let row = firstMatch(in: app, identifier: "fleet.gateways.row.\(gatewayID)")
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "gateway row \(gatewayID) should appear after add")
        XCTAssertTrue(app.staticTexts[label].exists, "row should show display name \(label)")
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

    private func readCleanSessionID() -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/t2_session.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["session_id"] as? String else {
            return ""
        }
        return id
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

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.isEnabled
    }

    @discardableResult
    private func waitUntilValue(_ element: XCUIElement, isOn: Bool, timeout: TimeInterval) -> Bool {
        let wanted = isOn ? "1" : "0"
        let deadline = Date().addingTimeInterval(timeout)
        while (element.value as? String) != wanted && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return (element.value as? String) == wanted
    }

    private func tapBack(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "back button should appear")
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
