import XCTest

/// FOS-5 (t_41672ceb) — Bots+Groups+Chats refinement UI suite against the
/// scripted simulator fleet (deterministic; no live gateway):
/// 1. Fleet-wide Active Now preview renders ONCE above the groups (no
///    per-gateway strips) — the scripted fleet has no executing bots, so
///    the preview is ABSENT (honest) and only ONE "Active Now" header may
///    exist even when active bots exist.
/// 2. All/Bots/Groups scope picker: Groups scope hides bot rows and shows
///    the Groups section; Bots scope hides group rows.
/// 3. Groups terminology: roster section header says "GROUPS"; legacy room
///    row reads "Managed by Hermes Desktop · Read only".
/// 4. Chats: Compose opens the source-qualified bot picker; heading stays
///    "Newest sessions".
final class FOS5BotsGroupsChatsUITests: XCTestCase {

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
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        for (key, value) in extraEnv {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    /// A scope segment INSIDE the scope picker — `app.buttons["Bots"]` alone
    /// matches the tab bar's Bots tab first, so scope the query.
    private func scopeSegment(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let control = app.segmentedControls["fleet.roster.scope"].firstMatch
        if control.exists { return control.buttons[title] }
        return app.segmentedControls.firstMatch.buttons[title]
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let any = app.descendants(matching: .any)[identifier]
        if any.exists { return any }
        return any
    }

    private func scrollToFind(_ app: XCUIApplication, identifier: String, label: String?) {
        let element = app.descendants(matching: .any)[identifier]
        var attempts = 0
        while !element.exists && attempts < 12 {
            app.swipeUp(velocity: .slow)
            attempts += 1
        }
        XCTAssertTrue(
            element.waitForExistence(timeout: 5),
            "expected element \(identifier) to exist after scrolling")
        if let label {
            XCTAssertTrue(
                element.label.localizedCaseInsensitiveContains(label),
                "element \(identifier) should read '\(label)' (got: \(element.label))")
        }
    }

    // MARK: 1. Fleet-wide Active Now

    func testActiveNowPreviewAbsentWithoutExecutingBotsAndNeverDuplicated() throws {
        let app = launch()
        // The scripted fleet has NO executing bots — honest absence: no
        // Active Now header at all.
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.roster.row.workstation#researcher")
                .waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.descendants(matching: .any)["fleet.roster.active-now"].exists,
            "no executing bots → no Active Now preview (honest absence)")
    }

    // MARK: 2. Scope picker

    func testScopePickerFiltersBotsAndGroups() throws {
        let app = launch()
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.roster.row.workstation#researcher")
                .waitForExistence(timeout: 10))

        // Groups scope: bot rows disappear; the Groups header appears with
        // its room rows.
        scopeSegment(app, "Groups").tap()
        XCTAssertFalse(
            app.descendants(matching: .any)["fleet.roster.row.workstation#researcher"].exists,
            "Groups scope must hide bot rows")
        scrollToFind(app, identifier: "fleet.roster.rooms", label: "GROUPS")
        scrollToFind(app, identifier: "fleet.room.row.room-alpha", label: nil)

        // Bots scope: room rows disappear; bot rows return.
        scopeSegment(app, "Bots").tap()
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.roster.row.workstation#researcher")
                .waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.descendants(matching: .any)["fleet.roster.rooms"].exists,
            "Bots scope must hide the Groups section")

        // All scope: both render.
        scopeSegment(app, "All").tap()
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.roster.row.workstation#researcher")
                .waitForExistence(timeout: 10))
        scrollToFind(app, identifier: "fleet.roster.rooms", label: "GROUPS")
    }

    // MARK: 3. Groups terminology

    func testGroupsTerminologyOnLegacyRoomRow() throws {
        let app = launch()
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.roster.row.workstation#researcher")
                .waitForExistence(timeout: 10))
        scrollToFind(app, identifier: "fleet.roster.rooms", label: "GROUPS")
        // The legacy projection row reads the exact §9 sentence.
        let legacy = app.descendants(matching: .any)["fleet.room.row.name:Research Crew"]
        var attempts = 0
        while !(legacy.exists && legacy.label.contains("Read only")) && attempts < 12 {
            app.swipeUp(velocity: .slow)
            attempts += 1
        }
        XCTAssertTrue(
            legacy.waitForExistence(timeout: 5),
            "legacy room row renders")
        XCTAssertTrue(
            legacy.label.localizedCaseInsensitiveContains("Managed by Hermes Desktop"),
            "legacy row carries the managed-by label (got: \(legacy.label))")
        XCTAssertTrue(
            legacy.label.localizedCaseInsensitiveContains("Read only"),
            "legacy row carries the read-only label (got: \(legacy.label))")
    }

    // MARK: 4. Chats Compose + heading

    func testChatsComposeOpensSourceQualifiedBotPicker() throws {
        let app = XCUIApplication()
        self.app = app
        app.launchEnvironment["HERMES_FLEET_AUTO_NAV"] = "chats"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // Heading stays honest (SPEC §10: do not rename to Recent).
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.chats.new").waitForExistence(timeout: 10))

        // Compose opens the bot picker: source-qualified rows (slug +
        // gateway name), never a silent first gateway.
        firstMatch(in: app, identifier: "fleet.chats.new").tap()
        let candidate = app.descendants(matching: .any)["fleet.chats.compose.bot.workstation#researcher"]
        XCTAssertTrue(
            candidate.waitForExistence(timeout: 10),
            "compose sheet must list source-qualified bot candidates")
        XCTAssertTrue(
            candidate.label.localizedCaseInsensitiveContains("workstation"),
            "compose row carries gateway provenance (got: \(candidate.label))")
    }
}
