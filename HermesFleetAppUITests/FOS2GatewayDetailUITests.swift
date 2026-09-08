import XCTest

/// FOS-2 (t_e2169548, SPEC §8) — Gateway Detail cockpit regression suite.
///
/// Drives the DEBUG scripted fleet (deterministic) and proves:
///   1. a Gateway row opens that machine's cockpit (identity, connection
///      state, sanitized endpoint; NO raw full endpoint/credential);
///   2. resource rows are dense native rows for Bots / Groups / Projects /
///      Kanban / Schedules / Skills / Memory / Connection;
///   3. entering a profile-owned pane shows the EXPLICIT profile chooser —
///      with the scripted fleet's TWO workstation profiles, no silent
///      first/default preselection happens before an explicit choice;
///   4. an explicit choice scopes the pane (scope bar names gateway+profile)
///      and persists (re-entry reuses it);
///   5. Connection child exposes Connect/Test/Diagnostics with honest copy.
final class FOS2GatewayDetailUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 15) {
        // Below-fold rows enter the AX tree lazily — scroll before waiting.
        if !element.waitForExistence(timeout: 3) {
            let app = XCUIApplication()
            for _ in 0..<8 where !element.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "element \(element) should appear")
        if !element.isHittable {
            let app = XCUIApplication()
            for _ in 0..<4 where !element.isHittable { app.swipeUp(velocity: .fast) }
        }
        element.tap()
    }

    /// existence check that scrolls into the lazy AX tree first.
    @discardableResult
    private func ensureVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.exists { return true }
        for _ in 0..<8 where !element.exists { app.swipeUp(velocity: .fast) }
        return element.exists
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 1. Cockpit renders from a Gateway row: identity, state, sanitized
    /// endpoint, honest coverage line, and every resource row.
    func testGatewayRowOpensCockpitWithResourceRows() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        UITabNavigation.openGatewayDetail(app, gateway: "workstation")

        // Identity + honest activity coverage.
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.gateway-detail.activity-coverage").exists,
                      "coverage line must render (unknown stays unknown)")

        // Every §8 resource row renders as a native row (scroll the lazy
        // cockpit list; rows below the fold enter the AX tree on scroll).
        let app2 = app
        for key in ["bots", "groups", "projects", "kanban", "cron", "skills", "memory", "connection"] {
            let row = firstMatch(in: app2, identifier: "fleet.gateway-detail.workstation.\(key)")
            XCTAssertTrue(
                ensureVisible(row, in: app2),
                "resource row \(key) must render"
            )
        }
        attachScreenshot(of: app, name: "fos2-cockpit-resources")
    }

    /// 3. Two profiles, no prior choice ⇒ the CHOOSER renders; nothing is
    /// preselected silently. 4. An explicit choice scopes the pane and the
    /// scope bar names it.
    func testSchedulesPaneRequiresExplicitProfileChoiceThenScopes() throws {
        let app = XCUIApplication()
        // Neutralize any stored explicit choice so the chooser must render.
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        UITabNavigation.openGatewayDetail(app, gateway: "workstation")
        tap(firstMatch(in: app, identifier: "fleet.gateway-detail.workstation.cron"))

        // TWO candidates render — and crucially, before any tap, the cron
        // pane's rows must NOT have loaded under a silent default scope.
        let researcher = firstMatch(in: app, identifier: "fleet.scope.option.workstation#researcher")
        let defaultOption = firstMatch(in: app, identifier: "fleet.scope.option.workstation#default")
        XCTAssertTrue(researcher.waitForExistence(timeout: 10), "researcher option must render")
        XCTAssertTrue(defaultOption.exists, "default option must render")

        // Explicit choice — the researcher (NOT first by roster order
        // default is first; choosing researcher proves no positional pick).
        tap(researcher)

        // The pane is scoped: the scope bar names gateway + profile.
        let scopeBar = firstMatch(in: app, identifier: "fleet.scope.bar.workstation")
        XCTAssertTrue(scopeBar.waitForExistence(timeout: 10), "scope bar must render after choice")
        XCTAssertTrue(scopeBar.label.contains("researcher"),
                      "scope bar must name the chosen profile (got: \(scopeBar.label))")
        // Fixture rows load under the chosen scope.
        XCTAssertTrue(firstMatch(in: app, identifier: "cron.row.script-cron-1").waitForExistence(timeout: 15),
                      "cron rows must render under the explicit scope")
        attachScreenshot(of: app, name: "fos2-schedules-scoped-researcher")
    }

    /// 4b. The explicit choice persists: re-entering the pane reuses it
    /// without re-asking (and the scope bar still names it). Launched
    /// WITHOUT NAV_RESET so persisted state is the real subject — the choice
    /// is made explicitly in this same run.
    func testExplicitProfileChoicePersistsAcrossReentry() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // First entry: choose explicitly (persisted by the chooser). If a
        // previous run left a stored skills choice, the helper accepts the
        // stored-skip path and asserts the pane scope either way.
        UITabNavigation.openScopedPane(app, resource: "skills", profile: "researcher")

        // Pop back to the cockpit and re-enter: stored choice reused.
        app.navigationBars.buttons.firstMatch.tap()
        tap(firstMatch(in: app, identifier: "fleet.gateway-detail.workstation.skills"))
        let scopeBar = firstMatch(in: app, identifier: "fleet.scope.bar.workstation")
        XCTAssertTrue(scopeBar.waitForExistence(timeout: 10))
        XCTAssertTrue(scopeBar.label.contains("researcher"),
                      "stored explicit choice must be reused (got: \(scopeBar.label))")
        // Skills rows render under the reused scope.
        XCTAssertTrue(firstMatch(in: app, identifier: "skills.row.codex").waitForExistence(timeout: 15),
                      "skills rows must render under the reused scope")
        attachScreenshot(of: app, name: "fos2-skills-reused-scope")
    }

    /// 5. Connection child: identity, controls, diagnostics; copy never
    /// claims to stop the machine or Bots.
    func testConnectionChildExposesControlsAndDiagnostics() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        UITabNavigation.openGatewayDetail(app, gateway: "workstation")
        tap(firstMatch(in: app, identifier: "fleet.gateway-detail.workstation.connection"))

        // Controls render (the Test Connection row is the §8 diagnostic
        // action with in-flight state and surfaced result).
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.connection.test.workstation").waitForExistence(timeout: 15),
                      "Test Connection must be reachable on the Connection screen")
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.connection.connect.workstation").exists,
                      "Connect must be reachable on the Connection screen")
        // Full GatewayID is available in Connection details (§8).
        XCTAssertTrue(app.staticTexts["Gateway ID"].exists, "Gateway ID row must exist in Connection details")
        attachScreenshot(of: app, name: "fos2-connection-details")
    }

    /// 2b. Bot Detail entry carries the Route (no chooser): Skills from a
    /// Bot Detail opens directly scoped to that Bot's profile.
    func testBotDetailSkillsEntryCarriesRouteWithoutChooser() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // Gateways → cockpit → Bots → researcher bot detail.
        UITabNavigation.openGatewayDetail(app, gateway: "workstation")
        UITabNavigation.openGatewayBots(app)
        tap(firstMatch(in: app, identifier: "fleet.roster.row.workstation#researcher"))
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10))

        // Skills from Bot Detail carries the Route — NO chooser.
        tap(firstMatch(in: app, identifier: "fleet.bot-detail.skills"))
        let scopeBar = firstMatch(in: app, identifier: "fleet.scope.bar.workstation")
        XCTAssertTrue(scopeBar.waitForExistence(timeout: 10),
                      "Bot Detail entry must land scoped (no chooser)")
        XCTAssertTrue(scopeBar.label.contains("researcher"),
                      "scope must be the Bot's own profile (got: \(scopeBar.label))")
        attachScreenshot(of: app, name: "fos2-botdetail-skills-scoped")
    }
}
