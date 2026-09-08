import XCTest

/// U5 (Gold Fleet) — bots + bot-detail re-skin regression suite.
///
/// Drives the DEBUG build (deterministic scripted fleet: 3 gateways — two
/// healthy, one unreachable — with real roster bots and sessions) and proves
/// the plan card's U5 scope:
///   1. bot LIST rows (per-gateway + union roster) render on the design
///      system: avatar + name + route + real status pill;
///   2. bot DETAIL renders the persistent header card (avatar, name,
///      canonical route, pill) and the segmented control;
///   3. the segmented control has exactly Chat + Details (Metrics OMITTED —
///      no real per-bot metrics data exists; the plan forbids stub screens);
///   4. Chat is the default segment and keeps the session rows + New Session
///      affordance reachable (every drill-in flow lands here);
///   5. Details renders identity + status from the real roster;
///   6. no presentation-layer regression in the drill-in path (Gateways →
///      Bots → Detail → session → conversation canvas still works).
final class U5BotDetailUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Bot list rows (per-gateway drill + union roster)

    func testGatewayBotRowsRenderAvatarRouteAndPill() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        // Drill into the healthy scripted gateway's bot list.
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        XCTAssertTrue(app.staticTexts["Default"].waitForExistence(timeout: 10),
                      "Bots screen should list the Default bot on Workstation")

        // U5 row: the row id is stable; the combined row carries name +
        // route + pill text (children combined).
        let row = firstMatch(in: app, identifier: "fleet.roster.row.workstation#default")
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "the per-gateway bot list must render a U5 row")
        // Real status pill from the scripted bot's activity (Idle in the
        // fixture → the pill's "Status: Idle" label merges into the combined
        // row label).
        let rowLabel = row.label
        XCTAssertTrue(
            rowLabel.contains("Status:"),
            "bot rows must carry a status pill (row label: \(rowLabel))"
        )
        attachScreenshot(of: app, name: "u5-bots-rows-gold")
    }

    func testUnionRosterRendersDesignSystemRows() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openBotsTab(app)

        // The union roster lists the scripted fleet's real bot rows.
        let row = firstMatch(in: app, identifier: "fleet.roster.row.workstation#default")
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "the union roster must render a U5 bot row")
        attachScreenshot(of: app, name: "u5-roster-rows-gold")
    }

    // MARK: - Bot detail: header + segmented control

    func testBotDetailHeaderAndSegments() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        tap(firstMatch(in: app, identifier: "fleet.roster.row.workstation#default"))

        // Persistent header card.
        let header = firstMatch(in: app, identifier: "fleet.bot-detail.header")
        XCTAssertTrue(header.waitForExistence(timeout: 10),
                      "bot detail must render the U5 header card")
        // FOS-5 compact header: preferred title text + friendly gateway.
        // (The header card uses .contain so inner action identifiers stay
        // addressable — assert on the title text itself.)
        XCTAssertTrue(
            app.staticTexts["Default"].firstMatch.exists,
            "the header must show the bot's title"
        )

        // FOS-5 segmented control: Conversations / Routines / Configuration.
        let segment = firstMatch(in: app, identifier: "fleet.bot-detail.segment")
        XCTAssertTrue(segment.waitForExistence(timeout: 10),
                      "bot detail must render the segmented control")
        XCTAssertTrue(segmentButton(app, "Conversations").exists, "Conversations segment must exist")
        XCTAssertTrue(segmentButton(app, "Routines").exists, "Routines segment must exist")
        XCTAssertTrue(segmentButton(app, "Configuration").exists, "Configuration segment must exist")
        XCTAssertFalse(segmentButton(app, "Metrics").exists,
                       "Metrics must be OMITTED (no real per-bot metrics data)")

        // Chat is the default: session rows are visible without switching.
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.sessions.row.workstation.default.s1")
                .waitForExistence(timeout: 10),
            "Chat (default) must show the session rows"
        )
        attachScreenshot(of: app, name: "u5-bot-detail-chat-default")
    }

    func testDetailsSegmentShowsIdentity() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        tap(firstMatch(in: app, identifier: "fleet.roster.row.workstation#default"))
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10))

        // Switch to Configuration: the identity card renders (FOS-5: the
        // Details segment became Configuration).
        segmentButton(app, "Configuration").tap()
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.route").waitForExistence(timeout: 10),
            "the Details segment must render the identity card"
        )
        attachScreenshot(of: app, name: "u5-bot-detail-details-segment")
    }

    // MARK: - Drill-in path regression (session opens from Chat)

    func testSessionOpensFromChatSegment() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        tap(firstMatch(in: app, identifier: "fleet.roster.row.workstation#default"))
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10))

        tap(firstMatch(in: app, identifier: "fleet.bot-detail.sessions.row.workstation.default.s1"))
        XCTAssertTrue(
            app.textFields["fleet.conversation.composer"].waitForExistence(timeout: 10),
            "a session tap from the Chat segment must open the conversation canvas"
        )
        attachScreenshot(of: app, name: "u5-session-opens-from-chat")
    }

    // MARK: - Helpers

    /// A segmented-control segment button by title (top-level buttons or the
    /// segmented control's children, whichever exposes on this iOS).
    private func segmentButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let direct = app.buttons[title].firstMatch
        if direct.exists { return direct }
        return app.segmentedControls.firstMatch.buttons[title].firstMatch
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "element \(element) should appear")
        element.tap()
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let any = app.descendants(matching: .any)[identifier]
        if any.exists { return any }
        if app.buttons[identifier].exists { return app.buttons[identifier] }
        if app.cells[identifier].exists { return app.cells[identifier] }
        return any
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
