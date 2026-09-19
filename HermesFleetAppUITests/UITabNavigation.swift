import XCTest

/// Shared navigation for compact drawers and regular-width system tabs/sidebars.
/// Keep the historical helper names for existing suites; cold launch is Bots.
/// The shell (sidebarAdaptable) is width-adaptive: compact width renders the
/// custom drawer (no UITabBar at all), while regular width renders the
/// adaptive TOP CONTROL whose five destinations surface as plain labeled
/// Buttons (SF-symbol identifiers) with no UITabBar element and no drawer.
enum UITabNavigation {

    static func shellReady(_ app: XCUIApplication, timeout: TimeInterval = 15) {
        // Three valid shell shapes, probed in order:
        //  1. a system tab bar (expanded iPad sidebar / future compact bar),
        //  2. the compact drawer's universal Menu button,
        //  3. the regular-width iPad adaptive top control. Probe the
        //     DESTINATION CONTROLS (labels Bots…Settings): they float above
        //     whatever stack is mounted. `fleet.tab.bots` is NOT a valid
        //     probe — the shell only mounts the selected/visited stacks, so
        //     it is absent whenever AUTO_NAV or a relaunch has already
        //     selected another destination (iPad B43/Artifacts failures).
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists || tabBar.waitForExistence(timeout: 2) { return }
        let menu = app.buttons["fleet.drawer.open"]
        if menu.exists || menu.waitForExistence(timeout: 2) { return }
        let adaptiveBots = app.buttons["Bots"]
        let adaptiveSettings = app.buttons["Settings"]
        XCTAssertTrue(
            adaptiveBots.waitForExistence(timeout: timeout) && adaptiveSettings.exists,
            "navigation shell must expose the tab bar, Menu, or the adaptive top control")
    }

