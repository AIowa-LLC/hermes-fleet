import XCTest

/// Issue #5 deterministic UI coverage. The scripted simulator emits the same
/// ordinary message.start/delta/complete event shape as existing tests, but
/// the explicit launch argument makes its assistant answer cross Markdown
/// syntax boundaries so this exercises the live presentation lifecycle.
@MainActor
final class Issue5StreamingRichTextUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAssistantMarkdownStreamsWhileUserMarkdownStaysLiteral() throws {
        let app = launch()
        openConversation(app)

        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("# user **literal**")
        tap(app.descendants(matching: .any)["fleet.conversation.send"])

        // The scripted fixture pauses after message.start, so the user row
        // remains visible before the rich answer grows past the viewport.
        let userLiteral = app.descendants(matching: .any)["fleet.conversation.row.row-1"]
        XCTAssertTrue(
            userLiteral.waitForExistence(timeout: 10),
            "user-entered Markdown must remain literal")
        XCTAssertTrue(
            userLiteral.label.contains("# user **literal**"),
            "user-entered Markdown must remain literal")

        // The scripted session starts empty, so the assistant row ID is
        // deterministic. Querying the exact visible identifier keeps this
        // test scoped to the rich row rather than the full AX tree.
        let assistantRow = app.descendants(matching: .any)["fleet.conversation.row.row-2"]
        let richText = assistantRow.descendants(matching: .any)["fleet.rich-text.row-2"]
        XCTAssertTrue(
            richText.waitForExistence(timeout: 15),
            "the active assistant row should use Fleet's streaming rich-text wrapper")

        XCTAssertTrue(assistantRow.label.contains("Assistant"), "assistant speaker semantics must remain visible to VoiceOver")

        // The dependency's code block control and link text must remain
        // reachable descendants of the contained assistant row.
        let copy = assistantRow.buttons["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "code Copy affordance must be reachable")

        let safeLink = assistantRow.links["Safe link"]
        XCTAssertTrue(safeLink.waitForExistence(timeout: 10), "HTTPS link must be reachable")

        XCTAssertFalse(
            assistantRow.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "javascript:"))
                .firstMatch.exists,
            "unsafe schemes must not become interactive or visible link destinations")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-issue5-markdown-fixture"]
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        return app
    }

    private func openConversation(_ app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        tap(app.descendants(matching: .any)["fleet.gateways.row.workstation"])
        UITabNavigation.openGatewayBots(app, gateway: "workstation")
        tap(app.descendants(matching: .any)["fleet.roster.row.workstation#default"])
        tap(app.descendants(matching: .any)["fleet.bot-detail.sessions.row.workstation.default.s1"])

        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(15)
        while !composer.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(composer.isEnabled, "composer should enable after session open")
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "required UI element should appear")
        element.tap()
    }
}
