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
    /// session.title (methods_session.py:1427): the gateway auto-titles a new
    /// chat after the first turn — the header adopts it live and NO "Unknown
    /// event" row renders in the transcript (the build-49 bug).
    func testSessionAutoTitleAdoptsHeaderWithoutUnknownEventRow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_SESSION_TITLE_FIXTURE"] = "1"
        app.launch()
        openConversation(app)

        let composer = app.textFields["fleet.conversation.composer"]
        composer.tap()
        composer.typeText("good morning")
        app.descendants(matching: .any).matching(identifier: "fleet.conversation.send").firstMatch.tap()

        // The header's secondary line adopts the scripted auto-title.
        let headerTitle = app.descendants(matching: .any)
            .matching(identifier: "fleet.conversation.header.title").firstMatch
        XCTAssertTrue(headerTitle.waitForExistence(timeout: 15))
        let titled = NSPredicate(format: "label CONTAINS %@", "Scripted auto title")
        let titledExp = XCTNSPredicateExpectation(predicate: titled, object: headerTitle)
        XCTAssertTrue(XCTWaiter().wait(for: [titledExp], timeout: 10) == .completed,
                      "header must adopt the auto title (got: \(headerTitle.label))")

        // The transcript stays clean — no raw event-name rows.
        let unknownRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Unknown event")).firstMatch
        XCTAssertFalse(unknownRow.exists, "session.title must not surface as Unknown event")
    }

    /// Top chip bar (Hermex-inspired, docked at the top): after a turn the
    /// scroll zone carries model · folder · profile · context. Off-screen
    /// chips are reachable by swiping the zone (overflow scrolls, never
    /// truncates).
    func testHeaderChipBarScrollsAndCarriesSessionFacts() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_SESSION_INFO_FIXTURE"] = "1"
        app.launch()
        openConversation(app)

        let composer = app.textFields["fleet.conversation.composer"]
        waitUntilEnabled(composer, timeout: 10)
        composer.tap()
        composer.typeText("chip bar probe")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))

        // The model chip is always in the zone.
        let chip = firstMatch(in: app, identifier: "model.chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "model chip must render in the scroll zone")

        // Folder + profile chips arrive with the session.info fixture; if
        // off-screen, swipe the zone left to reveal them (bounded).
        let zone = firstMatch(in: app, identifier: "fleet.conversation.header.chipzone")
        XCTAssertTrue(zone.waitForExistence(timeout: 5), "chip scroll zone must render")
        func reveal(_ id: String) -> XCUIElement {
            let e = app.descendants(matching: .any)[id]
            for _ in 0..<4 where !(e.exists && e.isHittable) {
                zone.swipeLeft(velocity: .slow)
            }
            return e
        }
        let folder = reveal("fleet.conversation.header.folder")
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "folder chip must render")
        let folderValue = folder.value as? String ?? ""
        XCTAssertTrue(folderValue.contains("hermes-fleet"),
                      "folder chip carries the cwd as its accessibility value (got \(folderValue))")
        let profile = reveal("fleet.conversation.header.profile")
        XCTAssertTrue(profile.waitForExistence(timeout: 5), "profile chip must render")

        // Full path popover on folder tap.
        if folder.isHittable {
            folder.tap()
            let path = app.staticTexts["/home/dev/hermes-fleet"]
            XCTAssertTrue(path.waitForExistence(timeout: 5), "folder popover shows the full cwd")
            tap(app.buttons["Copy path"])
        }
    }

    func testConversationUsesSingleRowHeader() throws {
        let app = launch()
        openConversation(app)

        // Compaction round 2: the system navigation bar is HIDDEN on the
        // conversation — all chrome lives in ONE 44-56pt custom row.
        let header = firstMatch(in: app, identifier: "fleet.conversation.header")
        XCTAssertTrue(header.waitForExistence(timeout: 10), "compact header must render")
        // The header's AX frame includes the status-bar region (custom chrome
        // owns the full top inset), so measure the ROW itself: back-button
        // top to transcript top = the single chrome row.
        let back = firstMatch(in: app, identifier: "fleet.conversation.back")
        XCTAssertTrue(back.waitForExistence(timeout: 5), "custom back button must render")
        let transcript0 = firstMatch(in: app, identifier: "fleet.conversation.transcript")
        XCTAssertTrue(transcript0.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(
            transcript0.frame.minY - back.frame.minY, 48,
            "the merged header must stay a single compact row (got \(transcript0.frame.minY - back.frame.minY)pt)"
        )

        // The system nav bar must not render for the conversation's stack.
        // (Scope to the owning Chats stack — mounted hidden stacks' bars can
        // still surface in the AX snapshot.)
        let stackBar = app.descendants(matching: .any)["fleet.tab.chats"]
            .descendants(matching: .navigationBar).firstMatch
        let barVisible = stackBar.exists && stackBar.isHittable
        XCTAssertFalse(barVisible,
                       "the conversation must not show the system navigation bar")

        // Identity + title leaves, back + drawer buttons, one row.
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.conversation.header.name").waitForExistence(timeout: 5))
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.conversation.header.title").exists)
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.drawer.open").waitForExistence(timeout: 5),
                      "drawer toggle must render in the row")
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.conversation.header.identity").exists,
                      "identity element (spoken status carrier) must render")

        // The transcript must begin at/below the single header row — the old
        // two-row chrome is gone (pre-fix transcript minY included the bar).
        let transcript = firstMatch(in: app, identifier: "fleet.conversation.transcript")
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(
            transcript.frame.minY, header.frame.maxY + 8,
            "transcript must start right after the single header row (header maxY \(header.frame.maxY), transcript minY \(transcript.frame.minY))"
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
        // ⋯ session-actions menu (compaction round 2: the toolbar row is
        // gone; timeline rides the menu).
        let composer = app.textFields["fleet.conversation.composer"]
        waitUntilEnabled(composer, timeout: 10)
        composer.tap()
        composer.typeText("compact chrome probe")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))

        let menu = firstMatch(in: app, identifier: "session.actions.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "session actions menu must render")
        menu.tap()
        let timeline = app.buttons["fleet.conversation.timeline.open"]
        XCTAssertTrue(
            timeline.waitForExistence(timeout: 10),
            "timeline affordance must be reachable from the session-actions menu"
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