    static func assertSelected(_ app: XCUIApplication, label: String,
                               navigationTitle: String? = nil,
                               timeout: TimeInterval = 10) {
        if app.tabBars.firstMatch.exists {
            XCTAssertTrue(app.tabBars.buttons[label].isSelected,
                          "\(label) destination must be selected")
        } else {
            let tabRaw = ["Bots": "bots", "Chats": "chats", "Scheduled": "cron", "Kanban": "kanban",
                        "Fleet": "fleet", "Settings": "settings", "About": "about"][label] ?? label.lowercased()
            let stack = app.descendants(matching: .any)["fleet.tab.\(tabRaw)"]
            if stack.waitForExistence(timeout: 2) {
                XCTAssertTrue(stack.exists,
                              "\(label) destination must be visible")
            } else {
                let title = navigationTitle ?? label
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: timeout),
                              "\(label) destination must be visible")
            }
        }
    }

    /// SwiftUI's sidebarAdaptable style exposes a visible tab bar on regular
    /// iPad and a drawer on compact iPhone.
    static func tabControl(_ app: XCUIApplication, label: String) -> XCUIElement {
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists || tabBar.waitForExistence(timeout: 2) {
            let tabButton = tabBar.buttons[label].firstMatch
            if tabButton.exists || tabButton.waitForExistence(timeout: 2) {
                return tabButton
            }
        }
        let button = app.buttons[label].firstMatch
        if button.exists || button.waitForExistence(timeout: 2) {
            return button
        }
        // iPad landscape presents the same destinations as sidebar cells;
        // their semantic labels remain the navigation contract even though
        // UIKit does not expose them as Button elements.
        return app.cells[label].firstMatch
    }

    /// Select a destination through the current device's navigation shell.
    ///
    /// Build 43 retention contract: a selected tab KEEPS its pushed stack,
    /// so the tab's ROOT bar (`navigationBars[label]`) is NOT a valid switch
    /// confirmation — a tab holding a pushed screen legitimately shows that
    /// screen's bar instead (U3 asserts exactly that retention). The landing
    /// signal is the DRAWER DISMISSING: every destination row closes it. The
    /// single retry is gated on the drawer still being OPEN (a presenting
    /// drawer can swallow the synthesized tap). NEVER re-tap a destination
    /// whose drawer already closed: re-selecting the current destination is
    /// the shell's deliberate pop-to-root affordance and destroys the
    /// retained stack under test.
    @discardableResult
    static func selectTab(_ app: XCUIApplication, label: String,
                          timeout: TimeInterval = 15) -> XCUIElement {
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists || tabBar.waitForExistence(timeout: 1) {
            let tab = tabBar.buttons[label].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: timeout), "\(label) tab should exist")
            tab.tap()
            return tab
        }
        let menu = app.buttons["fleet.drawer.open"].firstMatch
        if !(menu.exists || menu.waitForExistence(timeout: 2)) {
            let tab = tabControl(app, label: label)
            XCTAssertTrue(tab.waitForExistence(timeout: timeout), "\(label) sidebar destination should exist")
            tab.tap()
            return tab
        }
        menu.tap()
        let raw = ["Bots": "bots", "Chats": "chats", "Scheduled": "cron", "Kanban": "kanban",
                   "Fleet": "fleet", "Settings": "settings", "About": "about"][label] ?? label.lowercased()
        let destination = app.descendants(matching: .any)
            .matching(identifier: "fleet.drawer.destination.\(raw)").firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: timeout), "drawer must expose \(label)")
        let drawer = app.descendants(matching: .any)["fleet.drawer"]
        for _ in 0..<4 {
            destination.tap()
            // Dismissal = the tap landed. Poll briefly (the 0.24s dismiss
            // animation keeps the element in the tree for a moment).
            var dismissed = false
            for _ in 0..<6 where !dismissed {
                if !drawer.exists { dismissed = true } else { usleep(500_000) }
            }
            if dismissed { break }
            // Drawer still open = the tap was dropped while presenting.
            // Re-tap the destination row directly (the drawer never closed,
            // so this cannot be mistaken for a pop-to-root reselect).
            if !destination.waitForExistence(timeout: 3) { break }
        }
        return destination
    }

    /// Dogfood r4: search/Command Center is DRAWER-ONLY — the toolbar
    /// button (fleet.command-center.open) is retired. This is the suite
    /// entry: open the drawer, tap its search circle.
    static func openCommandCenter(_ app: XCUIApplication, timeout: TimeInterval = 15) {
        _ = openDrawer(app, timeout: timeout)
        let search = app.buttons["fleet.drawer.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: timeout),
                      "the drawer must expose the search circle")
        search.tap()
        XCTAssertTrue(app.navigationBars["Command Center"].waitForExistence(timeout: timeout),
                      "the drawer search circle must present Command Center")
    }

    @discardableResult
    static func openDrawer(_ app: XCUIApplication, timeout: TimeInterval = 15) -> XCUIElement {
        let menu = app.buttons["fleet.drawer.open"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: timeout), "the universal Menu button must exist")
        menu.tap()
        let drawer = app.descendants(matching: .any)
            .matching(identifier: "fleet.drawer").firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: timeout), "navigation drawer should open")
        return drawer
    }

    /// ADR-0008: the ✕ close control is retired. The deterministic suite
    /// dismissal is the scrim (a real button in the AX tree); swipe and
    /// destination-select dismissals are exercised by U3's dedicated test.
    @discardableResult
    static func closeDrawer(_ app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let scrim = app.buttons["fleet.drawer.scrim"].firstMatch
        XCTAssertTrue(scrim.waitForExistence(timeout: timeout), "the drawer scrim must be present")
        // The drawer covers the scrim's center on every device — tap the
        // visible strip at the trailing screen edge instead.
        scrim.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let drawer = app.descendants(matching: .any)
            .matching(identifier: "fleet.drawer").firstMatch
        var dismissed = false
        for _ in 0..<20 where !dismissed {
            if !drawer.exists { dismissed = true } else { usleep(250_000) }
        }
        XCTAssertTrue(dismissed, "the drawer must dismiss after a scrim tap")
        return dismissed
    }

    /// Open a tab and verify its ROOT screen is showing.
    ///
    /// Build 43 retention contract: tabs keep their pushed stacks across
    /// switches, so "the destination is selected" and "the destination shows
    /// its root" are different states. This helper asserts the ROOT
    /// contract: when the compact destination holds a retained stack, it
    /// first pops back through the shell's own affordance (re-selecting the
    /// current destination in the drawer pops to root). Callers that only
    /// need the destination SELECTED — RETAINING its pushed stack — must
    /// call `selectTab` instead (the U3 retention journeys do).
    ///
    /// Non-compact (tab bar / iPad sidebar): retrying a tap is safe — a
    /// system tab control never re-fires on an already-selected tab. On iPad
    /// the adaptive control does not expose UITabBar's selected-state
    /// contract, so the retry loop falls back to bounded re-taps.
    @discardableResult
    private static func openTab(
        _ app: XCUIApplication,
        label: String,
        expectedBar: String,
        timeout: TimeInterval
    ) -> XCUIElement {
        let tabBar = app.tabBars.firstMatch
        let compact = !(tabBar.exists || tabBar.waitForExistence(timeout: 1))
        let bar = app.navigationBars[expectedBar]
        if compact {
            selectTab(app, label: label, timeout: timeout)
            // A retained stack legitimately hides the root bar — pop to the
            // root through the shell's own affordance, then let the final
            // assertion below own the verdict.
            if !bar.waitForExistence(timeout: 2) {
                popToRootViaDrawer(app, label: label, timeout: timeout)
            }
        } else {
            let tab = tabControl(app, label: label)
            XCTAssertTrue(tab.waitForExistence(timeout: timeout), "\(label) destination control should exist")
            // Under heavy simulator load (long CI gates) the first tap can
            // land during the lock-unlock hierarchy swap or the splash
            // cross-fade and be dropped. Retry up to five times.
            for _ in 0..<5 {
                if bar.waitForExistence(timeout: 6) { break }
                if tab.elementType == .button && tab.isSelected { continue }
                tab.tap()
            }
        }
        XCTAssertTrue(bar.waitForExistence(timeout: timeout),
                      "the \(label) tab must host its screen (\(expectedBar))")
        return bar
    }

    /// Pop a compact destination to its root through the shell's reselect
    /// affordance: open the drawer and tap the ALREADY-SELECTED destination
    /// row (the product contract: re-selecting the current destination pops
    /// its stack to root). No-ops when the drawer cannot be reached.
    private static func popToRootViaDrawer(
        _ app: XCUIApplication,
        label: String,
        timeout: TimeInterval
    ) {
        let menu = app.buttons["fleet.drawer.open"].firstMatch
        guard menu.waitForExistence(timeout: 3) else { return }
        menu.tap()
        let raw = ["Bots": "bots", "Chats": "chats", "Scheduled": "cron", "Kanban": "kanban",
                   "Fleet": "fleet", "Settings": "settings", "About": "about"][label] ?? label.lowercased()
        let destination = app.descendants(matching: .any)
            .matching(identifier: "fleet.drawer.destination.\(raw)").firstMatch
        guard destination.waitForExistence(timeout: timeout) else { return }
        destination.tap()
        // The dismissal itself is unobservable from here without re-querying
        // the (already-asserted) root bar; give the pop a moment to settle.
        usleep(500_000)
    }

    /// Open the Gateways registry cockpit. Build 43: Gateways is no longer
    /// a tab — the entry is Fleet → "Manage Gateways" (the dashboard's
    /// gateways section), pushing the registry on the Fleet stack.
    @discardableResult
    static func openGatewaysTab(_ app: XCUIApplication, timeout: TimeInterval = 15) -> XCUIElement {
        // Wait for the tab shell first — a tap synthesized before the tab
        // bar exists is silently dropped (the same lock-gate lesson the
        // other helpers encode).
        selectTab(app, label: "Fleet", timeout: timeout)
        // Build 43: the Fleet tab may have the registry cockpit ALREADY
        // pushed (restored navigation from an earlier session — suites that
        // launch without NAV_RESET restore the saved Fleet stack). Either
        // landing is acceptable; only push when the root is showing.
        let bar = app.navigationBars["Gateways"]
        if bar.waitForExistence(timeout: 5) { return bar }
        XCTAssertTrue(app.navigationBars["Fleet"].waitForExistence(timeout: timeout),
                      "the Fleet tab must host its screen")
        let manage = app.descendants(matching: .any)
            .matching(identifier: "fleet.dashboard.gateways.manage").firstMatch
        if !manage.waitForExistence(timeout: 5) {
            for _ in 0..<6 where !manage.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(manage.waitForExistence(timeout: timeout),
                      "Fleet must expose the Manage Gateways entry")
        scrollToHittable(manage, in: app)
        manage.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: timeout),
                      "Manage Gateways must push the registry cockpit")
        return bar
    }

    /// Open the Bots tab (the fleet roster, previously a toolbar link).
    /// FOS-3 (SPEC §6/§19): the collection title is "Bots" (was "Fleet Roster").
    @discardableResult
    static func openBotsTab(_ app: XCUIApplication, timeout: TimeInterval = 15) -> XCUIElement {
        openTab(app, label: "Bots", expectedBar: "Bots", timeout: timeout)
    }

    /// Select the Fleet tab and wait for its dashboard (shared by suites
    /// that assert Fleet content; Build 41+ cold launch lands on Bots).
    static func openTabToFleet(_ app: XCUIApplication, timeout: TimeInterval = 15) {
        openTab(app, label: "Fleet", expectedBar: "Fleet", timeout: timeout)
    }

    /// Build 43: Settings is a first-class tab (was the Fleet gear sheet).
    /// ADR-0011: the App Lock toggle moved into the Security sub-screen —
    /// the root contract is the Theme section, not the toggle.
    static func openSettings(_ app: XCUIApplication) {
        _ = openTab(app, label: "Settings", expectedBar: "Settings", timeout: 15)
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "fleet.settings.accent")
                .firstMatch.waitForExistence(timeout: 10),
            "the Settings root must render the Theme section (accent row)")
    }

    /// ADR-0011 W3: open Settings and push into the Security sub-screen
    /// (the App Lock toggle lives there now).
    static func openSettingsSecurity(_ app: XCUIApplication) {
        openSettings(app)
        let row = app.descendants(matching: .any)
            .matching(identifier: "fleet.settings.security").firstMatch
        if !row.waitForExistence(timeout: 5) {
            for _ in 0..<4 where !row.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Settings must expose the Security row")
        if !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 10),
                      "the Security row must push its sub-screen")
    }

    /// ADR-0011 + dogfood round 2: open the About tab via the Settings
    /// root's About row (the drawer circle is retired).
    static func openAbout(_ app: XCUIApplication) {
        openSettings(app)
        let row = app.buttons["fleet.settings.about"].firstMatch
        if !row.waitForExistence(timeout: 5) {
            for _ in 0..<4 where !row.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Settings must expose the About row")
        if !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 10),
                      "the Settings About row must select the About tab")
    }
    static func openActivity(_ app: XCUIApplication) {
        // FOS-3: Control's cross-fleet diagnostics links are owned by the
        // Gateways tab (Connection history under its Fleet section).
        _ = openGatewaysTab(app)
        let history = app.buttons["fleet.gateways.activity"].firstMatch
        if !history.waitForExistence(timeout: 5) {
            for _ in 0..<4 where !history.exists { app.swipeUp(velocity: .fast) }
        }
        history.tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 10))
    }

    // MARK: FOS-2 — Gateway Detail walks (SPEC §8)

    /// Open a gateway's Detail cockpit from the Gateways tab.
    /// `row` is the gateway id (the scripted fleet seeds workstation /
    /// render-box / arch).
    static func openGatewayDetail(
        _ app: XCUIApplication,
        gateway row: String = "workstation",
        timeout: TimeInterval = 15
    ) {
        openGatewaysTab(app, timeout: timeout)
        let rowElement = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateways.row.\(row)").firstMatch
        XCTAssertTrue(rowElement.waitForExistence(timeout: timeout),
                      "gateway row \(row) should render in the registry")
        rowElement.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.gateway-detail.\(row)").firstMatch
                .waitForExistence(timeout: timeout),
            "Gateway Detail cockpit should render for \(row)"
        )
    }

    /// Scroll within the cockpit until an element is hittable (resource rows
    /// sit below the fold on the cockpit and enter the AX tree lazily —
    /// scroll BEFORE existence checks; the R9 pattern).
    @discardableResult
    private static func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .fast)
        }
        return element
    }

    /// Same lazy-AX scroll contract as `scrollTo`, shared by the
    /// Fleet-dashboard navigation helpers (Build 43).
    @discardableResult
    private static func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        scrollTo(element, in: app)
    }

    /// Scroll the cockpit until a resource row exists (lazy AX), then tap it.
    private static func openCockpitRow(
        _ app: XCUIApplication,
        gateway: String,
        key: String,
        timeout: TimeInterval
    ) {
        let row = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateway-detail.\(gateway).\(key)").firstMatch
        if !row.waitForExistence(timeout: 5) {
            // Below the fold: scroll it into the AX tree first.
            for _ in 0..<8 where !row.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(row.waitForExistence(timeout: timeout),
                      "resource row \(key) should render on the cockpit")
        scrollTo(row, in: app)
        row.tap()
    }

    /// Open a gateway's Bots list from the Gateways tab (FOS-2: gateway rows
    /// open the Gateway Detail cockpit first — SPEC §8 — so the Bots
    /// collection is one more tap beneath it).
    static func openGatewayBots(
        _ app: XCUIApplication,
        gateway row: String = "workstation",
        timeout: TimeInterval = 15
    ) {
        let bots = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateway-detail.\(row).bots").firstMatch
        XCTAssertTrue(bots.waitForExistence(timeout: timeout),
                      "the cockpit's Bots row should render for \(row)")
        openCockpitRow(app, gateway: row, key: "bots", timeout: timeout)
    }

    /// Open a profile-scoped resource pane beneath Gateway Detail
    /// (Schedules / Skills / Memory / Projects). The scripted workstation
    /// exposes TWO profiles (default + researcher), so the explicit profile
    /// chooser renders; the pane is entered with an EXPLICIT profile choice
    /// (FOS-2: no silent first/default fallback — SPEC §8).
    static func openScopedPane(
        _ app: XCUIApplication,
        gateway: String = "workstation",
        resource key: String,
        profile: String = "default",
        timeout: TimeInterval = 15
    ) {
        openGatewayDetail(app, gateway: gateway, timeout: timeout)
        openCockpitRow(app, gateway: gateway, key: key, timeout: timeout)
        // Explicit profile choice (the chooser renders when no valid stored
        // selection exists; a stored selection skips straight to the pane —
        // accept either, but VERIFY the resulting scope bar names the pane's
        // gateway and the expected profile).
        let option = app.descendants(matching: .any)
            .matching(identifier: "fleet.scope.option.\(gateway)#\(profile)").firstMatch
        if option.waitForExistence(timeout: 5) {
            option.tap()
        }
        let scopeBar = app.descendants(matching: .any)
            .matching(identifier: "fleet.scope.bar.\(gateway)").firstMatch
        XCTAssertTrue(scopeBar.waitForExistence(timeout: timeout),
                      "the scoped pane must show its scope bar")
        XCTAssertTrue(scopeBar.label.contains(profile),
                      "scope bar must name the selected profile \(profile) (got: \(scopeBar.label))")
    }
}
