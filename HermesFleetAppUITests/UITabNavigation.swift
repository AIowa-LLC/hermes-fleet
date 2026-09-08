import XCTest

/// U3 (Gold Fleet) shared tab-navigation helpers for the UI suites.
///
/// The root shell is a four-tab `TabView` (Fleet / Chats / Bots / Gateways);
/// cold launch lands on Fleet. Suites that drive the registry cockpit open
/// the Gateways tab first; suites that opened the roster toolbar link open
/// the Bots tab instead.
///
/// The lock gate complicates the first interaction: the app launches LOCKED
/// (H1 default-ON) and swaps `AppLockView` for the tab shell when the
/// (scripted) biometric succeeds — a few seconds after launch, around the
/// same time early taps land. A tap synthesized into that hierarchy swap can
/// be silently dropped, leaving Fleet selected. The helpers therefore VERIFY
/// the switch took effect and retry the tap once before failing.
enum UITabNavigation {

    /// Open a tab by label and verify the switch took effect, retrying the
    /// tap ONCE only when the tab is still not selected (a first tap can be
    /// swallowed by the lock-unlock hierarchy swap). Never re-taps a selected
    /// tab — that pops its stack to root (standard iOS tab behavior).
    @discardableResult
    private static func openTab(
        _ app: XCUIApplication,
        label: String,
        expectedBar: String,
        timeout: TimeInterval
    ) -> XCUIElement {
        let tab = app.tabBars.firstMatch.buttons[label]
        XCTAssertTrue(tab.waitForExistence(timeout: timeout), "\(label) tab should exist in the tab bar")
        let bar = app.navigationBars[expectedBar]
        // Under heavy simulator load (long CI gates) the first tap can land
        // during the lock-unlock hierarchy swap and be dropped. Retry up to
        // three times, and never re-tap a selected tab (that pops to root).
        for _ in 0..<3 {
            if bar.waitForExistence(timeout: 6) { break }
            if tab.isSelected { continue } // selected but bar not showing: wait, don't pop
            tab.tap()
        }
        XCTAssertTrue(bar.waitForExistence(timeout: timeout),
                      "the \(label) tab must host its screen (\(expectedBar))")
        return bar
    }

    /// Open the Gateways tab and wait for the registry cockpit's nav bar.
    /// FOS-3 (SPEC §6): the tab title is "Gateways" (was "Hermes Fleet").
    @discardableResult
    static func openGatewaysTab(_ app: XCUIApplication, timeout: TimeInterval = 15) -> XCUIElement {
        openTab(app, label: "Gateways", expectedBar: "Gateways", timeout: timeout)
    }

    /// Open the Bots tab (the fleet roster, previously a toolbar link).
    /// FOS-3 (SPEC §6/§19): the collection title is "Bots" (was "Fleet Roster").
    @discardableResult
    static func openBotsTab(_ app: XCUIApplication, timeout: TimeInterval = 15) -> XCUIElement {
        openTab(app, label: "Bots", expectedBar: "Bots", timeout: timeout)
    }
    static func openSettings(_ app: XCUIApplication) {
        _ = openTab(app, label: "Fleet", expectedBar: "Fleet", timeout: 15)
        app.buttons["fleet.settings.open"].tap()
        XCTAssertTrue(app.switches["fleet.settings.app-lock.toggle"].waitForExistence(timeout: 10))
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
