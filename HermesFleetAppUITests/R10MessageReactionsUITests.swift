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
        tap(app.descendants(matching: .any).matching(identifier: "fleet.gateways.row.workstation").firstMatch)
        tap(app.descendants(matching: .any).matching(identifier: "fleet.bots.row.workstation#default").firstMatch)
        tap(app.descendants(matching: .any).matching(identifier: "fleet.bot-detail.sessions.row.workstation.default.s1").firstMatch)
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
        let rollbackDeadline = Date().addingTimeInterval(10)
        while chip.exists && Date() < rollbackDeadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertFalse(chip.exists, "optimistic reaction must roll back on wire failure")
    }

    /// QA round-1 defect regression (live path): react to a LIVE row — one
    /// streamed this session with no durable row_id (newest_role on the
    /// wire). The chip must SURVIVE the settle, so a second long-press
    /// offers Clear Reaction (pre-fix the settle dropped the live-* key
    /// while the row still projected through it: the chip vanished on
    /// SUCCESS and Clear was unreachable). Clearing then removes the chip.
    /// No REACTION_FIXTURE here: the transcript starts empty, so the sent
    /// user row is live (row-1, row_id-less) — the scripted seam resolves
    /// newest_role to its fixed durable row exactly like the gateway's
    /// latest_message_row_id.
    func testLiveRowReactKeepsChipAfterSettleAndClearWorks() throws {
        let app = XCUIApplication()
        app.launch()
        openConversation(app)

        // Send a prompt — the user row (row-1) is LIVE (no durable row_id);
        // the scripted assistant turn completes the exchange.
        let composer = app.textFields["fleet.conversation.composer"]
        composer.tap()
        composer.typeText("react to me")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))
        let reply = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Hello from the scripted fleet")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "scripted assistant turn should stream in")

        // Long-press the LIVE user row → react 👍 (newest_role on the wire).
        let row = firstMatch(in: app, identifier: "fleet.conversation.row.row-1")
        row.press(forDuration: 1.0)
        let thumbsUp = app.descendants(matching: .any)
            .matching(identifier: "fleet.conversation.reaction.palette.👍").firstMatch
        XCTAssertTrue(thumbsUp.waitForExistence(timeout: 5), "palette should present on long-press")
        thumbsUp.tap()

        // The chip must survive the settle — bounded wait for it to EXIST,
        // then it must STILL exist (the settle lands within moments; the
        // Clear check below is the deterministic guard either way).
        let chip = firstMatch(in: app, identifier: "fleet.conversation.reaction.chip.👍")
        XCTAssertTrue(chip.label.contains("👍"), "chip label carries the emoji: \(chip.label)")

        // A settled own reaction keeps Clear Reaction reachable — the
        // QA-repro'd side effect of the defect was that it never appeared.
        row.press(forDuration: 1.0)
        let clear = app.descendants(matching: .any)
            .matching(identifier: "fleet.conversation.reaction.clear").firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5),
                      "Clear Reaction must be offered on a row the user reacted to (chip survived settle)")
        clear.tap()

        // The chip clears.
        let gone = app.descendants(matching: .any)
            .matching(identifier: "fleet.conversation.reaction.chip.👍").firstMatch
        let deadline = Date().addingTimeInterval(10)
        while gone.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertFalse(gone.exists, "clearing the live-row reaction removes the chip")
    }
}
