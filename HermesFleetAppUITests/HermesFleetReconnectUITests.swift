import XCTest

/// G1 debt (supplemental) + §32 walkthrough steps 8-9: "briefly lose
/// connectivity, reconnect without corrupting/duplicating".
///
/// Drives the DEBUG build's gateway lifecycle controls on the Gateways screen:
/// open the per-row menu → Disconnect → the row badge flips to "Disconnected";
/// open the menu → Reconnect → the row returns to a healthy state. The
/// conversation-level mid-stream drop + reconnect + replay dedupe (no
/// duplicated assistant rows/text) is proven by the hosted
/// ConversationFixtureLoopTests (real transport + in-process gateway) — this
/// UI test covers the observable lifecycle the user actually touches.
final class HermesFleetReconnectUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testGatewayDisconnectThenReconnectLifecycle() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10),
                      "Gateways screen should list Workstation")

        // Open the row menu, tap Disconnect.
        let menu = app.descendants(matching: .any)["fleet.gateways.row.workstation.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "row menu should exist")
        menu.tap()
        let disconnect = app.buttons["Disconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5), "Disconnect menu item should appear")
        disconnect.tap()

        // Row badge should flip to Disconnected (brief loss of connectivity).
        let disconnected = app.staticTexts["Disconnected"].firstMatch
        XCTAssertTrue(disconnected.waitForExistence(timeout: 10),
                      "row badge should show Disconnected after disconnect")

        // Reconnect via the same menu.
        let menuAgain = app.descendants(matching: .any)["fleet.gateways.row.workstation.menu"]
        XCTAssertTrue(menuAgain.waitForExistence(timeout: 10))
        menuAgain.tap()
        let reconnect = app.buttons["Reconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5), "Reconnect menu item should appear")
        reconnect.tap()

        // Healthy state returns (Online / Connected / Idle badge).
        let deadline = Date().addingTimeInterval(10)
        var healthy = false
        while Date() < deadline {
            if app.staticTexts["Online"].exists || app.staticTexts["Connected"].exists {
                healthy = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(healthy,
                      "row badge should return to a healthy state after reconnect")
    }

    func testBackgroundResumeAndRelaunchRetainAndThenClearConversationDraft() throws {
        let app = XCUIApplication()
        configureLockedFixtureLaunch(app)
        app.launch()
        // NAV_RESET clears ConversationDraftStore by design. Use it for the
        // first clean fixture launch only, then keep normal storage across
        // the two process relaunches below.
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = nil
        UITabNavigation.shellReady(app, timeout: 30)
        establishGatewayConnectionIntent(app)
        openDefaultFixtureConversation(app)

        let composer = app.textFields["fleet.conversation.composer"]
        let draft = "Keep this unsent note \(UUID().uuidString)"
        composer.tap()
        composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)

        // Exercise two real background/foreground transitions while the
        // debounce is pending. Background flushes the draft before protected
        // storage can become unavailable; foreground must leave the composer
        // usable and restore the user's opted-in gateway connection.
        for transition in 1...2 {
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 1)
            app.activate()
            XCTAssertTrue(composer.waitForExistence(timeout: 30),
                          "composer should return after foreground transition \(transition)")
            XCTAssertTrue(composer.isEnabled,
                          "composer should be enabled after foreground transition \(transition)")
            XCTAssertEqual(composer.value as? String, draft,
                           "background/foreground transition \(transition) must retain the exact unsent draft")
        }

        // A cold process restart must restore the same route/session draft,
        // not merely preserve text in the live SwiftUI view.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
        app.launch()
        UITabNavigation.shellReady(app, timeout: 30)
        openDefaultFixtureConversation(app, expectedRestoredDraft: draft)
        let relaunchedComposer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(relaunchedComposer.waitForExistence(timeout: 20))
        XCTAssertTrue(relaunchedComposer.isEnabled)
        XCTAssertEqual(relaunchedComposer.value as? String, draft,
                       "the draft must survive a process relaunch for workstation/default/s1")

        // The default scripted session accepts prompt.submit. A successful
        // send clears the persisted draft as well as the visible composer.
        let send = app.descendants(matching: .any)
            .matching(identifier: "fleet.conversation.send").firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.tap()
        let submittedPrompt = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", draft)).firstMatch
        XCTAssertTrue(submittedPrompt.waitForExistence(timeout: 20),
                      "the exact draft should appear in the transcript after submission")
        let fixtureReply = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Hello from the scripted fleet")).firstMatch
        XCTAssertTrue(fixtureReply.waitForExistence(timeout: 20),
                      "the scripted session should complete the successful fixture send")
        let cleared = NSPredicate(format: "value == %@", "Message")
        let clearedExpectation = XCTNSPredicateExpectation(predicate: cleared, object: relaunchedComposer)
        XCTAssertEqual(XCTWaiter.wait(for: [clearedExpectation], timeout: 20), .completed,
                       "successful fixture send should clear the composer")

        // Verify the clear reached durable draft storage, rather than only
        // clearing the current text field's in-memory state.
        app.terminate()
        app.launch()
        UITabNavigation.shellReady(app, timeout: 30)
        openDefaultFixtureConversation(app, forceOpenExactSession: true)
        let afterSendComposer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(afterSendComposer.waitForExistence(timeout: 20))
        XCTAssertTrue(afterSendComposer.isEnabled)
        let restoredAfterSend = afterSendComposer.value as? String
        XCTAssertTrue(restoredAfterSend == nil || restoredAfterSend == "" || restoredAfterSend == "Message",
                      "a sent prompt must not reappear as a draft after relaunch (value: \(String(describing: restoredAfterSend)))")
    }

    private func configureLockedFixtureLaunch(_ app: XCUIApplication) {
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "enabled"
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_LOCK_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
    }

    private func establishGatewayConnectionIntent(_ app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        let menu = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateways.row.workstation.menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "Workstation row menu should exist")
        menu.tap()
        let disconnect = app.buttons["Disconnect"].firstMatch
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        disconnect.tap()
        XCTAssertTrue(app.staticTexts["Disconnected"].firstMatch.waitForExistence(timeout: 10))

        let reconnectMenu = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateways.row.workstation.menu").firstMatch
        XCTAssertTrue(reconnectMenu.waitForExistence(timeout: 10))
        reconnectMenu.tap()
        let reconnect = app.buttons["Reconnect"].firstMatch
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        reconnect.tap()
        let deadline = Date().addingTimeInterval(20)
        var isHealthy = false
        while Date() < deadline {
            if app.staticTexts["Online"].exists || app.staticTexts["Connected"].exists {
                isHealthy = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(isHealthy, "explicit Reconnect should establish intended gateway connectivity")
    }

    private func openDefaultFixtureConversation(
        _ app: XCUIApplication,
        expectedRestoredDraft: String? = nil,
        forceOpenExactSession: Bool = false
    ) {
        // Normal launch restoration keeps the Chats stack, which can already
        // place the app on the exact conversation. Accept that restored route
        // before touching another destination: selecting Fleet alone retains
        // its deeper navigation stack and is not a root-pop gesture.
        let restoredComposer = app.textFields["fleet.conversation.composer"].firstMatch
        if !forceOpenExactSession && restoredComposer.waitForExistence(timeout: 8) {
            XCTAssertTrue(restoredComposer.isEnabled,
                          "the restored workstation/default conversation should be ready")
            let profile = app.buttons["fleet.conversation.header.profile"].firstMatch
            XCTAssertTrue(profile.waitForExistence(timeout: 10),
                          "the restored conversation should expose its profile identity")
            XCTAssertEqual(profile.value as? String, "default",
                           "the restored conversation must remain on the default profile")
            let routeIdentity = app.staticTexts["fleet.conversation.header.title"].firstMatch
            XCTAssertTrue(routeIdentity.waitForExistence(timeout: 10),
                          "the restored conversation should expose its route identity")
            XCTAssertEqual(routeIdentity.label, "workstation#default",
                           "the restored conversation must remain on workstation/default")
            if let expectedRestoredDraft {
                let expectedValue = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", expectedRestoredDraft),
                    object: restoredComposer)
                XCTAssertEqual(XCTWaiter.wait(for: [expectedValue], timeout: 10), .completed,
                               "the exact unsent draft should be restored in its conversation")
            }
            return
        }

        // If no route was restored, use the shell's explicit root helper. It
        // handles retained deeper stacks through the product's reselect-root
        // affordance before opening Gateways.
        UITabNavigation.openTabToFleet(app)
        UITabNavigation.openGatewaysTab(app)
        let gateway = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateways.row.workstation").firstMatch
        XCTAssertTrue(gateway.waitForExistence(timeout: 15))
        gateway.tap()
        UITabNavigation.openGatewayBots(app)
        let defaultProfile = app.descendants(matching: .any)
            .matching(identifier: "fleet.roster.row.workstation#default").firstMatch
        XCTAssertTrue(defaultProfile.waitForExistence(timeout: 15))
        defaultProfile.tap()
        let session = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot-detail.sessions.row.workstation.default.s1").firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15),
                      "the scripted default profile must expose session s1")
        session.tap()
        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed,
                       "the exact fixture conversation must be ready before editing")
    }
}
