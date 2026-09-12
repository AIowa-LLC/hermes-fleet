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
        // remains visible while the rich answer grows. Keep the existence
        // query early, but defer reading accessibility labels until the rich
        // descendants are stable: hosted AX snapshots can stall while the
        // streaming renderer is mutating the tree.
        let userLiteral = app.descendants(matching: .any)["fleet.conversation.row.row-1"]
        XCTAssertTrue(
            userLiteral.waitForExistence(timeout: 10),
            "user-entered Markdown must remain literal")

        // The scripted session starts empty, so the assistant row ID is
        // deterministic. Querying the exact visible identifier keeps this
        // test scoped to the rich row rather than the full AX tree.
        let assistantRow = app.descendants(matching: .any)["fleet.conversation.row.row-2"]

        // The fixture gives these controls unique labels. Query them from the
        // app root because nested AX traversal through the actively streaming
        // assistant row can time out on hosted simulators even when the
        // controls are rendered.
        let copy = app.buttons["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "code Copy affordance must be reachable")

        let safeLink = app.links["Safe link"].firstMatch
        XCTAssertTrue(safeLink.waitForExistence(timeout: 10), "HTTPS link must be reachable")

        // Query the unique rich-text identifier only after the stable rendered
        // descendants are present. During active streaming, a broad AX query
        // can time out on hosted simulators even when the wrapper is rendered.
        let richText = app.descendants(matching: .any)["fleet.rich-text.row-2"]
        XCTAssertTrue(
            richText.waitForExistence(timeout: 15),
            "the active assistant row should use Fleet's streaming rich-text wrapper")

        // Read the combined row labels only after the streaming AX subtree has
        // settled. This preserves both VoiceOver assertions without asking
        // XCTest for a fresh broad snapshot during active Markdown updates.
        // Rich content can auto-scroll the transcript while it settles, so
        // reveal the user row again before resolving its combined label.
        let transcript = app.scrollViews["fleet.conversation.transcript"]
        for _ in 0..<4 {
            if userLiteral.exists { break }
            transcript.swipeDown()
        }
        XCTAssertTrue(userLiteral.waitForExistence(timeout: 10),
                      "the literal user row should remain reachable after rich text settles")
        XCTAssertTrue(
            userLiteral.label.contains("# user **literal**"),
            "user-entered Markdown must remain literal")
        XCTAssertTrue(
            assistantRow.label.contains("Assistant"),
            "assistant speaker semantics must remain visible to VoiceOver")

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
