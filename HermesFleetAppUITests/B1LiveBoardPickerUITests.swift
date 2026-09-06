import XCTest

/// B1 QA (t_a0ca4856) — INDEPENDENT live verification of the board selector
/// on Tony's physical iPhone (build 22, Debug) against the REAL gateway over
/// WiFi (LAN surface). Device-only: the scripted simulator fleet is excluded
/// by targeting this suite explicitly on the physical device.
///
/// Acceptance surface (from the B1 card, re-derived by QA):
///   1. Toolbar picker (fleet.kanban.board.picker) lists the gateway's REAL
///      boards (GET /boards) with the operator's active board displayed.
///   2. Switching re-targets the SNAPSHOT (visibly different board content).
///   3. The re-opened WS stream goes live on the new board.
///   4. Selection persists across relaunch (per-device UserDefaults).
///   5. Switching back to the active board restores the original content.
///   6. Read-only discipline: no mutating controls on the board.
/// (Orchestrator active-board pointer invariance is asserted host-side by
///  the QA runner script around this test — it is a MAC-side file.)
///
/// Credential safety: username/password are read at runtime from
/// /tmp/hermes_lan_surface/.cred (0600) and NEVER printed or committed.
final class B1LiveBoardPickerUITests: XCTestCase {

    private let endpoint = "http://192.168.50.37:9120"
    private let gatewayID = "192.168.50.37:9120"
    private let gwName = "B1 QA LAN"

    // Real board names on the live gateway (verified via GET /boards).
    private let activeBoardName = "Hermes Fleet R10"          // is_current=true
    private let otherBoardName = "Hermes Fleet for iOS"       // empty board
    private let activeBoardCard = "B1 board selector"         // distinctive substring of a live R10 card

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

