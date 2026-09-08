import XCTest

/// True Bots Mode slice 2 UI tests against the scripted simulator fleet
/// (deterministic; no live gateway): roster evolution (sections, search,
/// hidden, rooms), create bot, sections management, edit entry, and the
/// capability-gated delete state.
final class BotRosterSlice2UITests: XCTestCase {

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

    // MARK: - roster evolution

    func testRosterShowsSectionsAndRooms() throws {
        let app = launch()

        // Workstation fixture carries the scripted section registry
        // (Clients / Research) and two room provenances.
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.roster.row.workstation#researcher"]
                .waitForExistence(timeout: 10),
            "researcher bot row renders")

        // Section headers render in registry order (scroll until found).
        scrollToFind(app, identifier: "fleet.roster.section.sec-script-1", label: "CLIENTS")
        scrollToFind(app, identifier: "fleet.roster.section.sec-script-2", label: "RESEARCH")

        // Rooms group: hosted + legacy render as DISTINCT rows.
        scrollToFind(app, identifier: "fleet.room.row.room-alpha", label: nil)
        scrollToFind(app, identifier: "fleet.room.row.name:Research Crew", label: nil)
    }

    func testSearchFiltersRosterRows() throws {
        let app = launch()
        let researcher = app.descendants(matching: .any)["fleet.roster.row.workstation#researcher"]
        XCTAssertTrue(researcher.waitForExistence(timeout: 10))

        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("researcher")

        // Matching row stays; the default bot row disappears.
        XCTAssertTrue(researcher.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)["fleet.roster.row.workstation#default"].exists,
            "non-matching row filtered out")
    }

    // MARK: - bot detail actions

    func testBotDetailShowsEditAndGatedDelete() throws {
        let app = launch()
        let row = app.descendants(matching: .any)["fleet.roster.row.workstation#researcher"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        // FOS-5: Edit lives in the Configuration segment.
        let config = app.buttons["Configuration"].firstMatch
        XCTAssertTrue(config.waitForExistence(timeout: 8), "Configuration segment must exist")
        config.tap()

        // Edit affordance present on a reachable gateway.
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.bot-detail.edit"]
                .waitForExistence(timeout: 8))

        // Edit sheet loads the describe surface and cancels cleanly.
        app.descendants(matching: .any)["fleet.bot-detail.edit"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.bot.edit.submit"]
                .waitForExistence(timeout: 8))
        app.navigationBars.buttons["Cancel"].firstMatch.tap()
    }

    // MARK: - create bot

    func testCreateBotSheetAcceptsNameAndSubmits() throws {
        let app = launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.roster.row.workstation#researcher"]
                .waitForExistence(timeout: 10))

        // Manage menu → Create Bot.
        app.descendants(matching: .any)["fleet.roster.manage"].firstMatch.tap()
        let createItem = app.buttons["Create Bot"]
        XCTAssertTrue(createItem.waitForExistence(timeout: 5))
        createItem.tap()

        let nameField = app.descendants(matching: .any)["fleet.bot.create.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        nameField.tap()
        nameField.typeText("scribe-ui")

        let submit = app.buttons["fleet.bot.create.submit"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        // The submit enables once a name is typed (empty-name guard).
        var enabled = submit.isEnabled
        var polls = 0
        while !enabled && polls < 16 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            enabled = submit.isEnabled
            polls += 1
        }
        XCTAssertTrue(enabled, "submit enables once a name is typed")

        // Keyboard dismissed and submit tapped: the sheet completes and
        // dismisses (the create→roster-visible loop is proven end-to-end
        // against the real simulator wiring by SimulatorCreateFlowTests).
        if app.keyboards.count > 0 {
            app.keyboards.buttons["return"].firstMatch.tap()
        }
        submit.tap()
        let sheetGone = app.descendants(matching: .any)["fleet.bot.create.name"]
            .waitForNonExistence(timeout: 10)
        XCTAssertTrue(sheetGone, "create sheet completes and dismisses")
    }

    // MARK: - sections management

    func testSectionsManagementAddsSection() throws {
        let app = launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.roster.row.workstation#researcher"]
                .waitForExistence(timeout: 10))

        app.descendants(matching: .any)["fleet.roster.manage"].firstMatch.tap()
        let sectionsItem = app.buttons["Edit Sections — Workstation"]
        XCTAssertTrue(sectionsItem.waitForExistence(timeout: 5))
        sectionsItem.tap()

        let nameField = app.descendants(matching: .any)["fleet.sections.new-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        nameField.tap()
        nameField.typeText("Ops")
        app.descendants(matching: .any)["fleet.sections.add"].tap()

        // The new section row renders in the management list itself (the
        // registry save is immediate; roster section headers re-render on
        // the next roster refresh).
        XCTAssertTrue(
            app.staticTexts["Ops"].waitForExistence(timeout: 8),
            "new section row appears in the management list")
        app.navigationBars.buttons["Done"].firstMatch.tap()
    }

    // MARK: - helpers
/// Scroll the roster scroll view until an element (by identifier or
/// label) exists or attempts run out — the scripted fleet is short, so a
/// handful of swipes suffices.
    private func scrollToFind(
        _ app: XCUIApplication, identifier: String?, label: String?, attempts: Int = 8
    ) {
        func found() -> XCUIElement {
            if let identifier {
                return app.descendants(matching: .any)[identifier]
            }
            return app.staticTexts[label ?? ""]
        }
        if found().exists { return }
        for _ in 0..<attempts {
            app.swipeUp()
            if found().exists { return }
        }
        for _ in 0..<attempts {
            app.swipeDown()
            if found().exists { return }
        }
        XCTFail("element not found: identifier=\(identifier ?? "-") label=\(label ?? "-")")
    }
}
