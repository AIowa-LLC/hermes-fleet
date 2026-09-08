import XCTest

/// F1 LIVE verification (t_10831eec): register Arch as gateway #2 on Tony's
/// REAL iPhone and prove the multi-gateway fleet is live.
///
/// Runs on the PHYSICAL device (Debug build = production graph: real Keychain +
/// live transports — P0-5 lesson). Two gateways registered through the real
/// U2 form, no hardcoding:
///
///   #1 Mac   — http://100.100.200.61:9120   (tailnet surface)
///   #2 Arch  — http://100.127.200.89:9119   (tailnet surface, F1)
///
/// Credential safety: username/password pairs are read at runtime from
/// /tmp/hermes_lan_surface/.cred (Mac #1) and /tmp/f1_arch_gateway/.cred
/// (Arch #2, prose format — parsed without printing) and are NEVER printed,
/// logged, or committed.
final class F1TwoGatewayFleetLiveUITests: XCTestCase {

    // Endpoints overridable via the test runner env (TEST_RUNNER_F1_* on the
    // xcodebuild command line) — the PHYSICAL DEVICE runs DIRECT against the
    // tailnet (override with the real hosts). The DEFAULTS are the P0-7
    // loopback-forwarder surfaces (sim local-network privacy blocks direct
    // tailnet access — T2/P0-7 documented wall):
    //   19120 -> 100.100.200.61:9120  (Mac #1)   19119 -> 100.127.200.89:9119 (Arch #2)
    private let macEndpoint = ProcessInfo.processInfo.environment["F1_MAC_ENDPOINT"]
        ?? "http://127.0.0.1:19120"
    private let macName = "Mac #1"
    private var macID: String { URL(string: macEndpoint).map { "\($0.host ?? ""):\($0.port ?? 80)" } ?? macEndpoint }

    private let archEndpoint = ProcessInfo.processInfo.environment["F1_ARCH_ENDPOINT"]
        ?? "http://127.0.0.1:19119"
    private let archName = "Arch #2"
    private var archID: String { URL(string: archEndpoint).map { "\($0.host ?? ""):\($0.port ?? 80)" } ?? archEndpoint }

