import XCTest

/// Dogfood top-space fix — inline nav title + compact chrome UI coverage.
///
/// Proves the conversation screen's transcript begins dramatically higher:
/// inline navigation (no large title), one compact header row, no permanent
/// timeline inset, and the timeline affordance reachable from the toolbar.
/// Also runs the header at an accessibility Dynamic Type size to prove the
/// bot name survives and secondary metadata degrades gracefully.
final class ConversationCompactChromeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        return app
    }

    private func openConversation(_ app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        // iOS 26 materializes list rows on scroll — at accessibility sizes
        // the workstation row may sit below the fold, so scroll into view
        // BEFORE querying (the repo's lazy-list rule).
        let gatewayRow = firstMatch(in: app, identifier: "fleet.gateways.row.workstation")
        for _ in 0..<6 where !gatewayRow.exists {
            app.swipeUp()
        }
        tap(gatewayRow)
        UITabNavigation.openGatewayBots(app)
        tap(firstMatch(in: app, identifier: "fleet.roster.row.workstation#default"))
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10),
            "bot detail should render before drilling into the conversation"
        )
        tap(firstMatch(in: app, identifier: "fleet.bot-detail.sessions.row.workstation.default.s1"))
        XCTAssertTrue(
            app.textFields["fleet.conversation.composer"].waitForExistence(timeout: 10),
            "conversation canvas should open with a composer"
        )
    }

    /// The nav bar must be INLINE (compact) — a large-title bar measures
    /// taller than this bound on iPhone. The bound is generous vs the ~96pt
    /// large-title bar but tight vs the old stacked chrome.
    func testConversationUsesInlineNavTitle() throws {
        let app = launch()
        openConversation(app)

        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: 10), "a navigation bar must exist")
        let navHeight = navBar.frame.height
        XCTAssertLessThanOrEqual(
            navHeight, 60,
            "inline nav bar must be compact (large-title bars measure ~96pt+); got \(navHeight)"
        )

        // Bot identity remains visible in the compact header row. The
        // container uses .contain, so the name is asserted on its leaf.
        let header = firstMatch(in: app, identifier: "fleet.conversation.header")
        XCTAssertTrue(header.waitForExistence(timeout: 10), "compact bot header must render")
        let name = firstMatch(in: app, identifier: "fleet.conversation.header.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5), "bot name leaf must render")
        XCTAssertTrue(name.label.contains("Default"), "header label: \(name.label)")

        // The transcript surface itself starts within ~250pt of the top —
        // the old chrome consumed 250+ before the first message.
        let transcript = firstMatch(in: app, identifier: "fleet.conversation.transcript")
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(
            transcript.frame.minY, 250,
            "transcript must begin substantially higher; got \(transcript.frame.minY)"
        )
    }

    /// The model chip still opens the picker from the compact row, and the
    /// timeline sheet opens from the toolbar button.
    func testModelChipAndTimelineRemainReachable() throws {
        let app = launch()
        openConversation(app)

        let chip = firstMatch(in: app, identifier: "model.chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "model chip must render in the compact header")
        chip.tap()
        XCTAssertTrue(
            firstMatch(in: app, identifier: "model.picker.row.nous/hermes").waitForExistence(timeout: 10),
            "model picker must open from the compact chip"
        )
        tap(firstMatch(in: app, identifier: "model.picker.row.nous/hermes"))
        _ = waitUntilGone(firstMatch(in: app, identifier: "model.picker.row.nous/hermes"))

        // Send a turn so user turns exist, then open the timeline from the
        // toolbar.
        let composer = app.textFields["fleet.conversation.composer"]
        waitUntilEnabled(composer, timeout: 10)
        composer.tap()
        composer.typeText("compact chrome probe")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))

        let timeline = app.buttons["fleet.conversation.timeline.open"]
        XCTAssertTrue(
            timeline.waitForExistence(timeout: 15),
            "timeline affordance must be reachable from the navigation toolbar"
        )
        timeline.tap()
        XCTAssertTrue(app.navigationBars["Timeline"].waitForExistence(timeout: 5))
        tap(app.buttons["Done"])
    }

    /// At accessibility Dynamic Type sizes the header must not break: bot
    /// name visible, secondary metadata hidden, controls still present.
    /// Every drill-down list is scrolled into the AX tree before tapping
    /// (iOS 26 materializes rows on scroll; at AX sizes everything sits
    /// lower). Raw identifiers + bounded swipes — no shared helper
    /// pre-asserts.
    func testHeaderSurvivesAccessibilityTypeSize() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityXL"]
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        func reveal(_ identifier: String) -> XCUIElement {
            let element = app.descendants(matching: .any)[identifier]
            for _ in 0..<8 where !element.exists {
                app.swipeUp()
            }
            return element
        }

        tap(reveal("fleet.gateways.row.workstation"))
        tap(reveal("fleet.gateway-detail.workstation.bots"))
        tap(reveal("fleet.roster.row.workstation#default"))
        tap(reveal("fleet.bot-detail.sessions.row.workstation.default.s1"))
        XCTAssertTrue(
            app.textFields["fleet.conversation.composer"].waitForExistence(timeout: 10),
            "conversation canvas should open with a composer at AX size"
        )

        let header = firstMatch(in: app, identifier: "fleet.conversation.header")
        XCTAssertTrue(header.waitForExistence(timeout: 10), "compact header must render at AX sizes")
        let name = firstMatch(in: app, identifier: "fleet.conversation.header.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5), "bot name leaf must render at AX size")
        XCTAssertTrue(name.label.contains("Default"), "bot name must survive at AX size: \(name.label)")
        // Secondary metadata degrades away instead of squeezing the name.
        XCTAssertFalse(firstMatch(in: app, identifier: "model.chip").exists,
                       "secondary metadata must hide at accessibility sizes")
        // Steer controls remain present.
        XCTAssertTrue(firstMatch(in: app, identifier: "session.actions.menu").waitForExistence(timeout: 10),
                      "session actions must remain reachable at AX sizes")
    }

    // MARK: - Helpers (same shapes as the U6 suite)

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "element \(element) should appear")
        element.tap()
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        let enabled = NSPredicate(format: "isEnabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: enabled, object: element)
        wait(for: [expectation], timeout: timeout)
    }

    @discardableResult
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = NSPredicate(format: "exists == 0")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: element)
        wait(for: [expectation], timeout: timeout)
        return !element.exists
    }
}
