import XCTest

/// TRUE BOTS MODE slice 3 (D13) — deterministic bot-routines UI suite
/// (scripted fleet). Proves the bot-scoped Routines surface:
///   1. bot detail exposes the Routines action;
///   2. only THIS bot's `[bot:<slug>]` routines render (general cron and
///      other bots' routines never leak into the bot surface);
///   3. pause/resume toggle flips the row;
///   4. create stamps the namespace (form shows the stored name) and the
///      new routine renders;
///   5. remove asks for confirmation before deleting;
///   6. the failure association (last_fire_error) renders on the row.
final class BotRoutinesUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        if element.exists { return element }
        for _ in 0..<8 where !element.exists {
            app.swipeUp(velocity: .fast)
        }
        return element
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "element \(element) should appear")
        element.tap()
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Gateways → Workstation → researcher bot → Routines.
    private func openResearcherRoutines(_ app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        tap(firstMatch(in: app, identifier: "fleet.roster.row.workstation#researcher"))
        tap(firstMatch(in: app, identifier: "fleet.bot-detail.routines"))
    }

    func testRoutinesListOnlyThisBotsNamespacedJobs() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openResearcherRoutines(app)

        // The researcher's two fixture routines render (paused included).
        let row = firstMatch(in: app, identifier: "routines.row.script-routine-1")
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "the researcher's routine row must render")
        XCTAssertEqual(row.label, "Morning briefing",
                       "the namespace is stripped for display — the user sees the routine label")
        let schedule = firstMatch(in: app, identifier: "routines.row.schedule.script-routine-1")
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        XCTAssertEqual(schedule.label, "every day at 07:00")
        XCTAssertTrue(firstMatch(in: app, identifier: "routines.row.script-routine-2").waitForExistence(timeout: 5),
                      "paused routine must stay visible (include_disabled honesty)")

        // General cron jobs NEVER leak into the bot surface.
        XCTAssertFalse(firstMatch(in: app, identifier: "routines.row.script-cron-1").exists,
                       "a general cron job must not render as this bot's routine")
        // Another bot's routine never leaks in.
        XCTAssertFalse(firstMatch(in: app, identifier: "routines.row.script-routine-3").exists,
                       "the default bot's routine must not render on the researcher's surface")
        attachScreenshot(of: app, name: "s3-routines-list")
    }

    func testFailureAssociationRendersOnRow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        // The default bot's routine carries a last_fire_error fixture.
        UITabNavigation.openGatewaysTab(app)
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        tap(firstMatch(in: app, identifier: "fleet.roster.row.workstation#default"))
        tap(firstMatch(in: app, identifier: "fleet.bot-detail.routines"))

        let failure = firstMatch(in: app, identifier: "routines.row.failure.script-routine-3")
        XCTAssertTrue(failure.waitForExistence(timeout: 15),
                      "last_fire_error must render as the row's failure detail")
        XCTAssertEqual(failure.label, "Failure: provider auth missing for openrouter",
                       "failure detail shows the wire-provided reason, never a fabricated one")
        attachScreenshot(of: app, name: "s3-routines-failure")
    }

    func testPauseToggleFlipsRowToPaused() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openResearcherRoutines(app)

        let row = firstMatch(in: app, identifier: "routines.row.script-routine-1")
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        // Open the row's action menu → Pause.
        tap(firstMatch(in: app, identifier: "routines.row.menu.script-routine-1"))
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "Pause action in the routine menu")
        pause.tap()

        // The row flips to Paused (status line, server truth after reload).
        let anyPaused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Paused")).firstMatch
        let paused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == YES"), object: anyPaused)
        wait(for: [paused], timeout: 10)
        attachScreenshot(of: app, name: "s3-routines-paused")
    }

    func testCreateStampsNamespaceAndRendersRow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openResearcherRoutines(app)

        tap(firstMatch(in: app, identifier: "routines.new"))

        let name = firstMatch(in: app, identifier: "routines.form.name")
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Evening recap")

        // The form footer shows the namespaced storage name — the user
        // never types the namespace.
        let sheet = firstMatch(in: app, identifier: "routines.form.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(
            sheet.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "[bot:researcher]")).firstMatch.exists,
            "the form must preview the [bot:researcher] namespaced job name")

        app.buttons["Advanced"].tap()
        let schedule = firstMatch(in: app, identifier: "routines.form.schedule")
        schedule.tap()
        schedule.typeText("every day at 21:00")

        let prompt = firstMatch(in: app, identifier: "routines.form.prompt")
        prompt.tap()
        prompt.typeText("Recap the day.")

        tap(firstMatch(in: app, identifier: "routines.form.save"))

        // The created routine renders with its label (namespace stripped).
        let created = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Evening recap")).firstMatch
        let appeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == YES"), object: created)
        wait(for: [appeared], timeout: 10)
        attachScreenshot(of: app, name: "s3-routines-created")
    }

    func testRemoveAsksConfirmationBeforeDelete() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openResearcherRoutines(app)

        let row = firstMatch(in: app, identifier: "routines.row.script-routine-1")
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        // Row menu → Remove arms the destructive confirmation.
        tap(firstMatch(in: app, identifier: "routines.row.menu.script-routine-1"))
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()

        // The confirmation dialog names the routine; Cancel keeps it.
        let confirm = firstMatch(in: app, identifier: "routines.remove.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "remove must confirm before deleting")
        // iOS 26 confirmation-dialog buttons match by identifier (the
        // dialog buttons get explicit ids).
        let cancel = firstMatch(in: app, identifier: "routines.remove.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Cancel must be offered")
        cancel.tap()
        XCTAssertTrue(firstMatch(in: app, identifier: "routines.row.script-routine-1").waitForExistence(timeout: 5),
                      "cancel must keep the routine")

        // Confirmed remove deletes the row.
        tap(firstMatch(in: app, identifier: "routines.row.menu.script-routine-1"))
        let removeAgain = app.buttons["Remove"]
        XCTAssertTrue(removeAgain.waitForExistence(timeout: 5))
        removeAgain.tap()
        tap(firstMatch(in: app, identifier: "routines.remove.confirm"))

        let gone = NSPredicate(format: "exists == NO")
        let rowGone = XCTNSPredicateExpectation(
            predicate: gone, object: firstMatch(in: app, identifier: "routines.row.script-routine-1"))
        wait(for: [rowGone], timeout: 10)
        attachScreenshot(of: app, name: "s3-routines-removed")
    }

    func testRunNowUnsupportedShowsHonestExplanationCard() throws {
        let app = XCUIApplication()
        // Script the REAL 0.21.0 wire answer: run not forwarded → 4016.
        app.launchArguments += ["-fixture-run-now-fails"]
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openResearcherRoutines(app)

        let row = firstMatch(in: app, identifier: "routines.row.script-routine-1")
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        // Row menu → Run Now.
        tap(firstMatch(in: app, identifier: "routines.row.menu.script-routine-1"))
        let runNow = app.buttons["Run Now"]
        XCTAssertTrue(runNow.waitForExistence(timeout: 5), "Run Now action in the routine menu")
        runNow.tap()

        // The honest unsupported-explanation card renders (4016 gate).
        let card = firstMatch(in: app, identifier: "routines.runnow.unsupported")
        XCTAssertTrue(card.waitForExistence(timeout: 10),
                      "the unsupported explanation card must be reachable from the UI")
        attachScreenshot(of: app, name: "s3-routines-runnow-unsupported")
    }

    func testRunNowSuccessSurfacesNotice() throws {
        let app = XCUIApplication()
        // Default scripted gateway forwards run (R9-era fixture
        // behavior) — the supported-gateway branch.
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openResearcherRoutines(app)

        let row = firstMatch(in: app, identifier: "routines.row.script-routine-1")
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        tap(firstMatch(in: app, identifier: "routines.row.menu.script-routine-1"))
        let runNow = app.buttons["Run Now"]
        XCTAssertTrue(runNow.waitForExistence(timeout: 5))
        runNow.tap()

        // The success notice renders (routines.notice card).
        let notice = firstMatch(in: app, identifier: "routines.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10),
                      "a supported gateway's run-now must surface the notice card")
        attachScreenshot(of: app, name: "s3-routines-runnow-success")
    }

    func testGeneralCronPaneUnhijacked() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        // The gateway-wide Cron pane still lists its fixture rows —
        // bot routines never filtered or hijacked the general surface.
        // FOS-2 (§8): the general Cron pane lives beneath Gateway Detail with
        // an explicit profile choice — never a silent first/default pick.
        UITabNavigation.openScopedPane(app, resource: "cron", profile: "default")
        XCTAssertTrue(firstMatch(in: app, identifier: "cron.row.script-cron-1").waitForExistence(timeout: 15),
                      "general cron rows must keep rendering on the Schedules pane")
        XCTAssertTrue(firstMatch(in: app, identifier: "cron.row.script-cron-2").waitForExistence(timeout: 5))
        attachScreenshot(of: app, name: "s3-general-cron-preserved")
    }
}
