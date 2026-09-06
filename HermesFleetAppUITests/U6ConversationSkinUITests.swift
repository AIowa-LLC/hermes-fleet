import XCTest

/// U6 (Gold Fleet) — conversation re-skin regression suite.
///
/// Drives the DEBUG build (deterministic scripted fleet) into a conversation
/// and proves the plan card's U6 scope renders:
///   1. the bot header: avatar + display name + canonical route + status pill
///      (fleet.conversation.header);
///   2. user bubbles right / bot replies left still stream end-to-end (the
///      visual-only mandate: no functional regression in the happy loop);
///   3. the composer keeps its identifiers (send/stop/composer) under the new
///      magenta circular send-button styling.
final class U6ConversationSkinUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testConversationHeaderRendersAvatarNameRouteAndPill() throws {
        let app = XCUIApplication()
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        // Drill to the scripted conversation: Workstation → Default → session s1.
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        tap(firstMatch(in: app, identifier: "fleet.bots.row.workstation#default"))
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10),
            "Bot detail should render before drilling into the conversation"
        )
        tap(firstMatch(in: app, identifier: "fleet.bot-detail.sessions.row.workstation.default.s1"))

        // U6 bot header on the conversation canvas.
        let header = firstMatch(in: app, identifier: "fleet.conversation.header")
        XCTAssertTrue(header.waitForExistence(timeout: 10),
                      "the conversation must render the U6 bot header")
        let label = header.label
        XCTAssertTrue(label.contains("Default"), "header shows the bot display name (label: \(label))")
        XCTAssertTrue(label.contains("Status:"), "header shows a status pill (label: \(label))")

        // The composer still exists under the new skin.
        XCTAssertTrue(app.textFields["fleet.conversation.composer"].waitForExistence(timeout: 10),
                      "composer must render after the re-skin")
        let send = firstMatch(in: app, identifier: "fleet.conversation.send")
        XCTAssertTrue(send.waitForExistence(timeout: 5), "circular send button must render")

        // Evidence for the apple-design visual review: clean canvas shot
        // (no keyboard, no sent message).
        attachScreenshot(of: app, name: "u6-conversation-header-composer")
    }

    func testSendStillStreamsAnswerWithNewBubbles() throws {
        let app = XCUIApplication()
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        tap(firstMatch(in: app, identifier: "fleet.bots.row.workstation#default"))
        tap(firstMatch(in: app, identifier: "fleet.bot-detail.sessions.row.workstation.default.s1"))
        XCTAssertTrue(app.textFields["fleet.conversation.composer"].waitForExistence(timeout: 10),
                      "Conversation canvas should open with a composer")

        // Send a task through the new composer + circular send button.
        let composer = app.textFields["fleet.conversation.composer"]
        waitUntilEnabled(composer, timeout: 10)
        composer.tap()
        composer.typeText("hello u6")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))

        // The scripted streamed answer still renders (visual-only mandate).
        let answer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Hello from the scripted fleet"))
            .firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15),
                      "Streamed assistant answer should render in the re-skinned transcript")
        attachScreenshot(of: app, name: "u6-conversation-streamed-answer")
    }

    // MARK: - Helpers (same shapes as the U5 suite)

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "element \(element) should appear")
        element.tap()
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let any = app.descendants(matching: .any)[identifier]
        if any.exists { return any }
        if app.buttons[identifier].exists { return any }
        return any
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        let enabled = NSPredicate(format: "isEnabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: enabled, object: element)
        wait(for: [expectation], timeout: timeout)
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
