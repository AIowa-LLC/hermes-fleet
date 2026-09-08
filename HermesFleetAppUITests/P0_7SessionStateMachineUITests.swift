import XCTest

/// P0-7 dogfood defects (Tony, TestFlight 0.1.0(3) over tailnet):
///   (1) opening an EXISTING session and sending a message failed with
///       "invalid gateway connection state: connect() from open" after the
///       conversation screen had been entered once before (re-entry against
///       the shared per-gateway transport);
///   (2) there was NO UI to create a new session at all.
///
/// Deterministic scripted-fleet coverage for both, mirroring the live
/// dogfood flow: Bot detail → session row → send → pop → RE-ENTER → send
/// again (must stream, no state error), plus Bot detail → New Session →
/// send (session.create path).
final class P0_7SessionStateMachineUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Acceptance (a)+(c): open an existing session, send, pop, RE-ENTER,
    /// send again — the reply must stream both times and no
    /// "connect() from open" error may render anywhere.
    func testExistingSessionReEntrySendsWithoutConnectFromOpen() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        // Drill to Bot detail (Workstation → Default).
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        let botRow = firstMatch(in: app, identifier: "fleet.roster.row.workstation#default")
        if !botRow.waitForExistence(timeout: 5) {
            for _ in 0..<6 where !botRow.exists { app.swipeUp(velocity: .fast) }
        }
        tap(botRow)
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10),
            "Bot detail should render")

        // First entry into the existing session "Fleet setup".
        tap(firstMatch(in: app, identifier: "fleet.bot-detail.sessions.row.workstation.default.s1"))
        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Conversation canvas opens")

        waitUntilEnabled(composer, timeout: 10)
        composer.tap()
        composer.typeText("first visit")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))
        let firstAnswer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "You said: first visit"))
            .firstMatch
        XCTAssertTrue(firstAnswer.waitForExistence(timeout: 15),
                      "First entry: streamed reply must render")

        // POP back, then RE-ENTER the same session. FOS-1 (§6) canonical
        // owner routing: an ordinary conversation lives on the CHATS stack,
        // so Back pops within Chats — re-enter the exact session from there.
        tapBackButton(app)
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10),
                      "Back from an ordinary conversation lands on its owning Chats stack")
        let reentry = app.descendants(matching: .any)
            .matching(identifier: "fleet.chats.session.workstation#default/workstation.default.s1").firstMatch
        if !reentry.waitForExistence(timeout: 5) {
            for _ in 0..<6 where !reentry.exists { app.swipeUp(velocity: .fast) }
        }
        tap(reentry)
        XCTAssertTrue(composer.waitForExistence(timeout: 10),
                      "Re-entered conversation canvas opens")

        // THE P0-7 assertion: re-entered send streams a reply, and the
        // in-conversation error surface stays empty (no "connect() from open").
        waitUntilEnabled(composer, timeout: 10)
        composer.tap()
        composer.typeText("second visit")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))
        let secondAnswer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "You said: second visit"))
            .firstMatch
        XCTAssertTrue(secondAnswer.waitForExistence(timeout: 15),
                      "Re-entry: streamed reply must render over the still-open transport")

        let errorBanner = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "invalid gateway connection state"))
            .firstMatch
        XCTAssertFalse(errorBanner.exists,
                       "No 'invalid gateway connection state' error may render after re-entry")
    }

    /// Acceptance (b): the New Session affordance on the sessions list opens
    /// a fresh conversation (session.create) that is immediately usable.
    func testNewSessionAffordanceCreatesUsableConversation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        let botRow = firstMatch(in: app, identifier: "fleet.roster.row.workstation#default")
        if !botRow.waitForExistence(timeout: 5) {
            for _ in 0..<6 where !botRow.exists { app.swipeUp(velocity: .fast) }
        }
        tap(botRow)
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10),
            "Bot detail should render")

        // The P0-7 affordance: "New Session" on the sessions list.
        let newSession = firstMatch(in: app, identifier: "fleet.bot-detail.sessions.new")
        XCTAssertTrue(newSession.waitForExistence(timeout: 10),
                      "New Session affordance must exist on the sessions list")
        tap(newSession)

        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10),
                      "New session conversation canvas opens with a composer")

        // Usable immediately: send a prompt, receive the streamed reply
        // (session.create → prompt.submit over the scripted fleet).
        waitUntilEnabled(composer, timeout: 10)
        composer.tap()
        composer.typeText("brand new")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))
        let answer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "You said: brand new"))
            .firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15),
                      "New session must be usable: streamed reply renders")
    }

    // MARK: helpers (mirroring the shared UI-test helpers)

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing element: \(element)")
        element.tap()
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", identifier))
            .firstMatch
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(element.isEnabled, "Element never became enabled: \(element)")
    }

    private func tapBackButton(_ app: XCUIApplication) {
        // Navigation back: iOS 26 exposes the system back as "BackButton"
        // (toolbar actions share the bar query — never tap firstMatch).
        let back = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Back button must exist")
        back.tap()
    }
}
