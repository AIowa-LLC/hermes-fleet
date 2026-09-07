import XCTest

/// H2 (t_5da54f59): Connection health dashboard renders live against the LAN
/// gateway and stats survive app restart.
///
/// Drives the RELEASE app (production graph: real Keychain + live transport +
/// file-backed SwiftData cache) on the iOS Simulator. Like T2, the simulator
/// app reaches the Mac's LAN surface through the loopback forwarder
/// (19121 -> 192.168.50.37:9120) started by scripts/h2_uitest.sh.
///
/// Flow:
///   1. add the LAN gateway via the U2 UI (username/password from .cred)
///   2. row menu Connect -> Connected (live against the LAN gateway; the
///      health-fed connection factory)
///   3. row menu Disconnect -> Reconnect (drives a real transport teardown +
///      re-establishment through the health-fed connection factory)
///   4. open the Health dashboard -> assert live Connected state + uptime %
///      + reconnect count + last-disconnect reason + ping RTT (heartbeat)
///   5. terminate + relaunch the app (container persists), re-add the gateway
///      (registry is in-memory; the SwiftData health store is not), Connect,
///      reopen the Health dashboard -> assert stats SURVIVED the restart
///      (reconnect count >= 1, last-disconnect reason, uptime present)
///
/// Credential safety: the real username/password are read at runtime from
/// /tmp/hermes_lan_surface/.cred (0600) and are NEVER printed, logged, or
/// committed.
final class H2HealthDashboardUITests: XCTestCase {

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

