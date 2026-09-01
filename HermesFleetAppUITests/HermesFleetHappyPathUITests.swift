import XCTest

/// G1 debt: core happy-path UI automation for the §32 dogfood flow.
///
/// Drives the DEBUG build (scripted fleet — 3 gateways, bots, sessions, a
/// scripted conversation that streams a canned turn) end-to-end:
///   Gateways (see the machines) → select a Bot on a machine → Bot detail →
///   open a session → send a task → watch it stream → receive the answer,
///   then return to the fleet and switch machines (multi-gateway).
///
/// The app under test is the Debug build, so `FleetSimulator` provides the
/// deterministic fleet; the streamed answer asserted here is the scripted
/// turn "Hello from the scripted fleet. You said: <text>".
final class HermesFleetHappyPathUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Core happy path (§32 steps 1-7)

    func testHappyPathGatewaysToConversationStreamedAnswer() throws {
        let app = XCUIApplication()
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        // Step 1+2: open the app, see the machines (gateways) available.
        XCTAssertTrue(app.staticTexts["MacBook M5"].waitForExistence(timeout: 10),
                      "Gateways screen should list MacBook M5")
        XCTAssertTrue(app.staticTexts["Gaming 4090"].exists, "Gateways screen should list Gaming 4090")
        XCTAssertTrue(app.staticTexts["Arch Lab"].exists, "Gateways screen should list Arch Lab")

        // Step 3: select a Bot on a specific machine (MacBook M5 → Default).
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.<dev-workstation>"))
        XCTAssertTrue(app.staticTexts["Default"].waitForExistence(timeout: 10),
                      "Bots screen should list the Default bot on MacBook M5")
        XCTAssertTrue(app.staticTexts["Researcher"].exists,
                      "Bots screen should list the Researcher bot on MacBook M5")

        tap(firstMatch(in: app, identifier: "fleet.bots.row.<dev-workstation>#default"))

        // Step 4: open a conversation from Bot detail (session "Fleet setup").
        XCTAssertTrue(app.staticTexts["Identity"].waitForExistence(timeout: 10),
                      "Bot detail should render the identity section")
        tap(firstMatch(in: app, identifier: "fleet.bot-detail.sessions.row.<dev-workstation>.default.s1"))
        XCTAssertTrue(app.textFields["fleet.conversation.composer"].waitForExistence(timeout: 10),
                      "Conversation canvas should open with a composer")

        // Step 5: send a task.
        let composer = app.textFields["fleet.conversation.composer"]
        waitUntilEnabled(composer, timeout: 10)
        composer.tap()
        composer.typeText("hello dogfood")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))

        // Step 6+7: watch Hermes work, receive the streamed answer.
        let answer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Hello from the scripted fleet"))
            .firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15),
                      "Streamed assistant answer should render in the transcript")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "You said: hello dogfood"))
                .firstMatch.exists,
            "The assistant turn should echo the sent task")

        // Evidence: capture the conversation canvas with the streamed answer.
        attachScreenshot(of: app, name: "u4-step5-7-conversation-streamed-answer")
    }

    /// Capture a screenshot attachment for the evidence record (lands in the
    /// .xcresult; exported for docs/U4-dogfood.md).
    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Return to Fleet, switch machine (§32 step 10, multi-gateway)

    func testReturnToFleetSwitchMachine() throws {
        let app = XCUIApplication()
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        XCTAssertTrue(app.staticTexts["MacBook M5"].waitForExistence(timeout: 10))
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.<dev-workstation>"))
        XCTAssertTrue(app.staticTexts["Default"].waitForExistence(timeout: 10))
        tap(firstMatch(in: app, identifier: "fleet.bots.row.<dev-workstation>#default"))
        XCTAssertTrue(app.staticTexts["Identity"].waitForExistence(timeout: 10))

        // Return to the fleet: pop back to the gateway's Bots screen, then back
        // to the Gateways list (root).
        tapBack(in: app)
        XCTAssertTrue(app.staticTexts["Researcher"].waitForExistence(timeout: 10),
                      "Bots screen should reappear after first back")
        tapBack(in: app)
        XCTAssertTrue(app.staticTexts["MacBook M5"].waitForExistence(timeout: 10))

        // Switch machine: select a Bot on a different machine (Gaming 4090).
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.gaming-4090"))
        XCTAssertTrue(app.staticTexts["Default"].waitForExistence(timeout: 10),
                      "Gaming 4090 should expose its Default bot")
        tap(firstMatch(in: app, identifier: "fleet.bots.row.gaming-4090#default"))
        let gamingRoute = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "gaming-4090#default"))
            .firstMatch
        XCTAssertTrue(gamingRoute.waitForExistence(timeout: 10),
                      "Bot detail should show the canonical Gaming 4090 route")
    }

    // MARK: - Helpers

    /// Find the first element (of any type) carrying the identifier.
    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let any = app.descendants(matching: .any)[identifier]
        if any.exists { return any }
        if app.buttons[identifier].exists { return app.buttons[identifier] }
        if app.cells[identifier].exists { return app.cells[identifier] }
        return any
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "element \(element) should appear")
        element.tap()
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(element.isEnabled, "element \(element) should become enabled")
    }

    private func tapBack(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "back button should appear")
        back.tap()
    }
}
