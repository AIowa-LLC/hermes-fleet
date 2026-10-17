import XCTest

/// DEV19 #188 — long Bot Chats open newest-first and page older history on
/// demand (scripted fleet, no live gateway).
///
/// `HERMES_FLEET_LONG_CHAT_FIXTURE=1` makes every resumed conversation a
/// synthetic 25,000-message lineage: the normal resume is refused like the
/// gateway's 4130 guard, the omit-messages resume succeeds, and history pages
/// through the scripted pager (durable row ids 1…25000, text
/// "Long chat message N"). `HERMES_FLEET_LONG_CHAT_UNSUPPORTED=1` simulates a
/// gateway without the paged route.
final class LongChatPagingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func text(_ app: XCUIApplication, _ value: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch
    }

    private func tap(_ target: XCUIElement) {
        XCTAssertTrue(target.waitForExistence(timeout: 10), "element should exist before activation")
        let deadline = Date().addingTimeInterval(10)
        while !target.isHittable && Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.2)))
        }
        target.tap()
    }

    /// The status-bar tap is iOS's scroll-to-top; swipes are the fallback for
    /// the lazily materialized top rows.
    private func scrollToTop(_ app: XCUIApplication, until target: XCUIElement) {
        let deadline = Date().addingTimeInterval(90)
        while !(target.exists && target.isHittable) && Date() < deadline {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
            Thread.sleep(forTimeInterval: 0.8)
            if target.exists && target.isHittable { break }
            app.swipeDown(velocity: .fast)
        }
    }

    private func launch(unsupported: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_LONG_CHAT_FIXTURE"] = "1"
        if unsupported { app.launchEnvironment["HERMES_FLEET_LONG_CHAT_UNSUPPORTED"] = "1" }
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)
        tap(element(app, "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        tap(element(app, "fleet.roster.row.workstation#default"))
        tap(element(app, "fleet.bot-detail.sessions.row.workstation.default.s1"))
        return app
    }

    private func waitForComposerEnabled(_ app: XCUIApplication) {
        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "conversation canvas should open with a composer")
        let deadline = Date().addingTimeInterval(15)
        while !composer.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(composer.isEnabled, "a too-long chat must still open with a usable composer")
    }

    /// The refused chat opens on the NEWEST page, never the start of history.
    func testLongChatOpensOnNewestPage() throws {
        let app = launch()
        waitForComposerEnabled(app)
        XCTAssertTrue(text(app, "Long chat message 25000").waitForExistence(timeout: 15),
                      "the newest message must render")
        XCTAssertFalse(text(app, "Long chat message 24800").exists,
                       "only the newest 200 rows load first")
    }

    /// "Load earlier messages" prepends the next older page in order and keeps
    /// the previously oldest row on screen (scroll position preserved).
    func testLoadEarlierPrependsOlderPageAndKeepsPlace() throws {
        let app = launch()
        waitForComposerEnabled(app)
        XCTAssertTrue(text(app, "Long chat message 25000").waitForExistence(timeout: 15))

        let loadEarlier = element(app, "fleet.conversation.load-earlier")
        scrollToTop(app, until: loadEarlier)
        XCTAssertTrue(text(app, "This is a long chat").exists,
                      "the calm paged-history notice explains the newest-first load")
        XCTAssertTrue(loadEarlier.isHittable, "Load earlier messages sits at the top of a paged chat")
        let oldestLoaded = text(app, "Long chat message 24801")
        XCTAssertTrue(oldestLoaded.exists, "the oldest loaded row is near the top before paging")
        loadEarlier.tap()

        // The reading position holds: the previously oldest row stays on
        // screen once the older page lands (the view re-anchors to it).
        let settled = Date().addingTimeInterval(15)
        while !element(app, "fleet.conversation.load-earlier").exists && Date() < settled {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(oldestLoaded.waitForExistence(timeout: 10) && oldestLoaded.isHittable,
                      "the row the reader was looking at stays on screen after the prepend")

        // The older page sits ABOVE it: scroll up a little and find it.
        let older = text(app, "Long chat message 24800")
        let deadline = Date().addingTimeInterval(20)
        while !older.exists && Date() < deadline {
            app.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(older.exists, "the next older page must prepend")
        if oldestLoaded.exists {
            XCTAssertLessThan(older.frame.minY, oldestLoaded.frame.minY,
                              "older messages render above newer ones")
        }
    }

    /// An older gateway without the paged route: the chat stays open and the
    /// user is told how to reach earlier history.
    func testUnsupportedPagingKeepsChatOpenWithActionableNotice() throws {
        let app = launch(unsupported: true)
        waitForComposerEnabled(app)
        XCTAssertTrue(text(app, "can't send it in pages").waitForExistence(timeout: 15),
                      "the unsupported-paging notice must explain the limitation")
        XCTAssertFalse(element(app, "fleet.conversation.load-earlier").exists,
                       "no paging control when the gateway cannot page")
    }
}