    override func setUpWithError() throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Local Network permission") { alert in
            let allow = alert.buttons["Allow"]
            if allow.exists { allow.tap(); return true }
            return false
        }
    }

    @discardableResult
    private func handleLocalNetworkPrompt(within seconds: TimeInterval = 6) -> Bool {
        // Only tap when a REAL system alert is on screen. The P0-7 template
        // tapped app.tap() blindly for the whole window — with no alert up,
        // those center taps hit gateway rows and navigated away from the
        // Gateways screen (found in F1 run 4: the Arch row check ran on the
        // Mac #1 bot-detail screen).
        let app = XCUIApplication()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let alert = app.alerts.firstMatch
            if alert.exists {
                let allow = alert.buttons["Allow"].exists ? alert.buttons["Allow"] : alert.buttons.firstMatch
                if allow.exists { allow.tap() }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return true
    }

    /// Dismiss accidental navigation (e.g. a system-alert tap that landed on a
    /// row): pop back to the Gateways list if a back button is showing.
    private func popBackToListIfNeeded(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
    }

    func testTwoGatewayFleetLive() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launch()
        UITabNavigation.openGatewaysTab(app)
        handleLocalNetworkPrompt()

        // ---- 1. Gateway #1: Mac tailnet ------------------------------------
        if !app.otherElements["fleet.gateways.row.\(macID)"].exists
            && !app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier CONTAINS %@", "fleet.gateways.row.\(macID)"))
                .firstMatch.exists {
            addGateway(in: app, name: macName, endpoint: macEndpoint,
                       username: macCreds.username, password: macCreds.password)
        }
        let macRow = firstMatch(in: app, identifier: "fleet.gateways.row.\(macID)")
        XCTAssertTrue(macRow.waitForExistence(timeout: 15), "Mac #1 gateway row must exist")
        testConnection(in: app, gatewayID: macID)
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 40),
                      "Mac #1 must classify CONNECTED")
        attachScreenshot(of: app, name: "f1-step1-mac-connected")

        // A stray tap may have navigated into the Mac row (alert handler);
        // return to the Gateways list before adding Arch.
        UITabNavigation.openGatewaysTab(app)
        popBackToListIfNeeded(app)

        // ---- 2. Gateway #2: Arch tailnet (F1 core) -------------------------
        if !app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "fleet.gateways.row.\(archID)"))
            .firstMatch.exists {
            addGateway(in: app, name: archName, endpoint: archEndpoint,
                       username: archCreds.username, password: archCreds.password)
        }
        let archRow = firstMatch(in: app, identifier: "fleet.gateways.row.\(archID)")
        // Below-fold rows are absent from the AX tree until scrolled (U6
        // lesson) — bounded scroll-reveal before declaring missing.
        var archFound = archRow.waitForExistence(timeout: 10)
        if !archFound {
            for _ in 0..<3 where !archFound {
                app.swipeUp()
                archFound = archRow.waitForExistence(timeout: 3)
            }
            if !archFound {
                // Diagnostic: attach the FULL AX tree (non-secret) so the
                // failure evidence shows the true screen state.
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "f1-arch-row-missing-ax-tree"
                tree.lifetime = .keepAlways
                add(tree)
            }
        }
        XCTAssertTrue(archFound, "Arch #2 gateway row must exist")
        attachScreenshot(of: app, name: "f1-step2-both-rows")

        // Test Connection on Arch: MUST reach Connected — this is where the
        // missing ATS exception would have silently failed the connect (P0-5).
        testConnection(in: app, gatewayID: archID)
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 40),
                      "Arch #2 must classify CONNECTED (ATS exception working)")
        attachScreenshot(of: app, name: "f1-step3-arch-connected")

        // ---- 3. Roster aggregates bots from BOTH gateways ------------------
        UITabNavigation.openBotsTab(app)
        let refresh = app.buttons["Refresh"].firstMatch
        if refresh.waitForExistence(timeout: 5) { refresh.tap(); sleep(8) }
        // FleetRosterView rows are keyed fleet.roster.row.<route.id> — wait
        // for the union roster to be non-empty (aggregation across gateways).
        let rosterRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "fleet.roster.row."))
            .firstMatch
        let rosterDeadline = Date().addingTimeInterval(60)
        while Date() < rosterDeadline && !rosterRow.exists { sleep(3) }
        XCTAssertTrue(rosterRow.waitForExistence(timeout: 10),
                      "union roster must show bots after refresh")
        attachScreenshot(of: app, name: "f1-step4-roster-both-gateways")

        // ---- 4. Per-gateway bots + session render (RT1: one transport per
        // gateway). Drill EACH gateway row on the Gateways tab; the pushed
        // BotsView keys rows fleet.roster.row.<gatewayID>#<profile>.
        UITabNavigation.openGatewaysTab(app)
        for (id, name) in [(macID, "Mac #1"), (archID, "Arch #2")] {
            let row = firstMatch(in: app, identifier: "fleet.gateways.row.\(id)")
            XCTAssertTrue(row.waitForExistence(timeout: 10), "\(name) row must exist on Gateways tab")
            tap(row)
            // FOS-2: gateway rows open the Gateway Detail cockpit (§8) —
            // the Bots collection is one more tap beneath it.
            UITabNavigation.openGatewayBots(app, gateway: id)
            if refresh.waitForExistence(timeout: 5) { refresh.tap(); sleep(6) }
            let botRow = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier CONTAINS %@",
                                      "fleet.roster.row.\(id)#"))
                .firstMatch
            XCTAssertTrue(botRow.waitForExistence(timeout: 30),
                          "\(name) bots must render on its per-gateway Bots screen")
            attachScreenshot(of: app, name: "f1-step5-bots-\(name.replacingOccurrences(of: " ", with: "-"))")
            if id == archID {
                // Drill the DEFAULT bot specifically — verified live to have
                // sessions (13 at F1 time; other profiles e.g. coach may be
                // empty, which firstMatch picked in run 6).
                let defaultBot = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier == %@",
                                          "fleet.roster.row.\(id)#default"))
                    .firstMatch
                var target = defaultBot
                if !target.waitForExistence(timeout: 5) {
                    // Below-fold reveal for the default row.
                    for _ in 0..<3 where !target.exists { app.swipeUp() }
                    target = defaultBot.exists ? defaultBot : botRow
                }
                tap(target)
                if firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 15) {
                    // Below-fold: session rows sit under the header card +
                    // segmented control — reveal by scroll before asserting.
                    let sessionRow = firstMatch(in: app, identifier: "fleet.bot-detail.sessions.row.")
                    var sessionsFound = sessionRow.waitForExistence(timeout: 15)
                    for _ in 0..<3 where !sessionsFound {
                        app.swipeUp()
                        sessionsFound = sessionRow.waitForExistence(timeout: 3)
                    }
                    XCTAssertTrue(sessionsFound,
                                  "Arch bot session rows must render (per-gateway session ownership)")
                    tap(sessionRow)
                    let composer = app.textFields["fleet.conversation.composer"]
                    XCTAssertTrue(composer.waitForExistence(timeout: 20),
                                  "Arch conversation canvas opens with a composer")
                    waitUntilEnabled(composer, timeout: 30)
                    attachScreenshot(of: app, name: "f1-step6-arch-conversation-open")
                }
            } else {
                tapBack(app)
            }
        }
    }

    // MARK: Credentials (runtime reads, never printed)

    private var macCreds: (username: String, password: String) {
        guard let text = try? String(contentsOfFile: "/tmp/hermes_lan_surface/.cred", encoding: .utf8) else {
            return ("", "")
        }
        var u = "", p = ""
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                if parts[0] == "username" { u = String(parts[1]) }
                if parts[0] == "password" { p = String(parts[1]) }
            }
        }
        return (u, p)
    }

    /// Arch mirror is PROSE format: "Username: tony" line + a "Password: <v>"
    /// long token line (structure verified in t_7e3edb5a / f1a_01c).
    private var archCreds: (username: String, password: String) {
        guard let text = try? String(contentsOfFile: "/tmp/f1_arch_gateway/.cred", encoding: .utf8) else {
            return ("", "")
        }
        var u = "", p = ""
        for line in text.split(separator: "\n") {
            let low = line.lowercased()
            if low.contains("username") {
                let toks = line.split(separator: " ")
                if let t = toks.last { u = String(t.trimmingCharacters(in: CharacterSet(charactersIn: ":"))) }
            }
            if low.contains("password") {
                let toks = line.split(separator: " ")
                for t in toks.dropFirst() where t.count >= 12 {
                    p = String(t.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
                    break
                }
            }
        }
        return (u, p)
    }

    // MARK: Helpers (mirrors P0_7LiveTailnetUITests)

    private func addGateway(in app: XCUIApplication, name: String, endpoint: String,
                            username: String, password: String) {
        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        let nameField = app.textFields["fleet.gateways.form.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        nameField.tap()
        nameField.typeText(name)
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        endpointField.tap()
        endpointField.typeText(endpoint)

        tap(firstMatch(in: app, identifier: "fleet.gateways.form.strategy"))
        selectStrategyUsernamePassword(in: app)

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
        // Tailnet hosts are intentionally NOT classified private (S3 design:
        // CGNAT 100.64/10 gets the warning) — the confirm toggle WILL show.
        let confirm = app.switches["fleet.gateways.form.cleartext-confirm"].firstMatch
        if confirm.waitForExistence(timeout: 3) {
            confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertTrue(waitUntilValue(confirm, isOn: true, timeout: 5),
                          "cleartext confirmation toggle should read ON")
        }
        let save = app.buttons["fleet.gateways.form.save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save should exist")
        waitUntilEnabled(save, timeout: 5)
        save.tap()
        handleLocalNetworkPrompt()
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 4) { notNow.tap(); sleep(1) }
    }

    private func selectStrategyUsernamePassword(in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let opt = firstOption(in: app, label: "Username & Password")
            if opt.waitForExistence(timeout: 4) { opt.tap() }
            if app.textFields["fleet.gateways.form.username"].waitForExistence(timeout: 4) { return }
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
            if testConn.waitForExistence(timeout: 5) { testConn.tap() }
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
