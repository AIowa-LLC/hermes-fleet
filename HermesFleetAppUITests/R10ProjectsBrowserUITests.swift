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
        // FOS-2 (§8): Projects beneath Gateway Detail, explicit profile.
        UITabNavigation.openScopedPane(app, resource: "projects", profile: "default")
        if expectRow {
            _ = firstMatch(in: app, identifier: "fleet.projects.row.proj-fleet")
        }
    }

    /// Entry renders the fixture overview: the explicit project (with
    /// active badge + session count) and the "No Project" tier.
    func testProjectsListShowsOverviewShape() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
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
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
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
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openProjects(app, expectRow: false)

        _ = firstMatch(in: app, identifier: "fleet.projects.retry")
    }

    /// R10-T3 round 2 (QA defect 1+2 regression): a transcript `@file:`
    /// chip taps THROUGH into the browser at that path — the focus
    /// banner carries the referenced path and names the containing
    /// project, which is also badged "referenced" (pre-highlight).
    /// Scripted fixture: resumeSession returns a durable row with an
    /// absolute @file: path inside the scripted tree's repo.
    func testTranscriptFileRefChipTapsThroughToFocusedBrowser() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_FILEREF_FIXTURE"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // Walk to the conversation the same way the reactions suite does.
        UITabNavigation.openGatewaysTab(app)
        tap(app.descendants(matching: .any).matching(identifier: "fleet.gateways.row.workstation").firstMatch)
        UITabNavigation.openGatewayBots(app)
        tap(app.descendants(matching: .any).matching(identifier: "fleet.roster.row.workstation#default").firstMatch)
        tap(app.descendants(matching: .any).matching(identifier: "fleet.bot-detail.sessions.row.workstation.default.s1").firstMatch)
        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "conversation canvas should open")

        // The transcript row's @file: chip (durable history rows render
        // after resume; bounded wait for the chip to appear).
        let chip = app.descendants(matching: .any)
            .matching(identifier: "fleet.conversation.fileref.0").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "the @file: chip must render under the transcript row")
        scrollTo(chip, in: app)
        tap(chip)

        // Landed in the Projects browser AT that path: the focus banner
        // carries the referenced path and names the containing project.
        let banner = firstMatch(in: app, identifier: "fleet.projects.focus.banner")
        XCTAssertTrue(banner.label.contains("ProjectsView.swift"),
                      "focus banner surfaces the referenced path: \(banner.label)")
        XCTAssertTrue(banner.label.contains("Fleet iOS"),
                      "focus banner names the containing project: \(banner.label)")

        // The containing project row is pre-highlighted ("referenced").
        let fleetRow = firstMatch(in: app, identifier: "fleet.projects.row.proj-fleet")
        XCTAssertTrue(fleetRow.label.contains("referenced"),
                      "containing project carries the tap-through highlight: \(fleetRow.label)")
    }
}
