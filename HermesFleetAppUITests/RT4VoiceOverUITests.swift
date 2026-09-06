import XCTest

/// RT4 P2-7 UI regression: conversation transcript rows expose VoiceOver
/// speaker semantics (User / Assistant / Tool / Status / System / Error) and
/// live-state values (Streaming / Failed), instead of a bare combined bubble
/// text that hides who spoke.
///
/// Drives the DEBUG scripted fleet: open a conversation, send a task, and let
/// the canned turn stream + complete. RED (old): the assistant row's
/// accessibility label was just the raw bubble text (no "Assistant" speaker),
/// so `label CONTAINS 'Assistant'` matched nothing. GREEN (fix): each row's
/// label carries the speaker + content.
final class RT4VoiceOverUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testConversationRowExposesSpeakerLabel() throws {
        let app = XCUIApplication()
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        // Navigate: Gateways → Workstation → Default bot → a session.
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10))
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        XCTAssertTrue(app.staticTexts["Default"].waitForExistence(timeout: 10))
        tap(firstMatch(in: app, identifier: "fleet.bots.row.workstation#default"))
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10))
        tap(firstMatch(in: app, identifier: "fleet.bot-detail.sessions.row.workstation.default.s1"))
        XCTAssertTrue(app.textFields["fleet.conversation.composer"].waitForExistence(timeout: 10))

        // Send a task; the scripted fleet streams a canned answer.
        let composer = app.textFields["fleet.conversation.composer"]
        waitUntilEnabled(composer, timeout: 10)
        composer.tap()
        composer.typeText("hello accessibility")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))

        // Wait for the completed assistant turn, then assert its VoiceOver
        // label exposes the "Assistant" speaker.
        let assistant = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                                  "Assistant", "Hello from the scripted fleet"))
            .firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 15),
                      "P2-7: assistant row must expose an 'Assistant' speaker label to VoiceOver")
        attachScreenshot(of: app, name: "rt4-p2-7-voiceover-speaker-label")
    }

    // MARK: - Helpers

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let any = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if any.exists { return any }
        let btn = app.buttons[identifier].firstMatch
        if btn.exists { return btn }
        let cell = app.cells[identifier].firstMatch
        if cell.exists { return cell }
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

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
