import UIKit
import XCTest

/// Adaptive drawer/sidebar navigation, pushed-screen access, and state retention.
final class U3TabNavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testColdLaunchShowsFiveTabsOnBots() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // Regular iPad exposes five destinations in its adaptive top control
        // (plain labeled Buttons — no UITabBar element); compact iPhone
        // exposes them from the drawer. Branch on the device idiom, NOT on
        // a runtime probe: iPhone launches through the lock-gate swap (no
        // drawer button exists until the scripted biometric lands), so a
        // timed drawer probe would race the unlock and misroute iPhone into
        // the adaptive path. tabControl/openDrawer still VERIFY the probed
        // shape actually renders.
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad: the top control hosts the five PRIMARY destinations
            // (sidebarAdaptable paginates past five — Settings would hide);
            // Settings stays in the drawer.
            for label in ["Bots", "Chats", "Groups", "Scheduled", "Kanban", "Fleet"] {
                XCTAssertTrue(UITabNavigation.tabControl(app, label: label)
                    .waitForExistence(timeout: 15), "root shell must include \(label)")
            }
            XCTAssertFalse(UITabNavigation.tabControl(app, label: "Gateways").exists,
                           "Gateways must not be a tab (Build 43: it lives under Fleet)")
            let drawer = UITabNavigation.openDrawer(app)
            XCTAssertTrue(drawer.exists, "iPad keeps the drawer for Settings")
            XCTAssertTrue(app.descendants(matching: .any)
                .matching(identifier: "fleet.drawer.destination.settings").firstMatch.exists,
                "Settings must remain reachable in the drawer on iPad")
            UITabNavigation.closeDrawer(app)
        } else {
            let drawer = UITabNavigation.openDrawer(app)
            XCTAssertTrue(drawer.exists, "compact root navigation drawer must render")
            for raw in ["bots", "chats", "groups", "cron", "kanban", "fleet", "settings"] {
                XCTAssertTrue(app.descendants(matching: .any)
                    .matching(identifier: "fleet.drawer.destination.\(raw)").firstMatch.exists)
            }
            UITabNavigation.closeDrawer(app)
        }

        // Build 41: Bots is the initial tab and shows the real roster (the
        // scripted fleet's gateways render in the sections — real data only).
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 15),
                      "Bots should render the roster with real scripted-fleet data")
        XCTAssertTrue(app.navigationBars["Bots"].exists, "Bots tab is initially selected")
        attachScreenshot(of: app, name: "u3-fleet-four-tabs")
    }

    func testBotsTabOpensFleetRoster() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        UITabNavigation.openBotsTab(app)
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10),
                      "the roster should list the scripted fleet's gateway sections")
        attachScreenshot(of: app, name: "u3-bots-roster")
    }

    func testGatewaysCockpitFromFleetTab() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // Build 43: the registry cockpit is reached Fleet → Manage Gateways.
        UITabNavigation.openGatewaysTab(app)
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.gateways.add").waitForExistence(timeout: 10),
                      "the Gateways toolbar must keep the Add entry")
        attachScreenshot(of: app, name: "u3-gateways-registry")
    }

    func testActivityTabShowsRealConnectionSummary() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        openActivityTab(app)
        // Real data only: the scripted fleet's gateways render a row each —
        // with honest "no activity recorded yet" lines until real connection
        // events accumulate (no fabricated timeline).
        let row = firstMatch(in: app, identifier: "fleet.activity.row.workstation")
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Connection activity must list the scripted fleet's gateways from real data")
        attachScreenshot(of: app, name: "u3-activity-real-summary")
    }

    func testSettingsTabHostsAppLockToggle() throws {
        let app = XCUIApplication()
        // Reset the persisted toggle so default-ON is deterministic even when
        // a previous suite left it OFF (same pattern as H1AppLockUITests).
        app.launchEnvironment["HERMES_FLEET_LOCK_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        openSettingsTab(app)
        // ADR-0011: the toggle lives in the Security sub-screen.
        let security = app.descendants(matching: .any)
            .matching(identifier: "fleet.settings.security").firstMatch
        XCTAssertTrue(security.waitForExistence(timeout: 15),
                      "the Settings root must expose the Security row")
        security.tap()
        let toggle = app.switches["fleet.settings.app-lock.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15),
                      "the Security sub-screen must host the App Lock toggle")
        XCTAssertEqual(toggle.value as? String, "1",
                       "App Lock toggle must default to ON in the Settings sheet")
        attachScreenshot(of: app, name: "u3-settings-app-lock")
    }

    func testGatewaysDrillInPreservedAcrossTabSwitch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // Drill in under Fleet: Manage Gateways → gateway → bots → bot detail.
        UITabNavigation.openGatewaysTab(app)
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10))
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        app.buttons["fleet.gateway-detail.workstation.bots"].tap()
        XCTAssertTrue(app.staticTexts["Default"].waitForExistence(timeout: 10))
        tap(firstMatch(in: app, identifier: "fleet.roster.row.workstation#default"))
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10),
            "Bot detail should render")

        // Switch away and back — the pushed detail must survive the tab
        // switch (each tab keeps its own NavigationStack). The Bots detail
        // was pushed on the Bots stack (owner routing, FOS-2 §6).
        tapTab(app, "Chats")
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        tapTab(app, "Bots")
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10),
            "Bot detail should render")
        attachScreenshot(of: app, name: "u3-tab-switch-preserves-stack")
    }

    /// iPad smoke coverage: the universal target remains usable after an
    /// orientation change, with the adaptive destination control and owning
    /// navigation stack still present. iPhone CI runs skip this device-only
    /// check; the manual iPad smoke invocation executes it on an iPad target.
    func testIPadLandscapePreservesRootNavigation() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad-only orientation smoke test")

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        let device = XCUIDevice.shared
        device.orientation = .landscapeLeft
        defer { device.orientation = .portrait }

        let fleet = UITabNavigation.tabControl(app, label: "Fleet")
        XCTAssertTrue(
            fleet.waitForExistence(timeout: 10),
            "Fleet destination remains available in landscape")
        // Select Fleet first — cold launch lands on Bots (Build 41+), so
        // the Fleet root only hosts its bar once selected.
        fleet.tap()
        XCTAssertTrue(
            app.navigationBars["Fleet"].waitForExistence(timeout: 10),
            "Fleet navigation bar remains available in landscape")
        attachScreenshot(of: app, name: "u3-ipad-landscape-navigation")
    }

    // MARK: - Compact drawer navigation

    func testCompactRootMenuOpensAndHasAllDestinations() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "compact iPhone drawer coverage")
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityXL"]
        app.launch()

        XCTAssertFalse(app.tabBars.firstMatch.waitForExistence(timeout: 2),
                       "compact iPhone replaces the visible tab bar")
        let drawer = UITabNavigation.openDrawer(app)
        for raw in ["bots", "chats", "groups", "cron", "kanban", "fleet", "settings"] {
            XCTAssertTrue(app.descendants(matching: .any)
                .matching(identifier: "fleet.drawer.destination.\(raw)").firstMatch.exists,
                "drawer exposes \(raw) destination")
        }
        attachScreenshot(of: app, name: "u3-compact-drawer-accessibility-type")
        XCTAssertTrue(drawer.exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "no bottom bar while drawer is open")
        UITabNavigation.closeDrawer(app)
        XCTAssertFalse(app.descendants(matching: .any)["fleet.drawer"].exists,
                       "Close dismisses the compact drawer")
    }

    func testCompactMenuIsAvailableOnIndividualAndGroupDestinations() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "compact iPhone drawer coverage")
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        let individual = app.descendants(matching: .any)
            .matching(identifier: "fleet.roster.row.workstation#default").firstMatch
        XCTAssertTrue(individual.waitForExistence(timeout: 15))
        individual.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fleet.bot-detail.header"].waitForExistence(timeout: 10))
        UITabNavigation.openDrawer(app)
        XCTAssertTrue(app.descendants(matching: .any)["fleet.drawer.destination.chats"].exists)
        UITabNavigation.closeDrawer(app)

        // Same-tab drawer reselection pops the Bots stack to its roster root.
        // Use the shared selector, which retries only while the drawer is
        // still open; a closed drawer is the signal that the one tap landed.
        UITabNavigation.selectTab(app, label: "Bots")
        let drawer = app.descendants(matching: .any)["fleet.drawer"].firstMatch
        XCTAssertFalse(drawer.exists, "same-tab selection must dismiss the drawer")
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 10),
                      "same-tab selection must return to the Bots roster")
        let group = app.descendants(matching: .any)["fleet.room.row.room-alpha"].firstMatch
        if !group.waitForExistence(timeout: 5) {
            for _ in 0..<8 where !group.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(group.waitForExistence(timeout: 10), "scripted group row renders")
        let roster = app.scrollViews["fleet.roster"].firstMatch
        XCTAssertTrue(roster.waitForExistence(timeout: 5), "Bots roster must expose its scroll view")
        let searchField = app.searchFields["Bots, groups, gateways"].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Bots roster search field must render")
        // XCTest can report a row as hittable when only its clipped bottom
        // edge is visible. In that state tap() targets the row's center
        // below the safe viewport (on iPhone 17 Pro, y=858 for a row ending
        // at y=894 in an 874-point window). Scroll the actual roster until
        // the whole row clears the persistent search field before activation.
        for _ in 0..<8 where group.frame.maxY > searchField.frame.minY {
            roster.swipeUp(velocity: .fast)
        }
        XCTAssertLessThanOrEqual(group.frame.maxY, searchField.frame.minY,
                                 "scripted group row must clear the bottom search field")
        XCTAssertTrue(group.isHittable, "scripted group row must be hittable before activation")
        group.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fleet.room.chat"].waitForExistence(timeout: 10))
        attachScreenshot(of: app, name: "u3-group-menu-and-back")
        UITabNavigation.openDrawer(app)
        XCTAssertTrue(app.descendants(matching: .any)["fleet.drawer.destination.bots"].exists)
    }

    func testCompactSwitchingRetainsIndividualConversationDraft() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "compact iPhone drawer coverage")
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        let row = app.descendants(matching: .any)["fleet.roster.row.workstation#default"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let session = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot-detail.sessions.row.workstation.default.s1").firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()
        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("drawer draft")
        attachScreenshot(of: app, name: "u3-individual-menu-and-draft")

        UITabNavigation.selectTab(app, label: "Fleet")
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: 10))
        UITabNavigation.selectTab(app, label: "Chats")
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "conversation path survives drawer switch")
        XCTAssertTrue(composer.value as? String == "drawer draft",
                      "conversation draft survives drawer switching")
    }

    func testCompactHiddenBotsMenuToggleUsesStableIdentifiers() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "compact iPhone drawer coverage")
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        // The scripted fixture marks workstation#researcher hidden when this
        // flag is enabled.
        app.launchEnvironment["HERMES_FLEET_HIDDEN_BOT"] = "1"
        app.launch()
        let manage = app.buttons["fleet.roster.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 15))
        XCTAssertTrue(manage.label.localizedCaseInsensitiveContains("bot") ||
                      manage.label.localizedCaseInsensitiveContains("option"),
                      "roster management control is presented as Bots options")
        XCTAssertFalse(app.descendants(matching: .any)["fleet.roster.row.workstation#researcher"].exists)
        manage.tap()
        let toggle = app.descendants(matching: .any)["fleet.roster.hidden-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(toggle.label.localizedCaseInsensitiveContains("show hidden bots"),
                      "hidden-bot action starts as Show hidden bots")
        toggle.tap()
        let researcher = app.descendants(matching: .any)["fleet.roster.row.workstation#researcher"]
        XCTAssertTrue(researcher.waitForExistence(timeout: 10), "revealed researcher bot renders")
        manage.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fleet.roster.hidden-toggle"].label
            .localizedCaseInsensitiveContains("hide hidden bots"),
                      "revealed hidden-bot action becomes Hide hidden bots")
        app.buttons["fleet.roster.hidden-toggle"].tap()
        XCTAssertFalse(researcher.exists, "Hide restores the original filtering")
    }

    func testCompactHiddenBotsEmptyNoticeHasStableIdentifier() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "compact iPhone drawer coverage")
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["fleet.roster.manage"].waitForExistence(timeout: 15))
        app.buttons["fleet.roster.manage"].tap()
        let toggle = app.descendants(matching: .any)["fleet.roster.hidden-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fleet.roster.hidden-empty"]
            .waitForExistence(timeout: 10), "empty hidden-bot notice has stable id")
    }

    func testCompactEveryRootExposesMenu() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "compact navigation")
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        for label in ["Chats", "Kanban", "Fleet", "Settings", "Bots"] {
            UITabNavigation.selectTab(app, label: label)
            XCTAssertTrue(app.navigationBars[label].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["fleet.drawer.open"].isHittable)
            XCTAssertFalse(app.tabBars.firstMatch.exists)
        }
        attachScreenshot(of: app, name: "u3-compact-roots-no-bottom-bar")
    }

    /// ADR-0008 (round-3 Codex parity): the ✕ close is retired — an
    /// interactive left swipe on the drawer dismisses it, and the scrim
    /// remains the deterministic dismissal control.
    func testDrawerSwipeLeftDismisses() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // Populate the drawer's Recents before capturing evidence: sessions
        // hydrate when the Chats root loads (a cold launch shows them empty).
        UITabNavigation.selectTab(app, label: "Chats")
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 15))
        usleep(1_500_000)

        let drawer = UITabNavigation.openDrawer(app)
        XCTAssertTrue(drawer.exists, "drawer opens")
        // Retired control: the strict-parity header is search-only.
        XCTAssertFalse(app.buttons["fleet.drawer.close"].exists,
                       "the close button is retired (ADR-0008)")
        XCTAssertTrue(app.buttons["fleet.drawer.search"].exists, "search stays")
        attachScreenshot(of: app, name: "u3-drawer-r3-open")

        drawer.swipeLeft()
        var dismissed = false
        for _ in 0..<20 where !dismissed {
            if !app.descendants(matching: .any)["fleet.drawer"].exists { dismissed = true } else { usleep(250_000) }
        }
        XCTAssertTrue(dismissed, "swipe-left must dismiss the drawer")

        // Re-open works after a gesture dismissal, and the scrim closes it.
        _ = UITabNavigation.openDrawer(app)
        XCTAssertTrue(UITabNavigation.closeDrawer(app), "scrim dismissal still works")
    }

    // MARK: - Tab helpers (verified switch, one retry on a dropped tap)

    private func tapTab(_ app: XCUIApplication, _ label: String) {
        UITabNavigation.selectTab(app, label: label)
    }

    private func openActivityTab(_ app: XCUIApplication) {
        UITabNavigation.openActivity(app)
    }

    private func openSettingsTab(_ app: XCUIApplication) {
        UITabNavigation.openSettings(app)
    }

    // MARK: - Helpers

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let any = app.descendants(matching: .any)[identifier]
        if any.exists { return any }
        if app.buttons[identifier].exists { return app.buttons[identifier] }
        if app.cells[identifier].exists { return app.cells[identifier] }
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
