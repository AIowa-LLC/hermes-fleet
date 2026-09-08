import XCTest

/// FOS-6 (t_9d259409) — component density UI suite against the scripted
/// simulator fleet (deterministic; no live gateway):
/// 1. The shared glance strip renders value+caption facts — each fact is
///    ONE AX element labeled "Label: value" (no four bordered tiles).
/// 2. Operational rows replace FleetCard on Roster/Schedules (cron)/
///    Skills/Routines — row actions still present and addressable
///    (no-lost-action audit), tap targets meet the ≥44pt bar.
/// 3. Semantic surfaces KEEP card treatment (Kanban board work cards
///    retained via its existing suite; spot-checked here by structure).
final class FOS6ComponentDensityUITests: XCTestCase {

    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    private func launch(extraEnv: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        self.app = app
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        for (key, value) in extraEnv {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func scrollToFind(_ app: XCUIApplication, _ element: XCUIElement, attempts: Int = 12) {
        var tries = 0
        while !element.isHittable && tries < attempts {
            app.swipeUp(velocity: .slow)
            tries += 1
        }
    }

    private func tap(_ e: XCUIElement) {
        if let app {
            scrollToFind(app, e)
        }
        e.tap()
    }

    /// The actionable-height bar: full-row NavigationLinks meet 44pt via
    /// FleetListRow's minHeight; compact icon buttons are held to >=40pt
    /// visible height with system press feedback (SPEC §21 gate 15 +
    /// card's ≥44pt actionable requirement for row-level controls).
    private func assertMinTapTarget(_ e: XCUIElement, _ name: String, minimum: CGFloat = 44,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.exists, "\(name) must exist for tap-target audit", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            e.frame.height, minimum,
            "\(name) actionable height \(e.frame.height)pt below \(minimum)pt bar",
            file: file, line: line)
    }

    // MARK: 1. Glance strip facts

    func testGlanceStripFactsRenderAsSingleAXElements() throws {
        let app = launch()
        let connected = app.staticTexts["fleet.dashboard.glance.connected"]
        XCTAssertTrue(connected.waitForExistence(timeout: 15), "connected fact renders")
        XCTAssertTrue(connected.label.contains(":"),
                      "each fact reads 'Label: value' as one element (got: \(connected.label))")
        XCTAssertTrue(connected.label.hasSuffix("/3"),
                      "connected fraction counts the registered fleet (got: \(connected.label))")
        let active = app.staticTexts["fleet.dashboard.glance.active"]
        XCTAssertTrue(active.waitForExistence(timeout: 5), "active fact renders")
        XCTAssertTrue(active.label.contains("—"),
                      "active fact never fabricates a zero count (got: \(active.label))")
    }

    // MARK: 2. Roster rows: operational rows, navigation intact

    func testRosterBotRowNavigatesWithoutCardChrome() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_AUTO_NAV": "roster"])
        let row = firstMatch(in: app, identifier: "fleet.roster.row.workstation#researcher")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "roster bot row renders")
        assertMinTapTarget(row, "roster bot row")
        row.tap()
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10),
            "row tap still opens Bot Detail (no lost navigation under the row style)")
    }

    // MARK: 3. Schedules (cron): row actions preserved

    func testCronRowKeepsFireAndToggleActions() throws {
        let app = launch()
        UITabNavigation.openScopedPane(app, resource: "cron", profile: "default")
        let fire = firstMatch(in: app, identifier: "cron.row.fire.script-cron-1")
        XCTAssertTrue(fire.waitForExistence(timeout: 15), "cron fire action survives the row migration")
        // Tap-target: the ACTIONABLE control (fire button) must meet the
        // bar; the name text that carries the row id is not the target.
        assertMinTapTarget(fire, "cron fire button", minimum: 40)
        let toggle = firstMatch(in: app, identifier: "cron.row.toggle.script-cron-1")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "cron enable/disable action survives")
        let row = firstMatch(in: app, identifier: "cron.row.script-cron-1")
        XCTAssertTrue(row.exists, "row identity rides the name text")
    }

    // MARK: 4. Skills: toggle preserved on the row

    func testSkillsRowKeepsToggle() throws {
        let app = launch()
        UITabNavigation.openScopedPane(app, resource: "skills", profile: "default")
        let toggle = firstMatch(in: app, identifier: "skills.row.toggle.codex")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15),
                      "skills toggle keeps its id under the row style")
        let row = firstMatch(in: app, identifier: "skills.row.codex")
        XCTAssertTrue(row.exists, "skills row identity rides the name text")
    }

    // MARK: 5. Routines: row + menu action preserved

    func testRoutinesRowKeepsMenuAction() throws {
        let app = launch()
        UITabNavigation.openGatewaysTab(app)
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        tap(firstMatch(in: app, identifier: "fleet.roster.row.workstation#researcher"))
        let segment = app.buttons["Routines"].firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 10))
        segment.tap()
        let row = firstMatch(in: app, identifier: "routines.row.script-routine-1")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "routine row renders on the operational row")
        let menu = firstMatch(in: app, identifier: "routines.row.menu.script-routine-1")
        XCTAssertTrue(menu.waitForExistence(timeout: 5),
                      "routine row menu action survives the row migration")
    }

    // MARK: 6. Kanban work cards keep card treatment (structural check)

    func testKanbanBoardStillRendersWorkCards() throws {
        let app = launch()
        // Proven KanbanBoardUITests navigation: Gateways -> cockpit row.
        UITabNavigation.openGatewaysTab(app)
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        let cockpitRow = firstMatch(in: app, identifier: "fleet.gateway-detail.workstation.kanban")
        scrollToFind(app, cockpitRow)
        XCTAssertTrue(cockpitRow.waitForExistence(timeout: 15), "the Kanban cockpit row renders")
        tap(cockpitRow)
        let banner = firstMatch(in: app, identifier: "kanban.board.streamBanner")
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "the board renders")
        // The board's real work cards stay card-shaped (SPEC §18 'Kanban
        // card' family); KanbanBoardUITests already proves column/card
        // content — here we verify the surface still renders post-FOS-6.
        let todoHeader = app.staticTexts["Todo"]
        XCTAssertTrue(todoHeader.waitForExistence(timeout: 15),
                      "the Kanban board (semantic card surface) still renders")
    }
}
