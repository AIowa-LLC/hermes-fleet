import XCTest

/// Card B — the Cron destination UI suite (scripted fleet): list rows carry
/// schedule/next-run/state/delivery, the detail screen shows the record +
/// execution ledger + run history with gateway/profile attribution, edit is
/// an in-place PUT (same job, new name), pause/resume and run-now act on the
/// job, and delete always asks for confirmation.
final class CronManagementUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Swipe up until `element` exists (lazy list content enters the AX tree
    /// in stages). Bounded to 8 swipes.
    @discardableResult
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        if element.exists { return element }
        for _ in 0..<8 where !element.exists {
            app.swipeUp(velocity: .fast)
        }
        return element
    }

    /// Swipe DOWN until `element` exists — earlier (lazy) list rows leave the
    /// AX tree once they scroll off; top-of-screen assertions after an
    /// actions-section scroll must scroll back first. Bounded to 8 swipes.
    @discardableResult
    private func scrollBackTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        if element.exists { return element }
        for _ in 0..<8 where !element.exists {
            app.swipeDown(velocity: .fast)
        }
        return element
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(scrollTo(element, in: app).waitForExistence(timeout: 15),
                      "element \(element) should appear")
        element.tap()
    }

    private func launchCronPane() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openScopedPane(app, resource: "cron", profile: "default")
        return app
    }

    private func openDetail(_ app: XCUIApplication, jobID: String) {
        tap(firstMatch(in: app, identifier: "cron.row.\(jobID)"), in: app)
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Tests

    /// List rows expose schedule, next-run, state and delivery; the pane names
    /// its gateway + profile.
    func testCronListShowsScheduleStateDeliveryAndAttribution() throws {
        let app = launchCronPane()

        let attribution = firstMatch(in: app, identifier: "cron.attribution")
        XCTAssertTrue(attribution.waitForExistence(timeout: 15), "the pane must name its gateway + profile")
        XCTAssertTrue(attribution.label.localizedCaseInsensitiveContains("workstation"),
                      "attribution names the gateway (got: \(attribution.label))")
        XCTAssertTrue(attribution.label.localizedCaseInsensitiveContains("default"),
                      "attribution names the profile (got: \(attribution.label))")

        let schedule = firstMatch(in: app, identifier: "cron.row.schedule.script-cron-1")
        XCTAssertTrue(scrollTo(schedule, in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(schedule.label, "every day at 07:00")

        let state = firstMatch(in: app, identifier: "cron.row.state.script-cron-1")
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(state.label.contains("scheduled"), "state chip shows the server state (got: \(state.label))")

        let deliver = firstMatch(in: app, identifier: "cron.row.deliver.script-cron-1")
        XCTAssertTrue(deliver.waitForExistence(timeout: 5))
        XCTAssertTrue(deliver.label.contains("Local"), "delivery target renders (got: \(deliver.label))")
        attachScreenshot(of: app, name: "b-cron-list")
    }

    /// The detail screen: record fields, execution ledger, run history,
    /// attribution.
    func testCronDetailShowsRecordLedgerHistoryAndAttribution() throws {
        let app = launchCronPane()
        openDetail(app, jobID: "script-cron-1")

        let name = firstMatch(in: app, identifier: "cron.detail.name")
        XCTAssertTrue(name.waitForExistence(timeout: 15), "detail loads the job")
        XCTAssertEqual(name.label, "Fleet morning briefing")

        let attribution = firstMatch(in: app, identifier: "cron.detail.attribution")
        XCTAssertTrue(attribution.waitForExistence(timeout: 5))
        XCTAssertTrue(attribution.label.localizedCaseInsensitiveContains("workstation")
                      && attribution.label.localizedCaseInsensitiveContains("default"),
                      "detail names gateway + profile (got: \(attribution.label))")

        XCTAssertTrue(firstMatch(in: app, identifier: "cron.detail.schedule").exists)
        XCTAssertTrue(firstMatch(in: app, identifier: "cron.detail.next").exists)
        XCTAssertTrue(firstMatch(in: app, identifier: "cron.detail.deliver").exists)

        let ledger = firstMatch(in: app, identifier: "cron.detail.execution.status")
        XCTAssertTrue(scrollTo(ledger, in: app).waitForExistence(timeout: 10), "execution ledger renders")
        XCTAssertTrue(ledger.label.contains("completed"), "ledger status (got: \(ledger.label))")

        let run = firstMatch(in: app, identifier: "cron.detail.run.cron_script-cron-1_1788596400")
        XCTAssertTrue(scrollTo(run, in: app).waitForExistence(timeout: 10), "run history renders the agent run")
        attachScreenshot(of: app, name: "b-cron-detail")
    }

    /// Script jobs have NO run sessions by design — the empty state says so
    /// instead of inventing rows.
    func testCronScriptJobShowsHonestEmptyHistory() throws {
        let app = launchCronPane()
        openDetail(app, jobID: "script-cron-3")

        let name = firstMatch(in: app, identifier: "cron.detail.name")
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        XCTAssertEqual(name.label, "Nightly pin sweep")

        let script = firstMatch(in: app, identifier: "cron.detail.script")
        XCTAssertTrue(scrollTo(script, in: app).waitForExistence(timeout: 10), "script job renders its script")

        let empty = firstMatch(in: app, identifier: "cron.detail.runs.empty")
        XCTAssertTrue(scrollTo(empty, in: app).waitForExistence(timeout: 10), "honest empty history renders")
        XCTAssertTrue(empty.label.localizedCaseInsensitiveContains("script"),
                      "empty state explains the script-job behavior (got: \(empty.label))")
    }

    /// Edit is an in-place PUT: the same job comes back renamed.
    func testCronEditRenamesInPlace() throws {
        let app = launchCronPane()
        openDetail(app, jobID: "script-cron-1")

        XCTAssertTrue(firstMatch(in: app, identifier: "cron.detail.name").waitForExistence(timeout: 15))
        tap(firstMatch(in: app, identifier: "cron.detail.edit"), in: app)

        let nameField = firstMatch(in: app, identifier: "cron.edit.name")
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "edit sheet opens")
        // Put the caret at the END of the prefilled text (a centered tap
        // lands mid-string), then clear it and type the new name.
        nameField.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let original = (nameField.value as? String) ?? ""
        if !original.isEmpty {
            nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count))
        }
        nameField.typeText("Briefing v2")
        XCTAssertEqual(nameField.value as? String, "Briefing v2",
                       "the edit field must hold the new name before saving")
        tap(firstMatch(in: app, identifier: "cron.edit.save"), in: app)

        // The sheet closed over the actions section; scroll back up to the
        // (lazy) detail header and watch the name settle.
        let updated = firstMatch(in: app, identifier: "cron.detail.name")
        XCTAssertTrue(scrollBackTo(updated, in: app).waitForExistence(timeout: 15),
                      "the detail header returns after the edit sheet closes")
        let predicate = NSPredicate(format: "label == %@", "Briefing v2")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: updated)
        wait(for: [expectation], timeout: 15)
        attachScreenshot(of: app, name: "b-cron-edited")
    }

    /// Pause → resume on the detail screen; the state reflects the server row.
    func testCronPauseAndResume() throws {
        let app = launchCronPane()
        openDetail(app, jobID: "script-cron-1")
        XCTAssertTrue(firstMatch(in: app, identifier: "cron.detail.name").waitForExistence(timeout: 15))

        tap(firstMatch(in: app, identifier: "cron.detail.toggle"), in: app)
        assertDetailState(app, contains: "paused")

        // Review round 1 regression (operator-visible symptom): the pause
        // response carries no ledger, so the pane must keep showing the last
        // known execution instead of fabricating "this job has not fired".
        let ledger = firstMatch(in: app, identifier: "cron.detail.execution.status")
        XCTAssertTrue(scrollTo(ledger, in: app).waitForExistence(timeout: 15),
                      "the execution ledger must survive a pause (ledger-less mutation response)")
        XCTAssertTrue(ledger.label.contains("completed"),
                      "ledger status after pause (got: \(ledger.label))")

        tap(firstMatch(in: app, identifier: "cron.detail.toggle"), in: app)
        assertDetailState(app, contains: "scheduled")
        attachScreenshot(of: app, name: "b-cron-paused-resumed")
    }

    /// The state chip lives in the (lazy) detail header — scroll back to it
    /// before asserting, since the actions section was just on screen.
    private func assertDetailState(_ app: XCUIApplication, contains text: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let state = firstMatch(in: app, identifier: "cron.detail.state")
        XCTAssertTrue(scrollBackTo(state, in: app).waitForExistence(timeout: 15),
                      "detail state chip renders", file: file, line: line)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text), object: state)
        wait(for: [expectation], timeout: 15)
    }

    /// Run now surfaces the confirmation notice.
    func testCronRunNowShowsNotice() throws {
        let app = launchCronPane()
        openDetail(app, jobID: "script-cron-1")
        XCTAssertTrue(firstMatch(in: app, identifier: "cron.detail.name").waitForExistence(timeout: 15))

        tap(firstMatch(in: app, identifier: "cron.detail.fire"), in: app)
        let notice = firstMatch(in: app, identifier: "cron.detail.notice")
        XCTAssertTrue(scrollTo(notice, in: app).waitForExistence(timeout: 15),
                      "run-now must confirm honestly")
        attachScreenshot(of: app, name: "b-cron-run-now")
    }

    /// Delete asks for confirmation; cancel keeps the job, confirm removes it.
    func testCronDeleteRequiresConfirmation() throws {
        let app = launchCronPane()
        openDetail(app, jobID: "script-cron-2")
        XCTAssertTrue(firstMatch(in: app, identifier: "cron.detail.name").waitForExistence(timeout: 15))

        tap(firstMatch(in: app, identifier: "cron.detail.delete"), in: app)
        // Alert buttons expose by LABEL (the app's trusted confirm pattern).
        let confirm = app.alerts.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "delete must ask for confirmation")

        // Cancel → the job is still there (assert on an element in the
        // current scroll region; the header above is lazy/offscreen here).
        let cancel = app.alerts.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(firstMatch(in: app, identifier: "cron.detail.delete").waitForExistence(timeout: 10),
                      "cancel keeps the job on screen")
        let stillNamed = firstMatch(in: app, identifier: "cron.detail.name")
        XCTAssertTrue(scrollBackTo(stillNamed, in: app).waitForExistence(timeout: 10),
                      "cancel keeps the job's detail header")

        // Confirm → the detail pops back to the list and the row is gone.
        tap(firstMatch(in: app, identifier: "cron.detail.delete"), in: app)
        XCTAssertTrue(app.alerts.buttons["Delete"].firstMatch.waitForExistence(timeout: 10))
        app.alerts.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(firstMatch(in: app, identifier: "cron.attribution").waitForExistence(timeout: 15),
                      "confirming delete pops back to the list")
        let row = firstMatch(in: app, identifier: "cron.row.script-cron-2")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == NO"), object: row)
        wait(for: [gone], timeout: 15)
        attachScreenshot(of: app, name: "b-cron-deleted")
    }

    /// The list's swipe delete also confirms before deleting.
    func testCronSwipeDeleteConfirms() throws {
        let app = launchCronPane()
        let row = firstMatch(in: app, identifier: "cron.row.script-cron-2")
        XCTAssertTrue(scrollTo(row, in: app).waitForExistence(timeout: 15))

        row.swipeLeft()
        tap(firstMatch(in: app, identifier: "cron.swipe.delete.script-cron-2"), in: app)

        let confirm = app.alerts.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "swipe delete must confirm")
        confirm.tap()
        XCTAssertTrue(firstMatch(in: app, identifier: "cron.attribution").waitForExistence(timeout: 15),
                      "the list pane stays up after the confirm")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == NO"), object: row)
        wait(for: [gone], timeout: 15)
    }
}