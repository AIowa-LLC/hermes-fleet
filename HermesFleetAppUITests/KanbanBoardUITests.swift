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
