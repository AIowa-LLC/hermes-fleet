import XCTest

/// R10-T3 — deterministic Projects-browser UI suite (scripted fleet, no
/// live gateway): dashboard entry → project list (overview shape with
/// counts + active badge) → drill-in shows hydrated lanes with session
/// rows → a session row opens the conversation canvas via the existing
/// route. The failure hook proves the honest error state.
///
/// The scripted `ScriptedProjectsSeam` fixture mirrors the live wire:
/// overview lanes carry NO rows (hydrate=False), drill-in lanes do.
final class R10ProjectsBrowserUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "missing element: \(identifier)")
        return element
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.isHittable || element.isEnabled, "element not hittable/enabled")
        element.tap()
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        var attempts = 0
        while !element.isHittable && attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
        return element
    }

    /// Dashboard → Management → Projects (below the fold). The app
    /// launches onto the Home dashboard — same entry walk as the R9
    /// memory-graph suite. `expectRow: false` for the failure-hook
    /// walkthrough (the pane shows its error state, not rows).
    private func openProjects(_ app: XCUIApplication, expectRow: Bool = true) {
        let entry = scrollTo(
            firstMatch(in: app, identifier: "fleet.dashboard.projects.entry"), in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "projects entry should appear on the dashboard")
        tap(entry)
        if expectRow {
            _ = firstMatch(in: app, identifier: "fleet.projects.row.proj-fleet")
        }
    }

    /// Entry renders the fixture overview: the explicit project (with
    /// active badge + session count) and the "No Project" tier.
    func testProjectsListShowsOverviewShape() throws {
        let app = XCUIApplication()
        app.launch()
        openProjects(app)

        let fleetRow = firstMatch(in: app, identifier: "fleet.projects.row.proj-fleet")
        XCTAssertTrue(fleetRow.label.contains("Fleet iOS"), "project label renders")
        XCTAssertTrue(fleetRow.label.contains("3"), "session count renders")

        _ = firstMatch(in: app, identifier: "fleet.projects.row.__no_project__")
    }

    /// Drill-in shows hydrated lanes (session rows the overview omitted).
    func testDrillInShowsHydratedLanesAndOpensConversation() throws {
        let app = XCUIApplication()
        app.launch()
        openProjects(app)

        tap(firstMatch(in: app, identifier: "fleet.projects.row.proj-fleet"))

        // Hydrated lane session rows (projects.project_sessions) —
        // lanes render flat (header + rows), no collapsed disclosure.
        let sessionRow = firstMatch(in: app, identifier: "fleet.projects.session.s1")
        XCTAssertTrue(sessionRow.label.contains("WS transport fix"),
                      "hydrated lane row carries the session title")
        _ = firstMatch(in: app, identifier: "fleet.projects.lane.r10-t3")

        // Tapping the session opens the conversation via the existing route.
        tap(sessionRow)
        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10),
                      "session row must open the conversation canvas")
    }

    /// The failure hook surfaces the honest error state (never silent).
    func testFailureHookShowsErrorState() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_PROJECTS_FAIL"] = "1"
        app.launch()
        openProjects(app, expectRow: false)

        _ = firstMatch(in: app, identifier: "fleet.projects.retry")
    }
}
