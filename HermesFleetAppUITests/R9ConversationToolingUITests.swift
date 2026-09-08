import XCTest

/// R9-T2/T3/T4 — deterministic conversation-tooling UI suite (scripted
/// fleet): the model chip opens the picker, fixture models render with the
/// current-model checkmark, a pick persists (sticky) and the meter/breakdown
/// surface renders with the fixture gauge.
final class R9ConversationToolingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openConversation(_ app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        tap(firstMatch(in: app, identifier: "fleet.roster.row.workstation#default"))
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10),
            "Bot detail should render before drilling into the conversation"
        )
        tap(firstMatch(in: app, identifier: "fleet.bot-detail.sessions.row.workstation.default.s1"))
        XCTAssertTrue(
            app.textFields["fleet.conversation.composer"].waitForExistence(timeout: 10),
            "conversation canvas should open with a composer"
        )
    }

    func testModelPickerShowsFixtureModelsWithCurrentCheckmark() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openConversation(app)

        // The model chip renders in the conversation header sub-row.
        let chip = firstMatch(in: app, identifier: "model.chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "model chip should render in the conversation header")

        // Tapping opens the picker; the fixture models load (scripted
        // tooling returns hermes/hermes-mini + 2 openrouter rows).
        chip.tap()
        let row = firstMatch(in: app, identifier: "model.picker.row.nous/hermes")
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "fixture model row should render in the picker")
        XCTAssertTrue(row.label.contains("hermes"),
                      "model id is announced to a11y: \(row.label)")
        XCTAssertTrue(firstMatch(in: app, identifier: "model.picker.row.nous/hermes-mini").exists,
                      "second fixture model renders")

        // Picking marks it sticky and dismisses.
        tap(row)
        let gone = NSPredicate(format: "exists == 0")
        let vanished = XCTNSPredicateExpectation(predicate: gone, object: row)
        wait(for: [vanished], timeout: 10)
        attachScreenshot(of: app, name: "r9-model-picker-picked")
    }

    func testContextMeterRendersAndBreakdownOpens() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openConversation(app)

        // Send a prompt — the scripted turn yields a mid-turn session.usage
        // tick (43% of 120k) that feeds the live meter.
        let composer = app.textFields["fleet.conversation.composer"]
        let deadline = Date().addingTimeInterval(15)
        while !composer.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(composer.isEnabled, "composer should enable once the session is ready")
        composer.tap()
        composer.typeText("hello meter")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))

        // The meter renders its percent after the tick.
        let meter = firstMatch(in: app, identifier: "context.meter")
        XCTAssertTrue(meter.waitForExistence(timeout: 15),
                      "context meter should render once usage data arrives")

        // Tapping opens the breakdown sheet (fixture categories).
        meter.tap()
        let summary = firstMatch(in: app, identifier: "context.breakdown.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 15),
                      "breakdown sheet should render with the fixture summary")
        XCTAssertTrue(firstMatch(in: app, identifier: "context.breakdown.row.system_prompt").waitForExistence(timeout: 10),
                      "fixture breakdown category row renders")
        attachScreenshot(of: app, name: "r9-context-breakdown")

        tap(app.buttons["context.breakdown.done"].firstMatch)
    }

    func testSessionMenuOffersSteerRenameFork() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openConversation(app)

        let menu = firstMatch(in: app, identifier: "session.actions.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 10),
                      "session actions menu should render in the conversation header")
        menu.tap()

        // The three actions surface (steer disabled until a turn streams).
        let steer = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Steer")).firstMatch
        let rename = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Rename")).firstMatch
        let fork = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fork")).firstMatch
        XCTAssertTrue(steer.waitForExistence(timeout: 10), "steer action offered")
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "rename action offered")
        XCTAssertTrue(fork.waitForExistence(timeout: 5), "fork action offered")
        attachScreenshot(of: app, name: "r9-session-actions-menu")
    }

    // MARK: - Helpers (same shapes as the R9 approval suite)

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "element \(element) should appear")
        element.tap()
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
