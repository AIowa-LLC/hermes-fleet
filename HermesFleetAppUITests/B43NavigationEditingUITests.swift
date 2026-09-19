import XCTest

/// Build 43 (restore bot editing + consolidate navigation) regression suite.
///
/// Proves against the deterministic scripted fleet:
///   1. Five tabs in order Bots / Chats / Kanban / Fleet / Settings; Bots is
///      the launch tab; Gateways is NOT a tab and lives under Fleet.
///   2. Fleet → Manage Gateways pushes the full registry cockpit; gateway
///      management flows remain reachable.
///   3. Settings is a TAB (own nav bar, no sheet Done), reachable through
///      the tab bar, Command Center, and AUTO_NAV.
///   4. Bot Detail ALWAYS exposes Edit: enabled when reachable; disabled
///      with an explanation naming the owning gateway when offline/ghost;
///      reconnection (gateway connect) re-enables it without recreating the
///      bot.
final class B43NavigationEditingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launch and WAIT for the tab shell (hydration + lock gate settle
    /// first; a tap synthesized before the tab bar exists is dropped).
    private func launch(extraEnv: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        for (key, value) in extraEnv { app.launchEnvironment[key] = value }
        app.launch()
        UITabNavigation.shellReady(app, timeout: 20)
        XCTAssertTrue(true,
                      "the tab shell must render after launch")
        return app
    }

    private func firstMatch(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: 1. Tab structure

    func testFiveTabsInOrderBotsFirst() {
        let app = launch()

        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            let labels = tabBar.buttons.allElementsBoundByIndex.map { $0.label }
            XCTAssertEqual(labels, ["Bots", "Chats", "Groups", "Scheduled", "Kanban", "Fleet", "Settings"],
                           "exactly seven destinations in the approved order")
            XCTAssertFalse(tabBar.buttons["Gateways"].exists,
                           "Gateways must not be a tab (Build 43)")
        } else if app.buttons["fleet.drawer.open"].exists {
            _ = UITabNavigation.openDrawer(app)
            for raw in ["bots", "chats", "groups", "cron", "kanban", "fleet", "settings"] {
                XCTAssertTrue(app.descendants(matching: .any)
                    .matching(identifier: "fleet.drawer.destination.\(raw)").firstMatch.exists)
            }
            UITabNavigation.closeDrawer(app)
        } else {
            // iPad: top control hosts the five primaries; Settings in drawer.
            for label in ["Bots", "Chats", "Groups", "Scheduled", "Kanban", "Fleet"] {
                XCTAssertTrue(UITabNavigation.tabControl(app, label: label)
                    .waitForExistence(timeout: 10), "sidebar must include \(label)")
            }
            if app.buttons["fleet.drawer.open"].exists {
                _ = UITabNavigation.openDrawer(app)
                XCTAssertTrue(app.descendants(matching: .any)
                    .matching(identifier: "fleet.drawer.destination.settings").firstMatch.exists,
                    "Settings must remain reachable in the drawer on iPad")
                UITabNavigation.closeDrawer(app)
            }
        }
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 10),
                      "Bots must remain the launch tab")
    }

    func testSettingsTabRendersDirectly() {
        let app = launch()
        UITabNavigation.selectTab(app, label: "Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "Settings must render as a tab with its own nav bar")
        XCTAssertFalse(app.buttons["fleet.settings.done"].exists,
                       "no sheet Done button may render")
        // ADR-0011: the App Lock toggle moved into the Security
        // sub-screen (the root leads with Theme + App settings chevrons).
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "fleet.settings.security").firstMatch.waitForExistence(timeout: 10),
            "the Security chevron row must render on the Settings root")
        XCTAssertTrue(firstMatch(app, "fleet.tab.settings").waitForExistence(timeout: 10),
                      "the Settings tab carries its dedicated identifier")
    }

    func testCommandCenterGoToSettingsSelectsTab() {
        let app = launch()
        UITabNavigation.selectTab(app, label: "Fleet")
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))
        app.buttons["fleet.command-center.open"].tap()
        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 10))

        // Scope to the sheet's own Go-to row (the tab bar sits BEHIND the
        // presented sheet — a bare "Settings" query is ambiguous).
        let settings = app.buttons["fleet.command-center.goto.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10),
                      "Command Center's Go-to list must include Settings")
        settings.tap()
        UITabNavigation.assertSelected(app, label: "Settings", navigationTitle: "Settings")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "fleet.settings.security").firstMatch.waitForExistence(timeout: 10),
            "the Settings root must expose the Security row (App Lock lives in its sub-screen)")
    }

    func testAutoNavSettingsSelectsTab() {
        let app = launch(extraEnv: ["HERMES_FLEET_AUTO_NAV": "settings"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15),
                      "AUTO_NAV=settings must select the Settings tab")
        UITabNavigation.assertSelected(app, label: "Settings", navigationTitle: "Settings")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "fleet.settings.security").firstMatch.waitForExistence(timeout: 10),
            "the Settings root must expose the Security row (App Lock lives in its sub-screen)")
    }

    // MARK: 2. Fleet → Gateways consolidation

    func testFleetHostsManageGatewaysEntryAndRegistry() {
        let app = launch()
        UITabNavigation.selectTab(app, label: "Fleet")
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))

        let manage = firstMatch(app, "fleet.dashboard.gateways.manage")
        if !manage.waitForExistence(timeout: 5) {
            for _ in 0..<8 where !manage.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(manage.waitForExistence(timeout: 10),
                      "Fleet must expose the Manage Gateways entry")
        scrollToHittable(manage, app)
        manage.tap()
        XCTAssertTrue(app.navigationBars["Gateways"].waitForExistence(timeout: 10),
                      "Manage Gateways must push the registry cockpit")
        XCTAssertTrue(firstMatch(app, "fleet.gateways.add").waitForExistence(timeout: 10),
                      "the registry cockpit keeps Add (full management preserved)")
        // A gateway row still opens its Detail cockpit.
        let row = firstMatch(app, "fleet.gateways.row.workstation")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(firstMatch(app, "fleet.gateway-detail.workstation").waitForExistence(timeout: 10),
                      "gateway detail remains reachable from the registry")
    }

    // MARK: 3. Bot editing availability (Fix A)

    /// Open the workstation#default Bot Detail and switch to its
    /// Configuration segment (the management actions live there; the screen
    /// opens on Conversations). Scrolls the row into the AX tree first
    /// (lazy rows / ghost rows sit below the fold — the R9 pattern).
    private func openBotDetailConfiguration(_ app: XCUIApplication, profile: String = "default") {
        let row = firstMatch(app, "fleet.roster.row.workstation#\(profile)")
        if !row.waitForExistence(timeout: 5) {
            for _ in 0..<6 where !row.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "the roster should list workstation#\(profile)")
        scrollToHittable(row, app)
        row.tap()
        XCTAssertTrue(firstMatch(app, "fleet.bot-detail.header").waitForExistence(timeout: 10),
                      "bot detail should render")
        let segment = app.segmentedControls["fleet.bot-detail.segment"]
        XCTAssertTrue(segment.waitForExistence(timeout: 10),
                      "the detail's segmented control must render")
        segment.buttons["Configuration"].tap()
        app.swipeUp(velocity: .fast)
        app.swipeUp(velocity: .fast)
    }

    /// Open the registry cockpit (Fleet → Manage Gateways). Tolerates the
    /// registry ALREADY being pushed on the Fleet stack (the tab preserves
    /// its navigation state — a previous visit leaves Gateways on top).
    private func openRegistryCockpit(_ app: XCUIApplication) {
        UITabNavigation.selectTab(app, label: "Fleet")
        // Either the Fleet root (push below) or the preserved Gateways
        // cockpit (nothing to do) is acceptable.
        if app.navigationBars["Gateways"].waitForExistence(timeout: 5) { return }
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))
        let manage = firstMatch(app, "fleet.dashboard.gateways.manage")
        if !manage.waitForExistence(timeout: 5) {
            for _ in 0..<8 where !manage.exists { app.swipeUp(velocity: .fast) }
        }
        scrollToHittable(manage, app)
        manage.tap()
        XCTAssertTrue(app.navigationBars["Gateways"].waitForExistence(timeout: 10))
    }

    /// Tap an action in the workstation gateway's registry row menu.
    private func workstationRowMenuAction(_ app: XCUIApplication, _ title: String) {
        let menu = firstMatch(app, "fleet.gateways.row.workstation.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 10),
                      "the workstation row menu must exist in the registry")
        scrollToHittable(menu, app)
        menu.tap()
        let action = app.buttons[title]
        XCTAssertTrue(action.waitForExistence(timeout: 5),
                      "the row menu must expose \(title)")
        action.tap()
    }

    /// HERMES_FLEET_ROSTER_BLIP=1 journey, outage phase. The app must first
    /// OWN an active connection for the workstation gateway (Disconnect only
    /// tears down a LIVE connection — at launch the roster refreshes through
    /// its own session objects, so no active connection exists), so: gateway
    /// Detail → Connect, then row menu → Disconnect (real teardown path),
    /// then a roster Refresh fails and the outage section renders with
    /// LAST-KNOWN ghost rows — exactly like a real gateway drop.
    private func enterBlipOutage(_ app: XCUIApplication) {
        openRegistryCockpit(app)
        let gwRow = firstMatch(app, "fleet.gateways.row.workstation")
        XCTAssertTrue(gwRow.waitForExistence(timeout: 10))
        gwRow.tap()
        let connect = firstMatch(app, "fleet.gateway-detail.connect.workstation")
        XCTAssertTrue(connect.waitForExistence(timeout: 10),
                      "the gateway cockpit must expose Connect")
        connect.tap()
        // Let the connection land before tearing it down.
        sleep(2)
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Gateways"].waitForExistence(timeout: 10))
        workstationRowMenuAction(app, "Disconnect")

        // Back on Bots, refresh the roster — the fetch fails and the
        // outage + cached ghost rows render.
        UITabNavigation.selectTab(app, label: "Bots")
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 10))
        let refresh = app.buttons["fleet.roster.refresh"]
        scrollToHittable(refresh, app)
        refresh.tap()
        let outage = firstMatch(app, "fleet.roster.outage.workstation")
        XCTAssertTrue(outage.waitForExistence(timeout: 15),
                      "the post-disconnect refresh must render the workstation outage section")
        let ghost = firstMatch(app, "fleet.roster.row.workstation#default")
        if !ghost.waitForExistence(timeout: 5) {
            for _ in 0..<6 where !ghost.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(ghost.waitForExistence(timeout: 10),
                      "the outage section must list the CACHED last-known bot rows")
    }

    func testReachableBotExposesEnabledEdit() {
        let app = launch()
        openBotDetailConfiguration(app)
        let edit = app.buttons["fleet.bot-detail.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10),
                      "a reachable bot must expose the Edit action")
        XCTAssertFalse(firstMatch(app, "fleet.bot-detail.writes-offline").exists,
                       "no offline explanation may render while reachable")
        // Opens the EXISTING editor (Save + editable fields) — no duplicate UI.
        edit.tap()
        XCTAssertTrue(firstMatch(app, "fleet.bot.edit.submit").waitForExistence(timeout: 10),
                      "Edit must open the existing editor sheet")
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5),
                      "the editor's title field must render")
        app.buttons["Cancel"].firstMatch.tap()
    }

    func testOfflineBotKeepsDiscoverableDisabledEdit() {
        // Healthy launch → user Disconnect → outage with cached ghost rows.
        let app = launch(extraEnv: ["HERMES_FLEET_ROSTER_BLIP": "1"])
        enterBlipOutage(app)
        openBotDetailConfiguration(app)

        let edit = app.buttons["fleet.bot-detail.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10),
                      "an offline bot must KEEP a discoverable Edit control")
        let caption = firstMatch(app, "fleet.bot-detail.writes-offline")
        XCTAssertTrue(caption.waitForExistence(timeout: 10),
                      "the offline explanation must render")
        XCTAssertTrue(caption.label.contains("Workstation"),
                      "the explanation must name the owning gateway (got: \(caption.label))")
        XCTAssertFalse(edit.isEnabled,
                       "Edit must be disabled while the owning gateway is unreachable")
    }

    func testReconnectionRestoresEditingWithoutRecreatingBot() {
        // Outage phase → editing disabled; heal through the REAL path
        // (workstation gateway Connect, which triggers the post-connect
        // roster sync) and verify Edit re-enables for the SAME bot — no
        // recreation, no rerouting.
        let app = launch(extraEnv: ["HERMES_FLEET_ROSTER_BLIP": "1"])
        enterBlipOutage(app)
        openBotDetailConfiguration(app)
        let edit = app.buttons["fleet.bot-detail.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertFalse(edit.isEnabled, "Edit starts disabled during the outage")

        // Heal: connect the workstation gateway through its Detail cockpit.
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        openRegistryCockpit(app)
        let gwRow = firstMatch(app, "fleet.gateways.row.workstation")
        XCTAssertTrue(gwRow.waitForExistence(timeout: 10))
        gwRow.tap()
        let connect = firstMatch(app, "fleet.gateway-detail.connect.workstation")
        XCTAssertTrue(connect.waitForExistence(timeout: 10),
                      "the gateway cockpit must expose Connect")
        connect.tap()

        // Back to the SAME bot's detail — Edit must now be enabled (the
        // post-connect roster sync is async; poll for enablement).
        UITabNavigation.selectTab(app, label: "Bots")
        openBotDetailConfiguration(app)
        let healed = app.buttons["fleet.bot-detail.edit"]
        XCTAssertTrue(healed.waitForExistence(timeout: 10))
        var enabled = false
        for _ in 0..<50 where !(healed.exists && healed.isEnabled) {
            usleep(500_000)
        }
        if healed.exists && healed.isEnabled { enabled = true }
        XCTAssertTrue(enabled,
                      "Edit must re-enable after the gateway reconnects — without recreating the bot")
        XCTAssertFalse(firstMatch(app, "fleet.bot-detail.writes-offline").exists,
                       "the offline explanation must clear after reconnection")
    }

    // MARK: helpers

    @discardableResult
    private func scrollToHittable(_ element: XCUIElement, _ app: XCUIApplication) -> XCUIElement {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .fast)
        }
        return element
    }
}
