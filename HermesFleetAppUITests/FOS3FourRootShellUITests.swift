import XCTest

/// FOS-3 (t_f770d814) — root-shell regression suite (SPEC §6, §12, §13,
/// Phase 3), updated for the Build 43 five-tab shell:
///   1. exactly five tabs with exact labels; inline titles on all five roots;
///   2. root toolbars: trailing Command Center everywhere; Gateways'
///      cockpit toolbar (Add) reached Fleet → Manage Gateways;
///   3. Settings TAB: own navigation bar (no sheet, no Done), first item is
///      configuration (no brand banner), appearance preference, version;
///   4. Command Center: gateway-object results; owner-tab routing (bots →
///      Bots, gateway resources → Fleet);
///   5. lock dismissal: re-locking closes Command Center;
///   6. retired roots: no Control/Workspace surfaces anywhere, no Gateways
///      tab, no Fleet gear sheet.
final class FOS3FourRootShellUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.shellReady(app, timeout: 15)
        return app
    }

    // MARK: 1. Five exact tabs + inline titles

    func testFiveExactTabsWithInlineTitles() throws {
        let app = launch()

        let tabBar = app.tabBars.firstMatch
        let labels = ["Bots", "Chats", "Scheduled", "Kanban", "Fleet", "Settings"]
        if tabBar.exists {
            for label in labels {
                XCTAssertTrue(tabBar.buttons[label].exists, "tab bar must include \(label)")
            }
            let tabLabels = tabBar.buttons.allElementsBoundByIndex.map { $0.label }
            XCTAssertEqual(tabLabels.count, 6,
                           "the tab bar must expose exactly six destinations (got \(tabLabels))")
            XCTAssertFalse(tabBar.buttons["Gateways"].exists,
                           "Gateways must not be a tab (Build 43: it lives under Fleet)")
        } else if app.buttons["fleet.drawer.open"].exists {
            _ = UITabNavigation.openDrawer(app)
            for raw in ["bots", "chats", "cron", "kanban", "fleet", "settings"] {
                XCTAssertTrue(app.descendants(matching: .any)
                    .matching(identifier: "fleet.drawer.destination.\(raw)").firstMatch.exists)
            }
            app.buttons["fleet.drawer.close"].tap()
        } else {
            // iPad: top control hosts the five primaries; Settings in drawer.
            for label in ["Bots", "Chats", "Scheduled", "Kanban", "Fleet"] {
                XCTAssertTrue(UITabNavigation.tabControl(app, label: label)
                    .waitForExistence(timeout: 10), "sidebar must include \(label)")
            }
            if app.buttons["fleet.drawer.open"].exists {
                _ = UITabNavigation.openDrawer(app)
                XCTAssertTrue(app.descendants(matching: .any)
                    .matching(identifier: "fleet.drawer.destination.settings").firstMatch.exists,
                    "Settings must remain reachable in the drawer on iPad")
                app.buttons["fleet.drawer.close"].tap()
            }
        }

        // Inline navigation titles on all five roots (§6).
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 10))
        UITabNavigation.selectTab(app, label: "Chats")
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        UITabNavigation.selectTab(app, label: "Kanban")
        XCTAssertTrue(app.navigationBars["Kanban"].waitForExistence(timeout: 10))
        UITabNavigation.selectTab(app, label: "Fleet")
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))
        UITabNavigation.selectTab(app, label: "Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    // MARK: 2. Root toolbars (§6)

    func testFleetToolbarHostsCommandCenterAndNoSettingsGear() throws {
        let app = launch()
        UITabNavigation.selectTab(app, label: "Fleet")

        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))
        // Build 43: the leading Settings gear is retired (Settings is a
        // tab; a second presentation would compete with it).
        XCTAssertFalse(app.buttons["fleet.settings.open"].exists,
                       "the Fleet root must NOT expose the retired Settings gear")
        XCTAssertTrue(app.buttons["fleet.command-center.open"].exists,
                      "the Fleet root must expose trailing Command Center")
    }

    func testChatsBotsToolbarActions() throws {
        let app = launch()

        // Chats: Compose entry + Command Center.
        UITabNavigation.selectTab(app, label: "Chats")
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.chats.new"].exists,
                      "Chats must expose its Compose entry")
        XCTAssertTrue(app.buttons["fleet.command-center.open"].exists,
                      "Chats must expose Command Center")

        // Bots: Create/organize menu + Command Center.
        UITabNavigation.selectTab(app, label: "Bots")
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.roster.manage"].waitForExistence(timeout: 10),
                      "Bots must expose its Create/organize menu")
        XCTAssertTrue(app.buttons["fleet.command-center.open"].exists,
                      "Bots must expose Command Center")
    }

    /// Build 43: the Gateways registry cockpit keeps its Add toolbar once
    /// entered via Fleet → Manage Gateways.
    func testGatewaysCockpitReachableFromFleetWithAddToolbar() throws {
        let app = launch()
        UITabNavigation.selectTab(app, label: "Fleet")
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))

        let manage = app.descendants(matching: .any)
            .matching(identifier: "fleet.dashboard.gateways.manage").firstMatch
        if !manage.waitForExistence(timeout: 5) {
            for _ in 0..<8 where !manage.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(manage.waitForExistence(timeout: 10),
                      "Fleet must expose the Manage Gateways entry")
        scrollToHittable(manage, in: app)
        manage.tap()
        XCTAssertTrue(app.navigationBars["Gateways"].waitForExistence(timeout: 10),
                      "Manage Gateways must push the registry cockpit")
        XCTAssertTrue(app.buttons["fleet.gateways.add"].exists,
                      "the registry cockpit must keep its Add toolbar")
        // Back returns to the Fleet root — provenance preserved.
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10),
                      "back from Gateways returns to Fleet")
    }

    // MARK: 3. Settings tab (§12, Build 43)

    func testSettingsTabOwnNavigationBarNoSheet() throws {
        let app = launch()
        UITabNavigation.selectTab(app, label: "Settings")

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "Settings renders as a tab with its own navigation bar")
        XCTAssertFalse(app.buttons["Done"].exists,
                       "the Settings TAB has no sheet Done button")
        XCTAssertFalse(app.buttons["fleet.settings.done"].exists,
                       "the retired sheet Done identifier must not render")

        // First item is useful configuration, not a brand block.
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "fleet.settings.brand").firstMatch.exists,
            "the brand banner must not render in Settings (FOS-3)")
        XCTAssertTrue(app.switches["fleet.settings.app-lock.toggle"].waitForExistence(timeout: 10),
                      "App Lock must lead the Settings tab")

        // The tab identifier is stable for programmatic navigation.
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "fleet.tab.settings").firstMatch.exists,
            "the Settings tab carries fleet.tab.settings")
    }

    // MARK: 4. Command Center (§13)

    func testCommandCenterShowsGatewayObjectsAndRoutesToOwningTabs() throws {
        let app = launch()
        UITabNavigation.selectTab(app, label: "Fleet")
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))

        app.buttons["fleet.command-center.open"].tap()
        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 10))

        // Direct gateway-object result: the scripted Workstation renders as
        // a Gateway row (new in FOS-3). Roster/conversation sections sit
        // above it — scroll into the AX tree first (FOS-2 lazy-AX lesson).
        let gatewayRow = app.descendants(matching: .any)
            .matching(identifier: "fleet.command-center.row.gateway:workstation").firstMatch
        if !gatewayRow.waitForExistence(timeout: 3) {
            for _ in 0..<8 where !gatewayRow.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(gatewayRow.waitForExistence(timeout: 10),
                      "Command Center must list direct gateway-object results")

        // Gateway results route to the Fleet tab (gateway owner since
        // Build 43) + exact destination.
        gatewayRow.tap()
        UITabNavigation.assertSelected(app, label: "Fleet", navigationTitle: "Fleet")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.gateway-detail.workstation").firstMatch
                .waitForExistence(timeout: 10),
            "a gateway result must open that gateway's Detail cockpit"
        )
    }

    func testCommandCenterBotResultRoutesToBotsTab() throws {
        let app = launch()
        UITabNavigation.selectTab(app, label: "Fleet")
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))

        app.buttons["fleet.command-center.open"].tap()
        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 10))

        let botRow = app.descendants(matching: .any)
            .matching(identifier: "fleet.command-center.row.bot:workstation#default").firstMatch
        // Roster rows may sit below the fold — scroll into the AX tree first.
        if !botRow.waitForExistence(timeout: 3) {
            for _ in 0..<6 where !botRow.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(botRow.waitForExistence(timeout: 10),
                      "Command Center must list roster bots with source-qualified ids")
        botRow.tap()

        UITabNavigation.assertSelected(app, label: "Bots", navigationTitle: "Bots")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.bot-detail.header").firstMatch
                .waitForExistence(timeout: 10),
            "a bot result must open that bot's detail on the Bots stack"
        )
    }

    /// Build 43: Command Center's "Go to" list includes the Settings tab
    /// destination and selects it like a tab tap.
    func testCommandCenterGoToSettingsSelectsSettingsTab() throws {
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
        XCTAssertTrue(app.switches["fleet.settings.app-lock.toggle"].waitForExistence(timeout: 10),
                      "the Settings tab must host the App Lock configuration")
    }

    // MARK: 5. Lock dismissal (card acceptance)

    func testRelockDismissesCommandCenter() throws {
        let app = XCUIApplication()
        // `follow` mode: the persisted toggle drives locking (DEBUG default
        // is .disabled, in which the toggle can never relock).
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "follow"
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_LOCK_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // Unlock lands on the Bots root (Build 41+ launch tab).
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 15))

        // Open Command Center, then background the app — the documented
        // relock path (AppLockController.handleScenePhase(.background)
        // re-locks an unlocked app). The lock must tear the sheet down.
        openScreen(app, button: "fleet.command-center.open", navTitle: "Command Center")

        // Deactivate the app (home screen) then reactivate — this drives
        // the real scene-phase .background/.active cycle. With the scripted
        // biometric, .active auto-authenticates and may unlock IMMEDIATELY,
        // so the acceptance is the LOCK'S EFFECT: the Command Center sheet
        // must have been torn down by the relock (it does not come back).
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        // Either the lock screen is showing, or the app already
        // auto-unlocked back to the shell — the sheet must be gone either
        // way, and the shell's Bots root must be reachable.
        let locked = app.buttons["fleet.app-lock.unlock"].waitForExistence(timeout: 10)
        if locked {
            app.buttons["fleet.app-lock.unlock"].tap()
        }
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 15),
                      "the shell must render after the background cycle")
        XCTAssertFalse(app.navigationBars["Command Center"].exists,
                       "Command Center must be dismissed by the lock (FOS-3)")
    }

    // MARK: 6. Retired roots leave no residue

    func testRetiredControlAndWorkspaceRootsAreGone() throws {
        let app = launch()
        UITabNavigation.selectTab(app, label: "Fleet")
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))

        XCTAssertFalse(app.navigationBars["Control"].exists,
                       "the Control root must be retired")
        XCTAssertFalse(app.navigationBars["Workspace"].exists,
                       "the Workspace root must be retired")
        for tab in ["Bots", "Chats", "Scheduled", "Kanban", "Fleet", "Settings"] {
            UITabNavigation.selectTab(app, label: tab)
            XCTAssertFalse(app.descendants(matching: .any)
                .matching(identifier: "fleet.control").firstMatch.exists,
                "no Control surface may render on \(tab)")
            XCTAssertFalse(app.descendants(matching: .any)
                .matching(identifier: "fleet.workspace").firstMatch.exists,
                "no Workspace surface may render on \(tab)")
        }
    }

    // MARK: Helpers — deterministic toggle flips (existence-safe polls)

    /// Open a screen via a toolbar/sheet button, retrying the tap when the
    /// expected navigation bar does not appear. Guards the lock-env cold
    /// launch flake where first paint stalls (AX tree live, screen white)
    /// and the synthesized tap is silently dropped.
    private func openScreen(_ app: XCUIApplication, button identifier: String, navTitle: String) {
        let button = app.buttons[identifier]
        let navBar = app.navigationBars[navTitle]
        XCTAssertTrue(button.waitForExistence(timeout: 10),
                      "\(identifier) must exist to open \(navTitle)")
        for _ in 0..<3 {
            if navBar.exists { return }
            if button.exists { button.tap() }
            if navBar.waitForExistence(timeout: 5) { return }
        }
        XCTFail("\(identifier) tap dropped by launch render stall — \(navTitle) never opened after 3 attempts")
    }

    /// Scroll until an element exists and is hittable (lazy-AX below-fold
    /// rows; the R9 pattern).
    @discardableResult
    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .fast)
        }
        return element
    }

    /// Tap the switch knob until its value reads `to`. The knob-only tap
    /// avoids the row-label pitfall (S3 lesson).
    private func flipSwitch(_ toggle: XCUIElement, to value: String) {
        for _ in 0..<3 {
            if !toggle.exists || (toggle.value as? String) == value { return }
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            settleSwitch(toggle, value: value)
        }
    }

    /// Wait briefly for the value to settle. Existence-safe: a relock may
    /// dismiss the owning surface and remove the switch mid-poll.
    private func settleSwitch(_ toggle: XCUIElement, value: String) {
        for _ in 0..<20 {
            if !toggle.exists || (toggle.value as? String) == value { return }
            usleep(250_000)
        }
    }
}
