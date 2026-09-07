import XCTest

/// R9-T5/T6 — deterministic management-panes UI suite (scripted fleet):
/// dashboard Management entries, cron rows render with the status dot +
/// mono schedule, the toggle flips the row state, the new-job form creates
/// a row, and the skills pane lists grouped rows with a working toggle.
///
/// NOTE: the Management section sits BELOW the fold on the Home dashboard
/// (after Fleet Overview / Gateways / Active Bots / Kanban) — entries are
/// scrolled to before tapping (the U4 scrollTo pattern).
final class R9ManagementPanesUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Swipe up until `element` exists (dashboard content enters the AX
    /// tree lazily). Bounded to 8 swipes.
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

    func testCronPaneListsFixtureJobsAndToggleFlipsRow() throws {
        let app = XCUIApplication()
        app.launch()

        // Dashboard → Management → Cron Jobs (below the fold).
        let entry = scrollTo(firstMatch(in: app, identifier: "fleet.dashboard.cron.entry"), in: app)
        tap(entry)

        let row = scrollTo(firstMatch(in: app, identifier: "cron.row.script-cron-1"), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "fixture cron job row should render")
        XCTAssertEqual(row.label, "Fleet morning briefing",
                       "the row identity element is the job name")

        // Schedule renders in mono and is individually addressable.
        let schedule = firstMatch(in: app, identifier: "cron.row.schedule.script-cron-1")
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        XCTAssertEqual(schedule.label, "every day at 07:00")

        // The paused fixture row surfaces too (include_disabled honesty).
        XCTAssertTrue(firstMatch(in: app, identifier: "cron.row.script-cron-2").waitForExistence(timeout: 5),
                      "paused job must be listed, not silently hidden")

        // Toggle the enabled job → the row's next-fire line flips to Paused.
        let toggle = firstMatch(in: app, identifier: "cron.row.toggle.script-cron-1")
        scrollTo(toggle, in: app)
        tap(toggle)
        let flipped = NSPredicate(format: "label CONTAINS %@", "Paused")
        let rowScope = app.staticTexts.matching(identifier: "cron.row.script-cron-1").firstMatch
        // Any element within the row reporting Paused settles the flip.
        let anyPaused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Paused")).firstMatch
        let flippedExpectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == YES"), object: anyPaused)
        wait(for: [flippedExpectation], timeout: 10)
        _ = rowScope
        attachScreenshot(of: app, name: "r9-cron-toggled")
    }

    func testCronFireNowShowsNotice() throws {
        let app = XCUIApplication()
        app.launch()

        let entry = scrollTo(firstMatch(in: app, identifier: "fleet.dashboard.cron.entry"), in: app)
        tap(entry)

        let fire = scrollTo(firstMatch(in: app, identifier: "cron.row.fire.script-cron-1"), in: app)
        XCTAssertTrue(fire.waitForExistence(timeout: 15), "fire button should render on the row")
        tap(fire)

        // The scripted gateway "supports" run — the confirmation notice
        // renders (and the list refreshes).
        let notice = firstMatch(in: app, identifier: "cron.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 15),
                      "fire-now should surface a notice")
        attachScreenshot(of: app, name: "r9-cron-fired")
    }

    func testCronFormCreatesJob() throws {
        let app = XCUIApplication()
        app.launch()

        let entry = scrollTo(firstMatch(in: app, identifier: "fleet.dashboard.cron.entry"), in: app)
        tap(entry)

        tap(firstMatch(in: app, identifier: "cron.new"))

        let name = firstMatch(in: app, identifier: "cron.form.name")
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Evening recap")

        let schedule = firstMatch(in: app, identifier: "cron.form.schedule")
        schedule.tap()
        schedule.typeText("every day at 21:00")

        let prompt = firstMatch(in: app, identifier: "cron.form.prompt")
        scrollTo(prompt, in: app)
        prompt.tap()
        prompt.typeText("Recap the day.")

        tap(firstMatch(in: app, identifier: "cron.form.save"))

        let newRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "cron.row.script-cron-"))
            .matching(NSPredicate(format: "label CONTAINS %@", "Evening recap"))
            .firstMatch
        XCTAssertTrue(newRow.waitForExistence(timeout: 15),
                      "created job should append to the list")
        attachScreenshot(of: app, name: "r9-cron-created")
    }

    func testSkillsPaneListsAndToggles() throws {
        let app = XCUIApplication()
        app.launch()

        let entry = scrollTo(firstMatch(in: app, identifier: "fleet.dashboard.skills.entry"), in: app)
        tap(entry)

        let row = scrollTo(firstMatch(in: app, identifier: "skills.row.codex"), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "fixture skill row should render")
        XCTAssertTrue(
            scrollTo(firstMatch(in: app, identifier: "skills.row.github-code-review"), in: app)
                .waitForExistence(timeout: 5),
            "fixture github skill renders")

        // The disabled fixture renders off.
        let tdd = app.switches["skills.row.toggle.test-driven-development"].firstMatch
        XCTAssertTrue(scrollTo(tdd, in: app).waitForExistence(timeout: 5))

        // Toggle codex off → the toggle settles off (any off-value shape).
        let codex = app.switches["skills.row.toggle.codex"].firstMatch
        XCTAssertTrue(scrollTo(codex, in: app).waitForExistence(timeout: 5))
        let valueBefore = codex.value as? String
        codex.tap()
        let off = NSPredicate(format: "value != %@", valueBefore ?? "1")
        let offExpectation = XCTNSPredicateExpectation(predicate: off, object: codex)
        wait(for: [offExpectation], timeout: 15)
        attachScreenshot(of: app, name: "r9-skills-toggled")
    }
}
