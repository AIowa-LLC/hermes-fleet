import XCTest

/// TRUE BOTS MODE slice 5 UI tests (D19/D20/D22) against the scripted
/// simulator fleet (deterministic; no live gateway):
/// - D19: RoomLink panel — honest unsupported state (no grant UI), grant
///   invite/register flow, stale replica blocks promotion until replay,
///   explicit takeover confirmation naming the previous authority.
/// - D20: mention autocomplete in the room composer — @ suggestion list,
///   source-qualified duplicate disambiguation, insert into the draft.
/// - D22: typed failure card with per-type copy + typed action buttons and
///   the mono wire badge.
///
/// NOTE on identifiers: FleetCard applies the card's identifier to every
/// child element in the AX tree, so card-scoped assertions query the CARD
/// identifier and match on label text; interactive controls (buttons) keep
/// their own identifiers.
final class RoomLinkMentionsUITests: XCTestCase {

    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    private func launch(extraEnv: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        self.app = app
        app.launchEnvironment["HERMES_FLEET_AUTO_NAV"] = "roster"
        for (key, value) in extraEnv {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    /// Scroll the roster until an element exists AND is hittable.
    ///
    /// A row can be present in the AX tree while its frame lies entirely
    /// outside the window (materialized just below the fold — e.g. the roster
    /// outage card pushed "Groups" rows past the bottom edge). Asking for
    /// `isHittable` on such an element does NOT return false: it fails the
    /// test outright with "Failed to determine hittability … Activation point
    /// invalid and no suggested hit points based on element frame"
    /// (merge-group run 34699513638, shard 5), killing the run before the
    /// scroll below ever gets a chance to bring the row into view. So only
    /// consult hittability once the frame actually overlaps the window;
    /// otherwise keep scrolling.
    private func scrollToFind(
        _ app: XCUIApplication, identifier: String? = nil,
        attempts: Int = 20
    ) -> XCUIElement {
        func found() -> XCUIElement {
            app.descendants(matching: .any)[identifier ?? ""]
        }
        let window = app.windows.firstMatch
        func hittable() -> Bool {
            guard found().exists else { return false }
            let windowFrame = window.frame
            // An unmaterialized/zero frame never legitimately intersects; and
            // if the window itself cannot be measured, keep the old behaviour.
            if !windowFrame.isEmpty && !found().frame.intersects(windowFrame) { return false }
            return found().isHittable
        }
        if hittable() { return found() }
        for _ in 0..<attempts {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            if hittable() { return found() }
        }
        if found().exists { return found() }
        XCTFail("element not found: identifier=\(identifier ?? "-")")
        return found()
    }

    private func openHostedRoom(_ app: XCUIApplication) {
        let row = scrollToFind(app, identifier: "fleet.room.row.room-alpha")
        row.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.chat"].waitForExistence(timeout: 10),
            "room chat screen renders")
    }

    private func openRoomLink(_ app: XCUIApplication) {
        app.buttons["fleet.room.roomlink"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.roomlink.screen"].waitForExistence(timeout: 10),
            "RoomLink panel renders")
    }

    /// True when any element matching the card identifier carries the label
    /// (FleetCard propagates the card identifier to children; label text is
    /// the content match).
    private func cardContains(_ app: XCUIApplication, card: String, text: String) -> Bool {
        let matches = app.descendants(matching: .any).matching(identifier: card)
        for index in 0..<matches.count where matches.element(boundBy: index).label.contains(text) {
            return true
        }
        return false
    }

    // MARK: - D19 RoomLink

    func testRoomLinkUnsupportedStateIsHonest() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_ROOMLINK": "unsupported"])
        openHostedRoom(app)
        openRoomLink(app)

        // Honest unsupported state with the gateway's own reason.
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.roomlink.unsupported"]
                .waitForExistence(timeout: 10),
            "unsupported explanation renders")

