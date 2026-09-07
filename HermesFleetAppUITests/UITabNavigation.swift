import XCTest

/// U3 (Gold Fleet) shared tab-navigation helpers for the UI suites.
///
/// The root shell is a five-tab `TabView` (Home / Bots / Gateways / Activity /
/// Settings); cold launch lands on Home. Suites that drive the registry
/// cockpit (previously the root screen) open the Gateways tab first; suites
/// that opened the roster toolbar link open the Bots tab instead.
///
/// The lock gate complicates the first interaction: the app launches LOCKED
/// (H1 default-ON) and swaps `AppLockView` for the tab shell when the
/// (scripted) biometric succeeds — a few seconds after launch, around the
/// same time early taps land. A tap synthesized into that hierarchy swap can
/// be silently dropped, leaving Home selected. The helpers therefore VERIFY
/// the switch took effect and retry the tap once before failing.
enum UITabNavigation {

    /// Open a tab by label and verify the switch took effect, retrying the
    /// tap ONCE only when the tab is still not selected (a first tap can be
    /// swallowed by the lock-unlock hierarchy swap). Never re-taps a selected
    /// tab — that pops its stack to root (standard iOS tab behavior).
    private static func openTab(
        _ app: XCUIApplication,
        label: String,
        expectedBar: String,
        timeout: TimeInterval
    ) -> XCUIElement {
        let tab = app.tabBars.firstMatch.buttons[label]
        XCTAssertTrue(tab.waitForExistence(timeout: timeout), "\(label) tab should exist in the tab bar")
        let bar = app.navigationBars[expectedBar]
        tab.tap()
        if !bar.waitForExistence(timeout: 6) && !tab.isSelected {
            // The tap was dropped mid-transition (tab never selected) — retry.
            tab.tap()
        }
        XCTAssertTrue(bar.waitForExistence(timeout: timeout),
                      "the \(label) tab must host its screen (\(expectedBar))")
        return bar
    }

    /// Open the Gateways tab and wait for the registry cockpit's nav bar.
    @discardableResult
    static func openGatewaysTab(_ app: XCUIApplication, timeout: TimeInterval = 15) -> XCUIElement {
        if app.navigationBars["Hermes Fleet"].exists { return app.navigationBars["Hermes Fleet"] }
        _ = openTab(app, label: "Control", expectedBar: "Control", timeout: timeout)
        app.buttons["Gateways"].firstMatch.tap()
        let bar = app.navigationBars["Hermes Fleet"]
        XCTAssertTrue(bar.waitForExistence(timeout: timeout))
        return bar
    }

    /// Open the Bots tab (the fleet roster, previously a toolbar link).
    @discardableResult
    static func openBotsTab(_ app: XCUIApplication, timeout: TimeInterval = 15) -> XCUIElement {
        openTab(app, label: "Bots", expectedBar: "Fleet Roster", timeout: timeout)
    }
    static func openSettings(_ app: XCUIApplication) {
        _ = openTab(app, label: "Control", expectedBar: "Control", timeout: 15)
        let link = app.buttons["App Lock & settings"].firstMatch
        if !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        XCTAssertTrue(app.switches["fleet.settings.app-lock.toggle"].waitForExistence(timeout: 10))
    }
    static func openActivity(_ app: XCUIApplication) {
        _ = openTab(app, label: "Control", expectedBar: "Control", timeout: 15)
        app.buttons["Connection history"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 10))
    }

}
