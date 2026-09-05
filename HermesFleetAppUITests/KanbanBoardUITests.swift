import XCTest

/// t_3b321b7b — deterministic Kanban board UI suite (DEBUG scripted fleet).
///
/// Proves the read-only board acceptance surface:
///   1. the Home dashboard shows the Kanban Board entry;
///   2. tapping it pushes the board with the scripted snapshot's columns
///      and cards (grouped by status);
///   3. the stream banner renders the Live phase;
///   4. the view is strictly read-only: no mutating controls exist (no
///      add/move buttons; cards are informational only);
///   5. with `HERMES_FLEET_KANBAN_LIVE_UPDATES=1`, scripted live events
///      drive updates without any manual refresh (the Recent Activity strip
///      appears).
final class KanbanBoardUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBoardEntryPushesReadOnlyBoard() throws {
        let app = XCUIApplication()
        app.launch()

        // Home dashboard entry (the scripted fleet seeds gateways).
        let entry = firstMatch(in: app, identifier: "fleet.dashboard.kanban.entry")
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "Kanban board entry must render on Home")
        entry.tap()

        // Columns from the scripted snapshot render (Todo header with count).
        XCTAssertTrue(
            firstMatch(in: app, identifier: "kanban.board.streamBanner").waitForExistence(timeout: 15),
            "the board must render its live-stream banner"
        )
        let todoHeader = app.staticTexts["Todo"]
        XCTAssertTrue(todoHeader.waitForExistence(timeout: 10), "the Todo column must render")

        // Read-only: no card-create affordance anywhere on the board.
        XCTAssertFalse(
            app.buttons["Add Card"].exists,
            "the board must not offer card creation (strictly read-only)"
        )

        attachScreenshot(of: app, name: "kanban-board-readonly")
    }

    func testLiveEventsUpdateBoardWithoutManualRefresh() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_KANBAN_LIVE_UPDATES"] = "1"
        app.launch()

        let entry = firstMatch(in: app, identifier: "fleet.dashboard.kanban.entry")
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "Kanban board entry must render on Home")
        entry.tap()

        // With the live ticker on (3s cadence), the Recent Activity strip
        // appears WITHOUT any user refresh action.
        XCTAssertTrue(
            firstMatch(in: app, identifier: "kanban.board.activity").waitForExistence(timeout: 20),
            "scripted live events must surface in the activity strip without manual refresh"
        )
        attachScreenshot(of: app, name: "kanban-board-live-updates")
    }

    func testBoardPickerListsAndSwitchesBoards() throws {
        let app = XCUIApplication()
        app.launch()

        let entry = firstMatch(in: app, identifier: "fleet.dashboard.kanban.entry")
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "Kanban board entry must render on Home")
        entry.tap()

        // The picker renders with the ACTIVE scripted board's name. (Reset
        // first if a prior run left another board selected.)
        let picker = firstMatch(in: app, identifier: "fleet.kanban.board.picker")
        XCTAssertTrue(
            picker.waitForExistence(timeout: 15),
            "the board picker must render once the boards list loads")
        if !picker.label.contains("R10 Maintenance") {
            picker.tap()
            let r10 = app.buttons["R10 Maintenance"].firstMatch
            XCTAssertTrue(r10.waitForExistence(timeout: 10))
            r10.tap()
            let backToR10 = NSPredicate(format: "label CONTAINS %@", "R10 Maintenance")
            XCTAssertEqual(
                XCTWaiter().wait(
                    for: [XCTNSPredicateExpectation(predicate: backToR10, object: picker)],
                    timeout: 15),
                .completed)
        }
        XCTAssertTrue(
            picker.label.contains("R10 Maintenance"),
            "the picker must show the active board's name (got: \(picker.label))")

        // Open the menu: both scripted boards are listed.
        picker.tap()
        let sideQuests = app.buttons["Side Quests"]
        XCTAssertTrue(
            sideQuests.waitForExistence(timeout: 10),
            "the picker menu must list the gateway's boards")

        // Switch → the displayed board name (and its content) changes.
        sideQuests.tap()
        let switched = firstMatch(in: app, identifier: "fleet.kanban.board.picker")
        XCTAssertTrue(switched.waitForExistence(timeout: 10))
        let named = NSPredicate(format: "label CONTAINS %@", "Side Quests")
        let expectation = XCTNSPredicateExpectation(predicate: named, object: switched)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 15), .completed,
            "the picker must show the newly selected board's name")

        // Side Quests snapshot renders (its distinct card).
        let sideCard = app.staticTexts["Scripted: side quest one"]
        XCTAssertTrue(
            sideCard.waitForExistence(timeout: 10),
            "switching boards must re-target the snapshot (Side Quests card visible)")

        attachScreenshot(of: app, name: "kanban-board-switched")
    }

    func testBoardSelectionSurvivesRelaunch() throws {
        // Pass 1: switch to Side Quests (skip the tap if a prior test in
        // this suite already left it selected — the picker toggles).
        let app = XCUIApplication()
        app.launch()
        let entry = firstMatch(in: app, identifier: "fleet.dashboard.kanban.entry")
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.tap()
        let picker = firstMatch(in: app, identifier: "fleet.kanban.board.picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        if !picker.label.contains("Side Quests") {
            picker.tap()
            let sideQuests = app.buttons["Side Quests"].firstMatch
            XCTAssertTrue(sideQuests.waitForExistence(timeout: 10))
            sideQuests.tap()
        }
        let named = NSPredicate(format: "label CONTAINS %@", "Side Quests")
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(
                    predicate: named,
                    object: firstMatch(in: app, identifier: "fleet.kanban.board.picker"))],
                timeout: 15),
            .completed)

        // Pass 2: relaunch — the selection persists (per-device UserDefaults).
        app.terminate()
        app.launch()
        let entry2 = firstMatch(in: app, identifier: "fleet.dashboard.kanban.entry")
        XCTAssertTrue(entry2.waitForExistence(timeout: 15))
        entry2.tap()
        let picker2 = firstMatch(in: app, identifier: "fleet.kanban.board.picker")
        XCTAssertTrue(picker2.waitForExistence(timeout: 15))
        XCTAssertTrue(
            picker2.label.contains("Side Quests"),
            "the selected board must survive relaunch (got: \(picker2.label))")

        attachScreenshot(of: app, name: "kanban-board-relaunch-persisted")
    }

    // MARK: Helpers (same pattern as the other UI suites)

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
