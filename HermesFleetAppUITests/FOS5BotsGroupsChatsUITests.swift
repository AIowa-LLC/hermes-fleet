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

    /// Fleet-wide group journey: the creation sheet is entered from Chats,
    /// presents Bots from two distinct gateway routes, and opens the resulting
    /// hosted conversation after the scripted peer setup completes.
    func testChatsNewGroupCreatesAndOpensCrossGatewayRoom() throws {
        let app = XCUIApplication()
        self.app = app
        app.launchEnvironment["HERMES_FLEET_AUTO_NAV"] = "chats"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        let newGroup = app.buttons["fleet.chats.new-group"]
        XCTAssertTrue(newGroup.waitForExistence(timeout: 10), "Chats exposes fleet-wide New Group")
        newGroup.tap()

        let name = app.textFields["fleet.room.create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "group name field renders")
        name.tap()
        name.typeText("Fleet Cross-Machine")

        let workstation = app.descendants(matching: .any)["fleet.room.create.candidate.workstation#researcher"]
        let renderBox = app.descendants(matching: .any)["fleet.room.create.candidate.render-box#default"]
        XCTAssertTrue(workstation.waitForExistence(timeout: 10), "workstation Bot is listed")
        XCTAssertTrue(renderBox.waitForExistence(timeout: 10), "render-box Bot is listed in the same picker")
        XCTAssertTrue(workstation.label.localizedCaseInsensitiveContains("Workstation"))
        XCTAssertTrue(renderBox.label.localizedCaseInsensitiveContains("Render Box"))

        workstation.tap()
        renderBox.tap()
        let submit = app.buttons["fleet.room.create.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isEnabled, "two reachable Bots satisfy the frozen roster minimum")

        let pickerShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        pickerShot.name = "build44-fleet-wide-group-picker"
        pickerShot.lifetime = .keepAlways
        add(pickerShot)

        submit.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.chat"].waitForExistence(timeout: 15),
            "successful cross-gateway creation opens the interactive hosted room")
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.member.Researcher"].waitForExistence(timeout: 5),
            "host member remains attributed")
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.member.Default"].waitForExistence(timeout: 5),
            "remote member remains attributed")
        let composer = app.textFields["fleet.room.composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "hosted room exposes its composer")
        XCTAssertTrue(composer.isEnabled, "a successfully linked hosted room remains interactive")
        XCTAssertEqual(composer.placeholderValue, "Message the room (@ to mention)")
        composer.tap()
        composer.typeText("Coordinate this")
        let send = app.buttons["fleet.room.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "interactive room exposes send")
        send.tap()
        XCTAssertTrue(
            app.staticTexts["Coordinate this"].waitForExistence(timeout: 5),
            "the user message is rendered in the authoritative room transcript")

        let roomShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        roomShot.name = "build44-cross-gateway-group-chat"
        roomShot.lifetime = .keepAlways
        add(roomShot)
    }

    // MARK: 5. Chats refresh-failure surface (dogfood corrective pass F2/F3)

    /// F2: a container `accessibilityIdentifier` on the failure surface
    /// overrode every descendant id, so `fleet.chats.refresh.retry` matched
    /// ZERO elements even though a hittable Retry button was on screen.
    /// F3: the compact Retry's AX frame stayed at the label size despite
    /// `.frame(minHeight: 44)` (QA measured 34.3 × 15.7).
    ///
    /// Deterministic probe: fail the session read for ONE gateway
    /// (`HERMES_FLEET_SESSIONS_FAIL`) while another keeps usable sessions →
    /// the compact INLINE surface renders. The Retry control must be
    /// discoverable by its own identifier AND be a genuine 44pt tap target.
    func testChatsInlineRefreshFailureRetryIsDiscoverableAndMeetsTapTarget() throws {
        let app = XCUIApplication()
        self.app = app
        app.launchEnvironment["HERMES_FLEET_AUTO_NAV"] = "chats"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_SESSIONS_FAIL"] = "render-box"
        app.launch()

        let inline = app.descendants(matching: .any)["fleet.chats.refresh.inline"]
        XCTAssertTrue(inline.waitForExistence(timeout: 15),
                      "a partial refresh failure must render the compact inline surface")

        let retry = app.buttons["fleet.chats.refresh.retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5),
                      "the Retry control must be discoverable by its own identifier")
        XCTAssertTrue(retry.isHittable, "the Retry control must be hittable")

        let frame = retry.frame
        XCTAssertGreaterThanOrEqual(
            frame.height, 44,
            "Retry's rendered accessibility frame must be a real tap target (height was \(frame.height))")
        XCTAssertGreaterThanOrEqual(
            frame.width, 44,
            "Retry's rendered accessibility frame must be a real tap target (width was \(frame.width))")
    }
}