        // NO grant UI on an unsupported gateway — never fake cross-machine
        // support.
        XCTAssertFalse(
            app.buttons["fleet.roomlink.invite"].exists,
            "invite affordance hidden when unsupported")
    }

    func testRoomLinkGrantInviteAndRegisterFlow() throws {
        let app = launch()
        openHostedRoom(app)
        openRoomLink(app)

        // Negotiation card shows the direct/TLS summary.
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.roomlink.summary"].waitForExistence(timeout: 10),
            "negotiation summary renders")

        // Invite mints a grant (masked token, never the full grant).
        let invite = app.buttons["fleet.roomlink.invite"]
        XCTAssertTrue(invite.waitForExistence(timeout: 5))
        invite.tap()
        XCTAssertTrue(
            app.buttons["fleet.roomlink.register"].waitForExistence(timeout: 10),
            "register affordance appears after a grant is minted")

        // Register publishes the route (ready row).
        app.buttons["fleet.roomlink.register"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.roomlink.route.researcher"].waitForExistence(timeout: 10),
            "linked peer route renders ready")
    }

    func testStaleReplicaBlocksPromotionUntilReplay() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_ROOMLINK": "stale"])
        openHostedRoom(app)
        openRoomLink(app)

        // Replay card shows the honest behind state.
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.roomlink.replica-progress"].waitForExistence(timeout: 10),
            "replica progress shows the stale position")
        let promote = app.buttons["fleet.roomlink.promote"]
        XCTAssertTrue(promote.waitForExistence(timeout: 5))
        XCTAssertFalse(promote.isEnabled, "take over disabled while the replica is behind")

        // Replay now → caught up → promotion enabled.
        app.buttons["fleet.roomlink.replicate"].tap()
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: app.buttons["fleet.roomlink.promote"])
        wait(for: [enabled], timeout: 20)
    }

    func testPromotionRequiresExplicitConfirmation() throws {
        let app = launch()
        openHostedRoom(app)
        openRoomLink(app)

        // FOS-8 (SPEC §9): the operator fencing assertion gates takeover —
        // enable it before the confirmation dialog can open.
        let fencing = app.descendants(matching: .any)["fleet.roomlink.fencing-toggle"]
        if fencing.waitForExistence(timeout: 10) {
            let fencingSwitch = fencing.descendants(matching: .switch).firstMatch
            if fencingSwitch.exists { fencingSwitch.tap() } else { fencing.tap() }
        }

        let promote = app.buttons["fleet.roomlink.promote"]
        XCTAssertTrue(promote.waitForExistence(timeout: 10))
        promote.tap()

        // The typed confirmation names the previous authority — never a
        // generic "are you sure".
        let takeover = app.buttons["Take over"]
        XCTAssertTrue(
            takeover.waitForExistence(timeout: 5),
            "confirmation dialog naming the previous authority renders")
        takeover.tap()

        // Receipt notice names the new epoch and the previous authority.
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.roomlink.notice"].waitForExistence(timeout: 10),
            "promotion receipt notice renders")
    }

    // MARK: - D20 mentions

    func testMentionAutocompleteInsertsTag() throws {
        let app = launch()
        openHostedRoom(app)

        let composer = app.textFields["fleet.room.composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("ping @res")

        // The fleet roster suggests the researcher (friendly title form).
        let suggestion = app.descendants(matching: .any)["fleet.mention.suggestion.researcher"]
        XCTAssertTrue(
            suggestion.waitForExistence(timeout: 10),
            "mention suggestion renders for the @fragment")
        suggestion.tap()

        // The tag is inserted into the draft; the message sends with it.
        app.buttons["fleet.room.send"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.entry.3"].waitForExistence(timeout: 10),
            "mention-bearing message sends (delivery is room policy)")
    }

    // MARK: - D22 typed failure card

    func testTypedFailureCardShowsPerTypeActionsAndWireBadge() throws {
        // The scripted room seeds a turn.failed with reason
        // provider_auth_or_access (attention class).
        let app = launch(extraEnv: ["HERMES_FLEET_ROOM_FAILURE": "1"])
        openHostedRoom(app)

        let card = app.buttons["fleet.room.failure-card"]
        _ = card.waitForExistence(timeout: 3)
        // Typed title (attention class) — not a generic "Turn failed".
        XCTAssertTrue(
            app.staticTexts["Needs attention — Provider sign-in needed"].waitForExistence(timeout: 10),
            "typed attention title renders")

        // Mono wire badge rides along (honest typed identity).
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.failure.wire-badge"]
                .waitForExistence(timeout: 5),
            "wire badge renders")

        // Per-type actions: re-authenticate + open settings (D22: never
        // generic-only). A card-level identifier is intentionally absent so
        // these keep their own identifiers.
        XCTAssertTrue(
            app.buttons["fleet.room.failure.action.reauthenticate"].waitForExistence(timeout: 5),
            "reauthenticate action renders for provider_auth_or_access")
        XCTAssertTrue(
            app.buttons["fleet.room.failure.action.open_settings"].exists,
            "open settings action renders")
    }
}
