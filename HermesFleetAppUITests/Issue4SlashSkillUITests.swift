import XCTest

/// Issue #4 — deterministic end-to-end slash-skill coverage.
///
/// The app is driven through the DEBUG scripted fleet. The suite deliberately
/// uses the composer, palette buttons, and transcript accessibility identifiers
/// so it proves the user-visible invocation contract rather than only testing
/// the view model or transport seam.
@MainActor
final class Issue4SlashSkillUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSkillPaletteFiltersInsertsDispatchesAndStreams() throws {
        let app = launch()
        openConversation(app)

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/")

        let palette = element(in: app, identifier: "fleet.conversation.skill.palette")
        XCTAssertTrue(palette.waitForExistence(timeout: 10), "Skills palette should appear after typing /")
        let review = element(in: app, identifier: "fleet.conversation.skill.hermes-change-review")
        let plan = element(in: app, identifier: "fleet.conversation.skill.hermes-plan")
        XCTAssertTrue(review.waitForExistence(timeout: 10), "scripted review skill should appear")
        XCTAssertTrue(plan.waitForExistence(timeout: 10), "scripted plan skill should appear")

        composer.typeText("hermes-c")
        XCTAssertTrue(review.waitForExistence(timeout: 10), "partial completion should retain the matching skill")
        XCTAssertTrue(waitUntilGone(plan), "partial completion should remove the non-matching skill")

        tap(review)
        XCTAssertTrue(
            waitForComposerValue(composer, equals: "/hermes-change-review "),
            "selection should insert the canonical slash token and retain focus"
        )
        composer.typeText("review this issue")
        XCTAssertEqual(composerValue(composer), "/hermes-change-review review this issue")

        tap(element(in: app, identifier: "fleet.conversation.send"))
        XCTAssertTrue(
            waitForComposerValue(composer, equals: ""),
            "the composer should clear after successful skill dispatch (current value: \(composerValue(composer)))"
        )

        let user = conversationRow(in: app, containing: "review this issue")
        XCTAssertNotNil(user, "successful dispatch should create a user bubble")
        guard let user else { return }
        XCTAssertTrue(
            user.label.contains("/hermes-change-review review this issue"),
            "the user bubble should show the human-facing invocation: \(user.label)"
        )
        XCTAssertFalse(
            user.label.contains("Scripted expanded skill"),
            "expanded model scaffolding must not be shown in the user bubble: \(user.label)"
        )

        XCTAssertNotNil(
            conversationRow(in: app, containing: "Hello from the scripted fleet", timeout: 15),
            "the streamed assistant response should render")
        XCTAssertNil(
            conversationRow(in: app, containing: "Scripted expanded skill", timeout: 2),
            "expanded skill scaffolding must remain hidden from the transcript UI")
    }

    func testSlashEditingBackspaceDismissesPaletteWithoutCorruptingText() throws {
        let app = launch()
        openConversation(app)

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/")
        let palette = element(in: app, identifier: "fleet.conversation.skill.palette")
        XCTAssertTrue(palette.waitForExistence(timeout: 10))

        let review = element(in: app, identifier: "fleet.conversation.skill.hermes-change-review")
        tap(review)
        XCTAssertTrue(waitForComposerValue(composer, equals: "/hermes-change-review "))
        composer.typeText("notes")
        XCTAssertEqual(composerValue(composer), "/hermes-change-review notes")

        clearComposer(composer)
        XCTAssertTrue(waitForComposerValue(composer, equals: ""), "backspace should remove the selected invocation")
        XCTAssertTrue(waitUntilGone(palette), "removing / should dismiss slash mode")

        composer.typeText("ordinary draft")
        XCTAssertEqual(composerValue(composer), "ordinary draft", "ordinary editing should remain intact after dismissal")
        XCTAssertFalse(palette.exists, "ordinary text should not reopen the Skills palette")
    }

    func testEmptySkillCatalogShowsHonestEmptyState() throws {
        let app = launch()
        openConversation(app, gateway: "workstation", profile: "default", sessionID: "workstation.default.s2")

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/")

        let palette = element(in: app, identifier: "fleet.conversation.skill.palette")
        XCTAssertTrue(palette.waitForExistence(timeout: 10), "empty catalog should still render the Skills palette")
        let empty = element(in: app, identifier: "fleet.conversation.skill.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "empty catalog should explain that no skills are available")
        XCTAssertTrue(empty.label.contains("No skills available"), "empty state should be understandable: \(empty.label)")
        XCTAssertFalse(element(in: app, identifier: "fleet.conversation.skill.hermes-change-review").exists)
    }

    func testDiscoveryFailureShowsInlineErrorAndOrdinaryChatStillWorks() throws {
        let app = launch()
        openConversation(app, gateway: "workstation", profile: "researcher", sessionID: "workstation.researcher.s1")

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/")

        let error = element(in: app, identifier: "fleet.conversation.skill.error")
        XCTAssertTrue(error.waitForExistence(timeout: 10), "discovery failure should be shown inline")
        XCTAssertTrue(error.label.lowercased().contains("failed"), "discovery failure should be understandable: \(error.label)")
        XCTAssertEqual(composerValue(composer), "/", "discovery failure must not destroy composer text")

        composer.typeText(XCUIKeyboardKey.delete.rawValue)
        composer.typeText("ordinary after discovery failure")
        tap(element(in: app, identifier: "fleet.conversation.send"))

        XCTAssertNotNil(
            conversationRow(in: app, containing: "ordinary after discovery failure"),
            "ordinary chat should remain available after discovery failure")
        XCTAssertNotNil(
            conversationRow(in: app, containing: "Hello from the scripted fleet", timeout: 15),
            "ordinary chat should still stream a response")
    }

    func testStaleSkillDispatchFailsClosedKeepsTextAndAllowsOrdinaryChat() throws {
        let app = launch()
        openConversation(app, gateway: "render-box", profile: "default", sessionID: "workstation.default.s1")

        let composer = composer(in: app)
        composer.tap()
        composer.typeText("/hermes-change-review stale invocation")
        let invocation = composerValue(composer)
        tap(element(in: app, identifier: "fleet.conversation.send"))

        let error = element(in: app, identifier: "fleet.conversation.skill.error")
        XCTAssertTrue(error.waitForExistence(timeout: 10), "stale dispatch should show an inline error")
        XCTAssertTrue(error.label.contains("no longer an available skill"), "stale error should be actionable: \(error.label)")
        XCTAssertEqual(composerValue(composer), invocation, "failed dispatch should leave slash text editable")
        XCTAssertFalse(
            conversationRow(in: app, containing: "stale invocation", timeout: 2) != nil,
            "stale slash dispatch must not submit through ordinary prompt.submit"
        )

        clearComposer(composer)
        composer.typeText("ordinary after stale dispatch")
        tap(element(in: app, identifier: "fleet.conversation.send"))

        XCTAssertNotNil(
            conversationRow(in: app, containing: "ordinary after stale dispatch"),
            "ordinary chat should work after fixing stale slash input")
        XCTAssertTrue(waitForComposerValue(composer, equals: ""), "successful ordinary send should clear the composer")
        XCTAssertNotNil(
            conversationRow(in: app, containing: "Hello from the scripted fleet", timeout: 15),
            "ordinary chat should stream after stale dispatch")
    }

    // MARK: - Deterministic scripted conversation helpers

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

    private func clearComposer(_ composer: XCUIElement) {
        let text = composerValue(composer)
        guard !text.isEmpty else { return }
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
    }
}
