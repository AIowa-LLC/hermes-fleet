import XCTest

/// Slash-command parity — deterministic composer journeys through the DEBUG
/// scripted fleet: browsing shows Commands + Skills sections; built-in
/// commands execute through their native Fleet routes; a terminal-only
/// command is honestly unavailable; dynamic extension commands execute;
/// prefill fills the composer without submitting.
@MainActor
final class SlashCommandParityUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Browsing + completion

    func testBareSlashShowsCommandsAndSkillsSectionsAndFilters() throws {
        let app = launch()
        openConversation(app)

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/")

        let palette = element(in: app, identifier: "fleet.conversation.command.palette")
        XCTAssertTrue(palette.waitForExistence(timeout: 10), "palette should appear after /")

        // Commands section: built-ins visible.
        XCTAssertTrue(element(in: app, identifier: "fleet.conversation.command.new").waitForExistence(timeout: 10),
                      "/new should appear")
        XCTAssertTrue(element(in: app, identifier: "fleet.conversation.command.steer").exists,
                      "/steer should appear")
        // Extension command surfaces without a Fleet release.
        XCTAssertTrue(element(in: app, identifier: "fleet.conversation.command.deploy-check").exists,
                      "dynamic quick command should appear")
        // Skills section: installed skills appear.
        XCTAssertTrue(element(in: app, identifier: "fleet.conversation.command.hermes-change-review").exists,
                      "installed skill should appear")

        // Terminal-only never surfaces.
        XCTAssertFalse(element(in: app, identifier: "fleet.conversation.command.redraw").exists,
                       "terminal-only /redraw must not be suggested")
        // Alias rows never surface.
        XCTAssertFalse(element(in: app, identifier: "fleet.conversation.command.reset").exists,
                       "alias /reset must not duplicate /new")

        // Typed query narrows.
        composer.typeText("ste")
        XCTAssertTrue(element(in: app, identifier: "fleet.conversation.command.steer").waitForExistence(timeout: 10),
                      "/ste narrows to /steer")
        XCTAssertTrue(waitUntilGone(element(in: app, identifier: "fleet.conversation.command.new")),
                      "/new should filter out of the /ste query")
    }

    func testSelectingCommandInsertsTokenWithoutExecuting() throws {
        let app = launch()
        openConversation(app)

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/ste")
        let steer = element(in: app, identifier: "fleet.conversation.command.steer")
        XCTAssertTrue(steer.waitForExistence(timeout: 10))
        tap(steer)
        XCTAssertTrue(
            waitForComposerValue(composer, equals: "/steer "),
            "selection inserts the token and a trailing space, never executes"
        )
    }

    // MARK: - /steer native action

    func testSteerExecutesWithoutUserBubble() throws {
        let app = launch()
        openConversation(app)

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/steer focus on the auth flow")
        tap(element(in: app, identifier: "fleet.conversation.send"))

        XCTAssertTrue(
            waitForComposerValue(composer, equals: ""),
            "composer clears after an accepted steer"
        )
        // Steer never creates a user turn.
        XCTAssertNil(conversationRow(in: app, containing: "focus on the auth flow"),
                     "steer guidance must not render as a user message")
    }

    // MARK: - /stop native action

    func testStopRendersHonestResultRow() throws {
        let app = launch()
        openConversation(app)

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/stop")
        tap(element(in: app, identifier: "fleet.conversation.send"))

        // With no active turn and one scripted background process killed.
        XCTAssertNotNil(
            conversationRow(in: app, containing: "No active turn to stop"),
            "/stop reports honestly when nothing streams"
        )
        XCTAssertNotNil(
            conversationRow(in: app, containing: "Stopped 1 background process"),
            "/stop includes background-process cleanup"
        )
    }

    // MARK: - /title native action

    func testTitleRenamesSession() throws {
        let app = launch()
        openConversation(app)

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/title Renamed by command")
        tap(element(in: app, identifier: "fleet.conversation.send"))

        XCTAssertTrue(
            waitForComposerValue(composer, equals: ""),
            "composer clears after a successful rename"
        )
    }

    // MARK: - /new native action

    func testNewStartsFreshConversation() throws {
        let app = launch()
        openConversation(app)

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/new")
        tap(element(in: app, identifier: "fleet.conversation.send"))

        // /new pushes another ConversationView while the previous screen
        // remains in the navigation stack. Both fields share the stable
        // composer ID, so resolve the topmost destination explicitly.
        let composers = app.textFields.matching(identifier: "fleet.conversation.composer")
        XCTAssertTrue(composers.firstMatch.waitForExistence(timeout: 10),
                      "the pushed conversation should expose its composer")
        // iOS versions differ on whether the covered NavigationStack view is
        // still represented in the accessibility tree. Select the last
        // ordered match, which is the visible destination on versions that
        // expose both composers and the sole match otherwise.
        guard let freshComposer = composers.allElementsBoundByIndex.last else {
            XCTFail("the pushed conversation should expose its composer")
            return
        }
        XCTAssertTrue(
            waitForComposerValue(freshComposer, equals: ""),
            "the fresh conversation composer is empty after /new"
        )
        XCTAssertNil(conversationRow(in: app, containing: "Hello from the scripted fleet"),
                     "the fresh conversation must not show the old transcript")
    }

    // MARK: - /status dedicated RPC

    func testStatusRendersStructuredOutputRow() throws {
        let app = launch()
        openConversation(app)

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/status")
        tap(element(in: app, identifier: "fleet.conversation.send"))

        XCTAssertNotNil(
            conversationRow(in: app, containing: "Session ID:"),
            "/status renders its output as a transcript row"
        )
    }

    // MARK: - Backend exec

    func testBackendExecCommandRendersOutputRow() throws {
        let app = launch()
        openConversation(app)

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/usage")
        tap(element(in: app, identifier: "fleet.conversation.send"))

        XCTAssertNotNil(
            conversationRow(in: app, containing: "Session tokens:"),
            "backend exec output renders inline"
        )
    }

    // MARK: - Terminal-only honesty

    func testTerminalCommandIsHonestlyUnavailable() throws {
        let app = launch()
        openConversation(app)

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/redraw")
        tap(element(in: app, identifier: "fleet.conversation.send"))

        let error = element(in: app, identifier: "fleet.conversation.command.error")
        XCTAssertTrue(error.waitForExistence(timeout: 10),
                      "terminal-only command reports its unavailability")
        XCTAssertTrue(error.label.contains("Hermes terminal"),
                      "the message should name the terminal surface: \(error.label)")
        XCTAssertEqual(composerValue(composer), "/redraw",
                       "the failed command stays editable")
    }

    // MARK: - Prefill

    func testPrefillFillsComposerWithoutSubmitting() throws {
        let app = launch()
        openConversation(app)

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/undo")
        tap(element(in: app, identifier: "fleet.conversation.send"))

        XCTAssertTrue(
            waitForComposerValue(composer, equals: "Edited follow-up prompt"),
            "prefill replaces the composer draft"
        )
        XCTAssertNil(conversationRow(in: app, containing: "Edited follow-up prompt"),
                     "prefill must not submit")
    }

    // MARK: - Unknown dispatch fails closed

    func testUnknownDispatchFailsClosedWithUnderstandableMessage() throws {
        let app = launch()
        openConversation(app)

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/future-probe")
        tap(element(in: app, identifier: "fleet.conversation.send"))

        XCTAssertNotNil(
            conversationRow(in: app, containing: "does not understand"),
            "unknown dispatch reports honestly in the transcript"
        )
    }

    // MARK: - Deterministic scripted conversation helpers
    // (Mirrors Issue4SlashSkillUITests' proven navigation path.)

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        var environment = app.launchEnvironment
        environment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment = environment
        app.launch()
        return app
    }

    private func openConversation(
        _ app: XCUIApplication,
        gateway: String = "workstation",
        profile: String = "default",
        sessionID: String = "workstation.default.s1"
    ) {
        UITabNavigation.openGatewaysTab(app)
        tap(element(in: app, identifier: "fleet.gateways.row.\(gateway)"))
        UITabNavigation.openGatewayBots(app, gateway: gateway)
        tap(element(in: app, identifier: "fleet.roster.row.\(gateway)#\(profile)"))
        tap(element(in: app, identifier: "fleet.bot-detail.sessions.row.\(sessionID)"))
        let field = composer(in: app)
        let deadline = Date().addingTimeInterval(15)
        while !field.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(field.isEnabled, "composer should enable after the scripted session opens")
    }

    private func composer(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "conversation composer should render")
        return field
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func conversationRow(
        in app: XCUIApplication,
        containing text: String,
        timeout: TimeInterval = 10
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "fleet.conversation.row."))
        while Date() < deadline {
            for row in rows.allElementsBoundByIndex where row.label.contains(text) {
                return row
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return rows.allElementsBoundByIndex.first(where: { $0.label.contains(text) })
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "missing element to tap")
        XCTAssertTrue(element.isHittable || element.isEnabled, "element should be hittable or enabled")
        element.tap()
    }

    private func composerValue(_ composer: XCUIElement) -> String {
        composer.value as? String ?? ""
    }

    private func waitForComposerValue(
        _ composer: XCUIElement,
        equals expected: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if composerMatches(composer, expected: expected) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return composerMatches(composer, expected: expected)
    }

    private func composerMatches(_ composer: XCUIElement, expected: String) -> Bool {
        let value = composerValue(composer)
        // SwiftUI exposes the TextField placeholder as its accessibility value
        // when the bound text is empty.
        return expected.isEmpty ? value.isEmpty || value == "Message" : value == expected
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !element.exists
    }
}
