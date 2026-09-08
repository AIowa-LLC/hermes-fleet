import XCTest

/// FOS-3 (t_f770d814) — four-root shell regression suite (SPEC §6, §12, §13,
/// Phase 3). Proves against the deterministic scripted fleet:
///   1. exactly four tabs with exact labels; inline titles on all four roots;
///   2. root toolbars: Fleet leading Settings + trailing Command Center;
///      Chats Compose; Bots Create/organize; Gateways Add + Command Center;
///   3. Settings sheet: own stack + Done, first item is configuration (no
///      brand banner), appearance preference, version;
///   4. Command Center: gateway-object results; owner-tab routing (bots →
///      Bots, gateway resources → Gateways); Settings entry;
///   5. lock dismissal: re-locking closes the Settings sheet and Command
///      Center (card acceptance: lock/search dismissal tests);
///   6. retired roots: no Control/Workspace surfaces anywhere.
final class FOS3FourRootShellUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        return app
    }

    // MARK: 1. Four exact tabs + inline titles

    func testFourExactTabsWithInlineTitles() throws {
        let app = launch()

        let tabBar = app.tabBars.firstMatch
        let labels = ["Fleet", "Chats", "Bots", "Gateways"]
        for label in labels {
            XCTAssertTrue(tabBar.buttons[label].exists, "tab bar must include \(label)")
        }
        // EXACTLY four tabs (Control/Workspace retired).
        let tabLabels = tabBar.buttons.allElementsBoundByIndex.map { $0.label }
        XCTAssertEqual(tabLabels.count, 4,
                       "the tab bar must expose exactly four tabs (got \(tabLabels))")

        // Inline navigation titles on all four roots (§6).
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Chats"].tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Bots"].tap()
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Gateways"].tap()
        XCTAssertTrue(app.navigationBars["Gateways"].waitForExistence(timeout: 10))
    }

    // MARK: 2. Root toolbars (§6)

    func testFleetToolbarHostsSettingsLeadingAndCommandCenterTrailing() throws {
        let app = launch()

        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.settings.open"].waitForExistence(timeout: 10),
                      "the Fleet root must expose the leading Settings gear")
        XCTAssertTrue(app.buttons["fleet.command-center.open"].exists,
                      "the Fleet root must expose trailing Command Center")
    }

    func testChatsBotsGatewaysToolbarActions() throws {
        let app = launch()

        // Chats: Compose entry + Command Center.
        app.tabBars.buttons["Chats"].tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.chats.new"].exists,
                      "Chats must expose its Compose entry")
        XCTAssertTrue(app.buttons["fleet.command-center.open"].exists,
                      "Chats must expose Command Center")

        // Bots: Create/organize menu + Command Center.
        app.tabBars.buttons["Bots"].tap()
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.roster.manage"].waitForExistence(timeout: 10),
                      "Bots must expose its Create/organize menu")
        XCTAssertTrue(app.buttons["fleet.command-center.open"].exists,
                      "Bots must expose Command Center")

        // Gateways: Add + Command Center.
        app.tabBars.buttons["Gateways"].tap()
        XCTAssertTrue(app.navigationBars["Gateways"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.gateways.add"].exists,
                      "Gateways must expose Add")
        XCTAssertTrue(app.buttons["fleet.command-center.open"].exists,
                      "Gateways must expose Command Center")
    }

    // MARK: 3. Settings sheet (§12)

    func testSettingsSheetOwnStackAndDone() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))

        app.buttons["fleet.settings.open"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "Settings renders in a sheet with its own navigation stack")
        XCTAssertTrue(app.buttons["Done"].exists, "the Settings sheet must expose Done")

        // First item is useful configuration, not a brand block.
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "fleet.settings.brand").firstMatch.exists,
            "the brand banner must not render in Settings (FOS-3)")
        XCTAssertTrue(app.switches["fleet.settings.app-lock.toggle"].waitForExistence(timeout: 10),
                      "App Lock must lead the Settings sheet")

        // Done dismisses back to the Fleet root.
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10),
                      "Done must dismiss the Settings sheet")
    }

    // MARK: 4. Command Center (§13)

    func testCommandCenterShowsGatewayObjectsAndRoutesToOwningTabs() throws {
        let app = launch()
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

        // Gateway results route to the OWNING Gateways tab + exact destination.
        gatewayRow.tap()
        XCTAssertTrue(app.tabBars.buttons["Gateways"].isSelected,
                      "a gateway result must select the Gateways tab")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.gateway-detail.workstation").firstMatch
                .waitForExistence(timeout: 10),
            "a gateway result must open that gateway's Detail cockpit"
        )
    }

    func testCommandCenterBotResultRoutesToBotsTab() throws {
        let app = launch()
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

        XCTAssertTrue(app.tabBars.buttons["Bots"].isSelected,
                      "a bot result must select the OWNING Bots tab")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.bot-detail.header").firstMatch
                .waitForExistence(timeout: 10),
            "a bot result must open that bot's detail on the Bots stack"
        )
    }

    func testCommandCenterSettingsEntryOpensSheet() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))

        app.buttons["fleet.command-center.open"].tap()
        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 10))

        let settings = app.buttons["fleet.command-center.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10),
                      "Command Center must expose a Settings entry (§12)")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "the Settings entry must open the app-level sheet")
    }

    // MARK: 5. Lock dismissal (card acceptance)

    func testRelockDismissesSettingsSheetAndCommandCenter() throws {
        let app = XCUIApplication()
        // `follow` mode: the persisted toggle drives locking (DEBUG default
        // is .disabled, in which the toggle can never relock).
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "follow"
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_LOCK_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // Unlock lands on the Fleet root.
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 15))

        // Open Settings. The toggle defaults ON: turn it OFF first, then ON —
        // `setEnabled(true)` on an unlocked controller relocks IMMEDIATELY
        // (AppLockController), which must tear down the presented sheet.
        app.buttons["fleet.settings.open"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let toggle = app.switches["fleet.settings.app-lock.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1", "App Lock defaults ON")
        // OFF first (verified — a dropped tap must not cascade), then ON.
        // NOTE: reads must be existence-safe — a successful relock dismisses
        // the sheet and the switch disappears mid-poll.
        flipSwitch(toggle, to: "0")
        XCTAssertEqual(toggle.value as? String, "0", "the OFF tap must land")
        XCTAssertFalse(app.buttons["fleet.app-lock.unlock"].waitForExistence(timeout: 3),
                       "turning the toggle OFF must not lock")
        // Flip back ON, verifying the switch value actually changed (a
        // dropped coordinate tap must not be mistaken for a relock failure).
        for _ in 0..<3 {
            if !toggle.exists || (toggle.value as? String) == "1" { break }
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            self.settleSwitch(toggle, value: "1")
        }
        XCTAssertTrue(app.buttons["fleet.app-lock.unlock"].waitForExistence(timeout: 10),
                      "flipping App Lock back ON must relock while the sheet is open")
        XCTAssertFalse(app.navigationBars["Settings"].exists,
                       "the Settings sheet must be dismissed by the lock (FOS-3)")

        // Unlock again (scripted biometric succeeds; the in-app relock leaves
        // the controller in .locked, so the biometric Unlock control shows)
        // and prove Command Center dismissal the same way: open Command
        // Center, then its OWN Settings entry (the gear beneath the sheet is
        // not hittable), then relock.
        app.buttons["fleet.app-lock.unlock"].tap()
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 15))
        app.buttons["fleet.command-center.open"].tap()
        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: 10))
        app.buttons["fleet.command-center.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let toggle2 = app.switches["fleet.settings.app-lock.toggle"]
        XCTAssertTrue(toggle2.waitForExistence(timeout: 10))
        flipSwitch(toggle2, to: "0")
        XCTAssertEqual(toggle2.value as? String, "0", "the OFF tap must land")
        for _ in 0..<3 {
            if !toggle2.exists || (toggle2.value as? String) == "1" { break }
            toggle2.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() // ON → relock
            self.settleSwitch(toggle2, value: "1")
        }
        XCTAssertTrue(app.buttons["fleet.app-lock.unlock"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Command Center"].exists,
                       "Command Center must be dismissed by the lock (FOS-3)")
        XCTAssertFalse(app.navigationBars["Settings"].exists,
                       "the Settings sheet must be dismissed by the lock (FOS-3)")

        // Unlock again so the app is left in a sane state.
        app.buttons["fleet.app-lock.unlock"].tap()
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 15))
    }

    // MARK: 6. Retired roots leave no residue
    func testRetiredControlAndWorkspaceRootsAreGone() throws {
        let app = launch()

        XCTAssertFalse(app.navigationBars["Control"].exists,
                       "the Control root must be retired")
        XCTAssertFalse(app.navigationBars["Workspace"].exists,
                       "the Workspace root must be retired")
        for tab in ["Fleet", "Chats", "Bots", "Gateways"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertFalse(app.descendants(matching: .any)
                .matching(identifier: "fleet.control").firstMatch.exists,
                "no Control surface may render on \(tab)")
            XCTAssertFalse(app.descendants(matching: .any)
                .matching(identifier: "fleet.workspace").firstMatch.exists,
                "no Workspace surface may render on \(tab)")
        }
    }

    // MARK: Helpers — deterministic toggle flips (existence-safe polls)

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
    /// dismiss the owning sheet and remove the switch mid-poll.
    private func settleSwitch(_ toggle: XCUIElement, value: String) {
        for _ in 0..<20 {
            if !toggle.exists || (toggle.value as? String) == value { return }
            usleep(250_000)
        }
    }
}
