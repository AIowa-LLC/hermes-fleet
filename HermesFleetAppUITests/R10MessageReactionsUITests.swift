import XCTest

/// R10-T2 — deterministic message-reactions UI suite (scripted fleet, no
/// live gateway): long-press a durable transcript row → Tapback palette →
/// emoji lands as a reaction chip under the bubble; re-send same emoji
/// retracts (server semantics surfaced by the scripted seam); Clear
/// removes the user's reaction; the failure hook proves the never-silent
/// error banner + optimistic rollback.
///
/// The `HERMES_FLEET_REACTION_FIXTURE=1` demo hook makes session.resume
/// return two durable row_id-stamped rows (one with a seeded 👀 reaction)
/// — mirroring the real wire: reactions only ride durable history rows.
final class R10MessageReactionsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "missing element: \(identifier)")
        return element
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.isHittable || element.isEnabled, "element not hittable/enabled")
        element.tap()
    }

    private func openConversation(_ app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        tap(app.descendants(matching: .any).matching(identifier: "fleet.gateways.row.<dev-workstation>").firstMatch)
        tap(app.descendants(matching: .any).matching(identifier: "fleet.bots.row.<dev-workstation>#default").firstMatch)
        tap(app.descendants(matching: .any).matching(identifier: "fleet.bot-detail.sessions.row.<dev-workstation>.default.s1").firstMatch)
        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "conversation canvas should open with a composer")
        let deadline = Date().addingTimeInterval(15)
        while !composer.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(composer.isEnabled, "composer should enable once the session is ready")
    }

    /// Long-press the durable user row, react 👍, chip renders.
    func testLongPressReactRendersChip() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_REACTION_FIXTURE"] = "1"
        app.launch()
        openConversation(app)

        // The seeded history reaction renders on the assistant row first
        // (durable read-back).
        _ = firstMatch(in: app, identifier: "fleet.conversation.reaction.chip.👀")

        // Long-press the durable user row → context menu palette.
        let row = firstMatch(in: app, identifier: "fleet.conversation.row.row-1")
        row.press(forDuration: 1.0)

        // Tap the 👍 palette entry (menu items are addressed by their
        // a11y identifier inside the context menu).
        let thumbsUp = app.descendants(matching: .any)
            .matching(identifier: "fleet.conversation.reaction.palette.👍").firstMatch
        XCTAssertTrue(thumbsUp.waitForExistence(timeout: 5), "palette should present on long-press")
        thumbsUp.tap()

        // The reaction chip renders under the user bubble.
        let chip = firstMatch(in: app, identifier: "fleet.conversation.reaction.chip.👍")
        XCTAssertTrue(chip.label.contains("👍"), "chip label carries the emoji: \(chip.label)")
    }

    /// Re-send the SAME emoji on a row the user already reacted to → the
    /// server retracts it (scripted seam mirrors the DB semantics); the
    /// chip disappears.
    func testResendSameEmojiRetracts() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_REACTION_FIXTURE"] = "1"
        app.launch()
        openConversation(app)

        // The assistant row carries the seeded user 👀 reaction.
        _ = firstMatch(in: app, identifier: "fleet.conversation.reaction.chip.👀")

        // Long-press the assistant row (row-2) and re-send 👀.
        let row = firstMatch(in: app, identifier: "fleet.conversation.row.row-2")
        row.press(forDuration: 1.0)
        let eyes = app.descendants(matching: .any)
            .matching(identifier: "fleet.conversation.reaction.palette.👀").firstMatch
        XCTAssertTrue(eyes.waitForExistence(timeout: 5), "palette should present on long-press")
        eyes.tap()

        // The retracted chip disappears (bounded wait).
        let chip = app.descendants(matching: .any)
            .matching(identifier: "fleet.conversation.reaction.chip.👀").firstMatch
        let deadline = Date().addingTimeInterval(10)
        while chip.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertFalse(chip.exists, "re-sending the same emoji must retract the reaction")
    }

    /// The failure hook: react throws 4040 — the error banner surfaces
    /// (never silent) and the optimistic chip rolls back.
    func testWireFailureSurfacesErrorBannerAndRollsBack() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_REACTION_FIXTURE"] = "1"
        app.launchEnvironment["HERMES_FLEET_REACTION_FAIL"] = "1"
        app.launch()
        openConversation(app)

        let row = firstMatch(in: app, identifier: "fleet.conversation.row.row-1")
        row.press(forDuration: 1.0)
        let thumbsUp = app.descendants(matching: .any)
            .matching(identifier: "fleet.conversation.reaction.palette.👍").firstMatch
        XCTAssertTrue(thumbsUp.waitForExistence(timeout: 5), "palette should present on long-press")
        thumbsUp.tap()

        // Never-silent banner carries the honest failure.
        let banner = firstMatch(in: app, identifier: "fleet.conversation.reaction.error")
        XCTAssertTrue(banner.label.contains("message not found") || banner.label.contains("fixture"),
                      "banner carries the honest failure: \(banner.label)")

        // The optimistic chip rolled back (bounded wait).
        let chip = app.descendants(matching: .any)
            .matching(identifier: "fleet.conversation.reaction.chip.👍").firstMatch
        let deadline = Date().addingTimeInterval(10)
        while chip.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertFalse(chip.exists, "optimistic reaction must roll back on wire failure")
    }
}