    private func handleLocalNetworkPrompt(within seconds: TimeInterval = 6) -> Bool {
        let app = XCUIApplication()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            app.tap()
            sleep(1)
        }
        return true
    }

    func testLivePickerSwitchPersistenceRoundTrip() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launch()

        // ---- 1. Register + connect the live LAN gateway -------------------
        UITabNavigation.openGatewaysTab(app)
        handleLocalNetworkPrompt()
        addGateway(in: app, name: gwName, endpoint: endpoint)
        XCTAssertTrue(
            app.staticTexts["Connected"].waitForExistence(timeout: 45),
            "live LAN gateway must classify CONNECTED over WiFi")
        attachScreenshot(of: app, name: "b1-step1-gateway-connected")

        // ---- 2. Board renders with the picker showing the ACTIVE board ----
        openKanbanFromHome(app)
        let picker = firstMatch(in: app, identifier: "fleet.kanban.board.picker")
        XCTAssertTrue(
            picker.waitForExistence(timeout: 30),
            "the board picker must render once the live boards list loads")
        let activeNamed = NSPredicate(format: "label CONTAINS %@", activeBoardName)
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(predicate: activeNamed, object: picker)],
                timeout: 20),
            .completed,
            "unselected picker must show the OPERATOR's active board (got: \(picker.label))")

        // Active board's real content renders (the B1 card itself).
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", activeBoardCard))
                .firstMatch.waitForExistence(timeout: 30),
            "the live active board must render its real cards")
        XCTAssertFalse(app.buttons["Add Card"].exists, "board must stay read-only")
        attachScreenshot(of: app, name: "b1-step2-active-board-live")

        // ---- 3. Switch boards: snapshot re-targets -------------------------
        picker.tap()
        let other = app.buttons[otherBoardName].firstMatch
        XCTAssertTrue(
            other.waitForExistence(timeout: 10),
            "picker menu must list the gateway's real boards (looking for \(otherBoardName))")
        other.tap()
        let switched = NSPredicate(format: "label CONTAINS %@", otherBoardName)
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(predicate: switched, object: picker)],
                timeout: 20),
            .completed,
            "picker must show the newly selected board's name (got: \(picker.label))")

        // The new board's snapshot: hermes-fleet-ios is EMPTY of live cards —
        // the honest empty state must render (old board's cards are GONE).
        XCTAssertTrue(
            app.staticTexts["No cards on this board yet."].waitForExistence(timeout: 25),
            "switching must re-target the snapshot (empty board shows empty state, not the old board's cards)")
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", activeBoardCard))
                .firstMatch.exists,
            "the previous board's card must not render after the switch")
        attachScreenshot(of: app, name: "b1-step3-switched-empty-board")

        // ---- 4. The re-opened WS stream goes live on the new board --------
        let banner = firstMatch(in: app, identifier: "kanban.board.streamBanner")
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "stream banner must render")
        let live = NSPredicate(format: "label CONTAINS %@", "live")
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(predicate: live, object: banner)],
                timeout: 30),
            .completed,
            "the re-opened event stream must reach Live on the new board (got: \(banner.label))")
        attachScreenshot(of: app, name: "b1-step4-stream-live-on-new-board")

        // ---- 5. Selection survives relaunch (per-device persistence) ------
        app.terminate()
        app.launch()
        openKanbanFromHome(app)
        let picker2 = firstMatch(in: app, identifier: "fleet.kanban.board.picker")
        XCTAssertTrue(picker2.waitForExistence(timeout: 30), "picker must render after relaunch")
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(predicate: switched, object: picker2)],
                timeout: 20),
            .completed,
            "selected board must survive relaunch (got: \(picker2.label))")
        XCTAssertTrue(
            app.staticTexts["No cards on this board yet."].waitForExistence(timeout: 25),
            "relaunched board must load the persisted board's snapshot")
        attachScreenshot(of: app, name: "b1-step5-relaunch-persisted")

        // ---- 6. Switch back to the active board: content restores ---------
        picker2.tap()
        let activeBtn = app.buttons[activeBoardName].firstMatch
        XCTAssertTrue(activeBtn.waitForExistence(timeout: 10), "active board must be listed")
        activeBtn.tap()
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(predicate: activeNamed, object: picker2)],
                timeout: 20),
            .completed,
            "picker must return to the active board (got: \(picker2.label))")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", activeBoardCard))
                .firstMatch.waitForExistence(timeout: 30),
            "switching back must restore the active board's real cards")
        attachScreenshot(of: app, name: "b1-step6-switched-back-active")

        // ---- 7. Cleanup: remove the QA gateway from Tony's phone ----------
        removeGateway(app)
        attachScreenshot(of: app, name: "b1-step7-gateway-removed")
    }

    // MARK: Helpers

    private func openKanbanFromHome(_ app: XCUIApplication) {
        let homeTab = app.tabBars.firstMatch.buttons["Command"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 15), "Command (Home) tab must exist")
        if !homeTab.isSelected {
            homeTab.tap()
        }
        let entry = firstMatch(in: app, identifier: "fleet.dashboard.kanban.entry")
        XCTAssertTrue(
            entry.waitForExistence(timeout: 20),
            "Kanban entry must render on Home once a live gateway is registered")
        entry.tap()
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
        // S3 cleartext gate: LAN endpoint is not loopback — confirm cleartext.
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

    private func removeGateway(_ app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        let row = firstMatch(in: app, identifier: "fleet.gateways.row.\(gatewayID)")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "gateway row must exist for cleanup")
        row.swipeLeft()
        let remove = firstMatch(in: app, identifier: "fleet.gateways.row.\(gatewayID).remove")
        if remove.waitForExistence(timeout: 5) {
            remove.tap()
            let confirm = firstMatch(in: app, identifier: "fleet.gateways.remove.confirm")
            XCTAssertTrue(confirm.waitForExistence(timeout: 8), "removal confirmation must appear")
            confirm.tap()
        } else {
            row.swipeLeft(velocity: .fast)
            XCTAssertTrue(remove.waitForExistence(timeout: 5), "swipe must reveal Remove")
            remove.tap()
            let confirm = firstMatch(in: app, identifier: "fleet.gateways.remove.confirm")
            XCTAssertTrue(confirm.waitForExistence(timeout: 8), "removal confirmation must appear")
            confirm.tap()
        }
        XCTAssertFalse(
            row.waitForNonExistence(timeout: 15),
            "gateway row must disappear after confirmed removal")
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

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    /// Inverse of waitForExistence: waits for the element to disappear.
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && exists {
            Thread.sleep(forTimeInterval: 0.3)
        }
        return !exists
    }
}