    func testHealthDashboardLiveAndSurvivesRestart() throws {
        let app = XCUIApplication()
        // H1 (R4): app lock defaults ON in Release; opt out for this live suite.
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        // H2: 2s heartbeat so ping RTT renders within seconds — well inside
        // the LAN relay's ~30s socket lifetime (test-support knob only).
        app.launchEnvironment["HERMES_FLEET_PING_INTERVAL_SECONDS"] = "2"
        app.launch()

        UITabNavigation.openGatewaysTab(app)
        handleLocalNetworkPrompt()
        attachScreenshot(of: app, name: "h2-step0-open-gateways")

        // ---- 1. Add the LAN gateway ----------------------------------------
        addGateway(in: app, name: lanName, endpoint: lanEndpoint)
        assertRow(in: app, gatewayID: lanID, label: lanName)
        attachScreenshot(of: app, name: "h2-step1-lan-gateway-added")

        // ---- 2. Connect via the row menu (the health-fed path; Test
        // Connection uses an unfed probe transport by design) ---------------
        rowMenuAction(in: app, gatewayID: lanID, action: "Connect")
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 40),
                      "LAN gateway must classify CONNECTED (live against the LAN gateway)")
        attachScreenshot(of: app, name: "h2-step2-lan-connected")

        // ---- 3. Disconnect -> Reconnect (drives real transport events on
        // the health-fed connection: teardown reason + re-establishment) ----
        rowMenuAction(in: app, gatewayID: lanID, action: "Disconnect")
        XCTAssertTrue(app.staticTexts["Disconnected"].waitForExistence(timeout: 15),
                      "row should show Disconnected after teardown")
        rowMenuAction(in: app, gatewayID: lanID, action: "Reconnect")
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 40),
                      "row should show Connected after reconnect")
        attachScreenshot(of: app, name: "h2-step3-reconnected")

        // ---- 4. Health dashboard: live stats ------------------------------
        openHealthDashboard(in: app)
        XCTAssertTrue(app.navigationBars["Connection Health"].waitForExistence(timeout: 10),
                      "Health dashboard should open")
        let row = firstMatch(in: app, identifier: "fleet.health.row.\(lanID)")
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "health row should render for the LAN gateway")
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 10),
                      "health dashboard shows the LIVE Connected state")

        let reconnects = app.staticTexts["fleet.health.reconnects.\(lanID)"]
        XCTAssertTrue(reconnects.waitForExistence(timeout: 10), "reconnect count row")
        XCTAssertGreaterThanOrEqual(reconnectCount(reconnects.label), 1,
                                    "Disconnect->Reconnect must be counted")

        let lastDisconnect = app.staticTexts["fleet.health.last-disconnect.\(lanID)"]
        XCTAssertTrue(lastDisconnect.waitForExistence(timeout: 10), "last-disconnect row")
        XCTAssertTrue(lastDisconnect.label.contains("normal closure"),
                      "last disconnect reason should be the classified normal closure")

        let uptime = app.staticTexts["fleet.health.uptime.\(lanID)"]
        XCTAssertTrue(uptime.waitForExistence(timeout: 10), "uptime row")
        XCTAssertTrue(uptime.label.contains("%"), "uptime should render as a percentage")

        // Ping RTT arrives on the first heartbeat (~15s in Release config);
        // bounded wait so the dashboard's live RTT is proven against the real
        // gateway.
        let rtt = app.staticTexts["fleet.health.rtt.\(lanID)"]
        XCTAssertTrue(rtt.waitForExistence(timeout: 10), "RTT row")
        let rttDeadline = Date().addingTimeInterval(60)
        while !rtt.label.contains("ms") && Date() < rttDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertTrue(rtt.label.contains("ms"),
                      "heartbeat ping RTT should render after the first pong (got: \(rtt.label))")
        attachScreenshot(of: app, name: "h2-step4-health-live-stats")

        // ---- 5. Restart: stats survive via FleetPersistence ---------------
        app.terminate()
        app.launch()
        UITabNavigation.openGatewaysTab(app)
        handleLocalNetworkPrompt()

        // Registry is in-memory (only credentials + health stats persist), so
        // re-add the same endpoint -> same GatewayID -> persisted stats.
        addGateway(in: app, name: lanName, endpoint: lanEndpoint)
        assertRow(in: app, gatewayID: lanID, label: lanName)
        // The health-fed path is the row menu CONNECT (Test Connection uses an
        // unfed probe transport by design).
        rowMenuAction(in: app, gatewayID: lanID, action: "Connect")
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 40),
                      "reconnect after restart should be Connected")

        openHealthDashboard(in: app)
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.health.row.\(lanID)")
            .waitForExistence(timeout: 10), "health row after restart")

        let survivedReconnects = app.staticTexts["fleet.health.reconnects.\(lanID)"]
        XCTAssertTrue(survivedReconnects.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(reconnectCount(survivedReconnects.label), 1,
                                    "reconnect count must SURVIVE the app restart")

        let survivedDisconnect = app.staticTexts["fleet.health.last-disconnect.\(lanID)"]
        XCTAssertTrue(survivedDisconnect.waitForExistence(timeout: 10))
        XCTAssertTrue(survivedDisconnect.label.contains("normal closure"),
                      "last-disconnect reason must SURVIVE the app restart")

        let survivedUptime = app.staticTexts["fleet.health.uptime.\(lanID)"]
        XCTAssertTrue(survivedUptime.waitForExistence(timeout: 10))
        XCTAssertTrue(survivedUptime.label.contains("%"),
                      "uptime must render after restart (persisted + continued)")
        attachScreenshot(of: app, name: "h2-step5-health-after-restart")
    }

    // MARK: Helpers

    private func reconnectCount(_ label: String) -> Int {
        // V5 (t_b2628d33): metrics are combined FleetMetadataRow elements —
        // the label reads "Reconnects: 2" (KEY: VALUE), not the bare count.
        let value = label.split(separator: ":", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last ?? label
        return Int(value) ?? -1
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
        let confirm = app.switches["fleet.gateways.form.cleartext-confirm"].firstMatch
        if confirm.waitForExistence(timeout: 3) {
            confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
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

    private func rowMenuAction(in app: XCUIApplication, gatewayID: String, action: String) {
        let menuBtn = app.buttons["fleet.gateways.row.\(gatewayID).menu"]
        XCTAssertTrue(menuBtn.waitForExistence(timeout: 10), "row menu should appear")
        menuBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let button = app.buttons[action]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "menu action \(action) should appear")
        button.tap()
        handleLocalNetworkPrompt()
    }

    private func openHealthDashboard(in app: XCUIApplication) {
        // U3: the Health dashboard lives on the Activity tab's stack (the
        // Gateways toolbar entry moved with the tab shell).
        UITabNavigation.openActivity(app)
        let health = firstMatch(in: app, identifier: "fleet.activity.health")
        XCTAssertTrue(health.waitForExistence(timeout: 10), "Health toolbar entry should exist")
        health.tap()
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
    private func handleLocalNetworkPrompt(within seconds: TimeInterval = 6) -> Bool {
        let app = XCUIApplication()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            app.tap()
            sleep(1)
        }
        return true
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
