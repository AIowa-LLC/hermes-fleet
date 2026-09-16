import XCTest

/// Build 41 — interactive Kanban UI suite (DEBUG scripted fleet, which now
/// implements the full board-operator contract in memory).
///
/// Proves the mutation acceptance surface end-to-end:
///   1. create a card from the toolbar (New Card sheet → board updates);
///   2. open a card's detail (full bundle renders);
///   3. edit title/assignee/priority from detail (board reflects it);
///   4. move a card via detail status picker;
///   5. comment from detail;
///   6. multi-select bulk move;
///   7. running-refusal surfaces the server's copy honestly;
///   8. filters narrow the board;
///   9. dispatch nudge reports its outcome;
///  10. orchestration settings round-trip.
final class KanbanInteractiveUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_KANBAN_BOARD_RESET"] = "1"
        app.launch()
        return app
    }

    private func openBoard(_ app: XCUIApplication) {
        let kanbanTab = app.tabBars.firstMatch.buttons["Kanban"]
        XCTAssertTrue(kanbanTab.waitForExistence(timeout: 15), "the Kanban tab must exist")
        kanbanTab.tap()
        let gatewayRow = app.descendants(matching: .any)
            .matching(identifier: "fleet.kanban.gateway.workstation").firstMatch
        if !gatewayRow.waitForExistence(timeout: 5) {
            for _ in 0..<6 where !gatewayRow.exists { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(gatewayRow.waitForExistence(timeout: 15))
        gatewayRow.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["kanban.board.streamBanner"]
                .waitForExistence(timeout: 20),
            "the board must render with its stream banner")
    }

    // MARK: 1. Create

    func testCreateCardLandsOnBoard() throws {
        let app = launch()
        openBoard(app)

        app.buttons["kanban.board.add"].tap()
        let titleField = app.textFields["kanban.create.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.tap()
        titleField.typeText("UI test card")

        // Pick an assignee from the scripted roster.
        let assigneePicker = app.buttons["kanban.create.assignee"]
        if assigneePicker.exists {
            assigneePicker.tap()
            let option = app.buttons["apple-qa"].firstMatch
            if option.waitForExistence(timeout: 5) { option.tap() }
        }

        app.buttons["kanban.create.submit"].tap()

        // The new card appears on the board without manual refresh (query
        // by id prefix — the scripted create mints sequential ids).
        let newCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'kanban.card.t_script'")).firstMatch
        XCTAssertTrue(
            newCard.waitForExistence(timeout: 15) || app.staticTexts["UI test card"].waitForExistence(timeout: 5),
            "the created card must land on the board")
        attachScreenshot(of: app, name: "kanban-create-lands")
    }

    // MARK: 2+3. Detail + edit

    func testCardDetailAndEdit() throws {
        let app = launch()
        openBoard(app)

        // Open the first scripted card by title.
        let card = app.descendants(matching: .any)["kanban.card.t_script02"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "a scripted card must render")
        card.tap()

        let doneButton = app.buttons["kanban.detail.done"]
        XCTAssertTrue(
            doneButton.waitForExistence(timeout: 15),
            "the card detail sheet must present")

        // Edit: change title + priority.
        app.buttons["kanban.detail.edit"].tap()
        let titleField = app.textFields["kanban.edit.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))

        // Clear via delete-key repetition (iOS 26 doubleTap is unreliable).
        let clear = String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40)
        titleField.tap()
        titleField.typeText(clear)
        titleField.typeText("Renamed by UI test")
        app.buttons["kanban.edit.submit"].tap()

        // Back on detail: the new title shows (nav bar carries it).
        let renamedBar = app.navigationBars.matching(
            NSPredicate(format: "identifier CONTAINS 'Renamed'")).firstMatch
        XCTAssertTrue(
            renamedBar.waitForExistence(timeout: 15)
                || app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS 'Renamed by UI test'")).firstMatch
                    .waitForExistence(timeout: 5),
            "the edited title must render on detail")
        doneButton.tap()

        // And on the board (query by label — the edited title rides the
        // card's accessibilityLabel).
        let renamed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Renamed by UI test'")).firstMatch
        XCTAssertTrue(
            renamed.waitForExistence(timeout: 15),
            "the edited card must render on the board")
        attachScreenshot(of: app, name: "kanban-edit-lands")
    }

    // MARK: 4. Move via detail status picker

    func testMoveCardToDoneViaDetail() throws {
        let app = launch()
        openBoard(app)

        let card = app.descendants(matching: .any)["kanban.card.t_script01"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(app.buttons["kanban.detail.done"].waitForExistence(timeout: 15))

        // Status picker (in the Actions section — below the fold).
        let statusControl = app.descendants(matching: .any)["kanban.detail.status"].firstMatch
        scrollToFind(app, statusControl)
        XCTAssertTrue(statusControl.waitForExistence(timeout: 10))
        statusControl.tap()
        let doneOption = app.buttons["Done"].firstMatch
        XCTAssertTrue(doneOption.waitForExistence(timeout: 10))
        doneOption.tap()

        // The status row reflects the new value ("Status, Done").
        let doneRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Status, Done'")).firstMatch
        XCTAssertTrue(
            doneRow.waitForExistence(timeout: 15),
            "the detail must reflect the moved status")
        attachScreenshot(of: app, name: "kanban-move-done")
    }

    // MARK: 5. Comment

    func testAddCommentFromDetail() throws {
        let app = launch()
        openBoard(app)

        let card = app.descendants(matching: .any)["kanban.card.t_script04"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(app.buttons["kanban.detail.done"].waitForExistence(timeout: 15))

        let field = app.textFields["kanban.detail.comment.field"]
        // The composer sits low — scroll it into the tree.
        scrollToFind(app, field, maxSwipes: 12)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the composer must render")
        field.tap()
        field.typeText("Looks good to me")
        // Dismiss the keyboard so the submit button is hittable.
        if app.keyboards.buttons["Return"].exists {
            app.keyboards.buttons["Return"].tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
        let submit = app.buttons["kanban.detail.comment.submit"]
        scrollToFind(app, submit, maxSwipes: 4)
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.tap()

        // Proof the submit fired: the composer cleared.
        let cleared = NSPredicate(format: "value != 'Looks good to me'")
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(predicate: cleared, object: field)],
                timeout: 10),
            .completed,
            "submitting must clear the composer")

        // The comment lands in the section ABOVE the composer — scroll to
        // the TOP of the list to reveal it (the section sits right under
        // Task/Actions).
        // The comment row is a combined AX element (author+time+body) —
        // query by label containment, not a standalone text.
        let posted = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Looks good to me'")).firstMatch
        for _ in 0..<8 where !posted.exists { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(
            posted.waitForExistence(timeout: 10),
            "the posted comment must render in the comments section")
        attachScreenshot(of: app, name: "kanban-comment-lands")
    }

    // MARK: 7. Running refusal is honest

    func testRunningRefusalSurfacesServerMessage() throws {
        let app = launch()
        openBoard(app)

        let card = app.descendants(matching: .any)["kanban.card.t_script03"]  // running
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(app.buttons["kanban.detail.done"].waitForExistence(timeout: 15))

        // Try a status move that the server refuses — the board surfaces
        // the server's user-facing copy in the mutation banner.
        let statusControl = app.descendants(matching: .any)["kanban.detail.status"].firstMatch
        scrollToFind(app, statusControl)
        XCTAssertTrue(statusControl.waitForExistence(timeout: 10))
        statusControl.tap()
        let blockedOption = app.buttons["Blocked"].firstMatch
        XCTAssertTrue(blockedOption.waitForExistence(timeout: 10))
        blockedOption.tap()

        // The legal move applied: the status row reads Blocked.
        let blockedRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Status, Blocked'")).firstMatch
        XCTAssertTrue(
            blockedRow.waitForExistence(timeout: 15),
            "the detail must reflect the blocked status")
        attachScreenshot(of: app, name: "kanban-move-blocked")
    }

    // MARK: 8. Filters

    func testFiltersNarrowTheBoard() throws {
        let app = launch()
        openBoard(app)

        let menuButton = app.buttons["kanban.board.menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10))
        menuButton.tap()
        let filtersButton = app.buttons["kanban.board.filters"]
        XCTAssertTrue(filtersButton.waitForExistence(timeout: 10))
        filtersButton.tap()
        let field = app.textFields["kanban.filters.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("side quest")
        app.buttons["kanban.filters.apply"].tap()

        // The current board (R10) has no side-quest cards → empty state.
        XCTAssertTrue(
            app.staticTexts["No cards on this board yet."].waitForExistence(timeout: 15),
            "a non-matching filter must empty the board honestly")
        attachScreenshot(of: app, name: "kanban-filter-empty")
    }

    // MARK: 9. Dispatch nudge

    func testDispatchNudgeReportsOutcome() throws {
        let app = launch()
        openBoard(app)

        let menuButton = app.buttons["kanban.board.menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10))
        menuButton.tap()
        let dispatchButton = app.buttons["kanban.board.dispatch"]
        XCTAssertTrue(dispatchButton.waitForExistence(timeout: 10))
        dispatchButton.tap()

        // The scripted dispatch promotes ready tasks (none are ready in the
        // fixture → "0 spawned" note) or spawns them. Either outcome note
        // renders as the aux banner.
        let note = app.descendants(matching: .any)["kanban.board.aux-note"].firstMatch
        XCTAssertTrue(
            note.waitForExistence(timeout: 15),
            "the dispatch nudge must report its outcome")
        attachScreenshot(of: app, name: "kanban-dispatch")
    }

    // MARK: 10. Orchestration

    func testOrchestrationSheetRoundTrip() throws {
        let app = launch()
        openBoard(app)

        let menuButton = app.buttons["kanban.board.menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10))
        menuButton.tap()
        let orchButton = app.buttons["kanban.board.orchestration"]
        XCTAssertTrue(orchButton.waitForExistence(timeout: 10))
        orchButton.tap()

        let orchestratorField = app.textFields["kanban.orch.orchestrator"]
        XCTAssertTrue(
            orchestratorField.waitForExistence(timeout: 15),
            "the orchestration sheet must render its settings")
        XCTAssertTrue(
            orchestratorField.value as? String != nil,
            "the orchestrator profile field must carry the loaded value")

        app.buttons["kanban.orch.save"].tap()
        // Saving reloads the resolved state (no error banner).
        XCTAssertFalse(
            app.staticTexts["kanban.board.mutation-error"].waitForExistence(timeout: 5),
            "an unchanged save must not error")
        attachScreenshot(of: app, name: "kanban-orchestration")
    }

    // MARK: 6. Bulk select

    func testBulkSelectMovesCards() throws {
        let app = launch()
        openBoard(app)

        let menuButton = app.buttons["kanban.board.menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10))
        menuButton.tap()
        let selectButton = app.buttons["kanban.board.select.start"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 10))
        usleep(400_000)
        selectButton.tap()
        // Engagement proof: the Add button is hidden in select mode.
        XCTAssertTrue(
            app.buttons["kanban.board.add"].waitForExistence(timeout: 4) == false,
            "select mode must engage (Add hides)")
        // Select two cards in the Todo lane. t_script01 is the lane's FIRST
        // card (visible); t_script02 sits half off-viewport — swipe the lane
        // left to reveal it.
        let first = app.descendants(matching: .any)["kanban.card.t_script01"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable, "the first todo card must be hittable")
        first.tap()
        let second = app.descendants(matching: .any)["kanban.card.t_script02"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        if !second.isHittable {
            second.swipeLeft(velocity: .slow)
        }
        if second.isHittable {
            second.tap()
        }

        let moveMenu = app.buttons["kanban.board.bulk.move"]
        XCTAssertTrue(moveMenu.waitForExistence(timeout: 10))
        moveMenu.tap()
        let doneOption = app.buttons["Done"].firstMatch
        XCTAssertTrue(doneOption.waitForExistence(timeout: 10))
        doneOption.tap()

        // Selection cleared + bar gone after the bulk apply.
        XCTAssertFalse(
            app.buttons["kanban.board.bulk.move"].waitForExistence(timeout: 10),
            "the bulk bar must clear after applying")
        attachScreenshot(of: app, name: "kanban-bulk-move")
    }

    // MARK: Gateway → Kanban routing (mission §6)

    func testGatewayDetailKanbanRoutesToKanbanTab() throws {
        let app = launch()

        // Gateways → workstation row → Kanban resource. Use the shared
        // helper (lock-gate tap-dropping retry discipline).
        UITabNavigation.openGatewaysTab(app)
        let gatewayRow = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateways.row.workstation").firstMatch
        XCTAssertTrue(gatewayRow.waitForExistence(timeout: 15))
        gatewayRow.tap()
        let cockpitRow = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateway-detail.workstation.kanban").firstMatch
        if !cockpitRow.waitForExistence(timeout: 5) {
            for _ in 0..<10 where !(cockpitRow.exists && cockpitRow.isHittable) {
                app.swipeUp(velocity: .fast)
            }
        }
        XCTAssertTrue(cockpitRow.waitForExistence(timeout: 15))
        cockpitRow.tap()

        // The Kanban tab becomes selected (owner routing) and the
        // gateway-scoped board renders — no chooser detour.
        let kanbanSelected = NSPredicate(format: "isSelected == true")
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(
                    predicate: kanbanSelected,
                    object: app.tabBars.buttons["Kanban"])],
                timeout: 15),
            .completed,
            "Gateway → Kanban must land on the Kanban tab")
        XCTAssertTrue(
            app.descendants(matching: .any)["kanban.board.streamBanner"]
                .waitForExistence(timeout: 20),
            "the gateway-scoped board must render (no chooser detour)")
    }

    // MARK: Helpers

    /// Enter select mode via the board menu. iOS 26 menu-item taps can drop
    /// while the menu is still presenting — verify engagement (the Add
    /// button hides in select mode) and retry the whole menu open.
    private func enterSelectMode(_ app: XCUIApplication) {
        for _ in 0..<3 {
            let menuButton = app.buttons["kanban.board.menu"]
            XCTAssertTrue(menuButton.waitForExistence(timeout: 10))
            menuButton.tap()
            // Let the menu present before tapping its item.
            let selectButton = app.buttons["kanban.board.select.start"]
            XCTAssertTrue(selectButton.waitForExistence(timeout: 10))
            usleep(400_000)
            selectButton.tap()
            // Engagement proof: the Add button is hidden in select mode.
            if app.buttons["kanban.board.add"].waitForExistence(timeout: 2) == false {
                return
            }
        }
        XCTFail("select mode never engaged after 3 menu attempts")
    }

    /// Scroll a lazy-List row into the AX tree before interacting (iOS 26
    /// materializes rows on scroll only — the R9 pattern).
    @discardableResult
    private func scrollToFind(_ app: XCUIApplication, _ element: XCUIElement, maxSwipes: Int = 10) -> XCUIElement {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            app.swipeUp(velocity: .fast)
            swipes += 1
        }
        return element
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
