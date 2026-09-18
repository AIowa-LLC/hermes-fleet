import XCTest

/// Cron tab (the six-tab shell): the tab exists between Chats and Kanban,
/// opens the all-machines Cron home, sections render per gateway with the
/// card-B row contract (schedule/state/delivery chips), and operations work
/// inline (run-now notice, pause/resume, delete confirm) without leaving the
/// screen.
final class CronTabUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
    }

    private func firstMatch(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Bounded predicate wait returning Bool (XCTWaiter, not the trapping
    /// `wait(for:)`, so loops can re-tap on timeout).
    private func expectationSatisfied(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    /// Small-step scroll (fast swipes overshoot; below-fold lazy rows leave
    /// the AX tree entirely) until the element exists AND is hittable.
    @discardableResult
    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 6) -> Bool {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp(velocity: .slow)
        }
        return element.exists && element.isHittable
    }

    /// The workstation gateway has two profiles (default + researcher) and
    /// NAV_RESET clears stored selections, so the honest §8 chooser renders
    /// on entry. Select `default` deterministically (same contract as the
    /// scoped-pane suites' openScopedPane).
    private func resolveDefaultProfileIfNeeded() {
        let option = firstMatch("cron.home.profile.workstation#default")
        if option.waitForExistence(timeout: 5) {
            option.tap()
        }
    }

    private func openCronTab() {
        // Compact: open the drawer, then tap the cron destination. iPad's
        // adaptive top control exposes it directly.
        let drawerDestination = firstMatch("fleet.drawer.destination.cron")
        if !drawerDestination.isHittable {
            _ = UITabNavigation.openDrawer(app)
        }
        if drawerDestination.waitForExistence(timeout: 10) {
            drawerDestination.tap()
        } else {
            app.buttons["fleet.drawer.close"].tap()
            let tab = UITabNavigation.tabControl(app, label: "Scheduled")
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "Cron destination must exist (drawer or top control)")
            tab.tap()
        }
        XCTAssertTrue(app.navigationBars["Scheduled"].waitForExistence(timeout: 10),
                      "the Cron tab root must show the Cron navigation title")
        resolveDefaultProfileIfNeeded()
    }

    func testCronTabRendersMachineSectionsWithJobs() throws {
        openCronTab()

        // The scripted fleet's workstation gateway serves fixture jobs; its
        // section must render rows with the shared row contract.
        let schedule = firstMatch("cron.row.schedule.script-cron-1")
        XCTAssertTrue(schedule.waitForExistence(timeout: 15),
                      "the workstation section must list its fixture job")
        XCTAssertEqual(schedule.label, "every day at 07:00")

        let state = firstMatch("cron.row.state.script-cron-1")
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(state.label.contains("scheduled"),
                      "state chip shows the server state (got: \(state.label))")

        let deliver = firstMatch("cron.row.deliver.script-cron-1")
        XCTAssertTrue(deliver.waitForExistence(timeout: 5))

        // Machine grouping: the section header names the gateway.
        XCTAssertTrue(app.staticTexts["Workstation"].exists,
                      "machine sections are named after their gateway")
    }

    /// QA finding (deleg_865febdb): the tab MUST expose an Add control —
    /// single-gateway opens the create form directly; a fleet opens the
    /// per-machine menu. The scripted fleet has one real gateway, so the +
    /// is a direct button here.
    func testCronTabExposesAddControl() throws {
        openCronTab()

        let add = firstMatch("cron.new")
        XCTAssertTrue(add.waitForExistence(timeout: 10),
                      "the Cron tab must expose an Add (+) control")
        XCTAssertTrue(scrollTo(add), "the Add control must be hittable")
        add.tap()

        // Multi-gateway fleets (the scripted fleet has workstation + arch):
        // + opens the per-machine menu; pick the workstation machine, which
        // then presents the shared create form (CronJobFormSheet).
        let menuItem = app.buttons["Workstation"].firstMatch
        if menuItem.waitForExistence(timeout: 5) {
            menuItem.tap()
        }

        let nameField = app.descendants(matching: .any)
            .matching(identifier: "cron.form.name").firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10),
                      "Add must open the create form (cron.form.name)")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 3) { cancel.tap() }
        else { app.swipeDown() }
    }

    func testCronTabRunNowShowsNoticeWithoutLeavingScreen() throws {
        openCronTab()

        let fire = firstMatch("cron.row.fire.script-cron-1")
        XCTAssertTrue(scrollTo(fire), "the run-now control must become hittable")

        // Bounded tap-and-verify (scroll-then-tap race: the lazy row can
        // re-layout between the hit-test and the synthesized event). The
        // notice renders directly ABOVE the section's rows — a small scroll
        // up brings it into the AX tree if it landed offscreen.
        var fired = false
        for _ in 0..<3 where !fired {
            fire.tap()
            fired = firstMatch("cron.notice").waitForExistence(timeout: 4)
            if !fired { scrollTo(fire) }
        }
        for _ in 0..<4 {
            if firstMatch("cron.notice").exists { break }
            app.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(firstMatch("cron.notice").waitForExistence(timeout: 10),
                      "run-now surfaces the notice bar on the same screen")
        XCTAssertTrue(app.navigationBars["Scheduled"].exists,
                      "run-now must not navigate away from the Cron tab")
    }

    func testCronTabPauseResumesInline() throws {
        openCronTab()

        let toggle = firstMatch("cron.row.toggle.script-cron-1")
        XCTAssertTrue(scrollTo(toggle), "the pause control must become hittable")
        let nextFire = firstMatch("cron.row.nextfire.script-cron-1")
        let pausedPredicate = NSPredicate(format: "label CONTAINS 'Paused'")

        // Bounded tap-and-verify (the tap can land mid-layout and be
        // swallowed; re-scroll + re-tap while the row still presents).
        for _ in 0..<3 {
            toggle.tap()
            if expectationSatisfied(pausedPredicate, on: nextFire, timeout: 5) { break }
            scrollTo(toggle)
        }
        XCTAssertTrue(pausedPredicate.evaluate(with: nextFire),
                      "row shows Paused after disable (got: \(nextFire.label))")

        // Resumed: the next-fire line returns to its scheduled time (e.g.
        // "Sep 5, 07:00") and no longer says Paused. The schedule itself
        // lives on the separate schedule chip.
        let resumedPredicate = NSPredicate(format: "label CONTAINS '07:00'")
        for _ in 0..<3 {
            scrollTo(toggle)
            toggle.tap()
            if expectationSatisfied(resumedPredicate, on: nextFire, timeout: 5) { break }
        }
        XCTAssertTrue(resumedPredicate.evaluate(with: nextFire),
                      "row resumes after enable (got: \(nextFire.label))")
        XCTAssertFalse(nextFire.label.contains("Paused"),
                       "resumed row must not stay paused (got: \(nextFire.label))")
    }
}
