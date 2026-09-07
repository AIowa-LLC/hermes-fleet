import XCTest

/// True Bots Mode — canonical Bot Chat tap UI tests against the scripted
/// simulator fleet (deterministic; no live gateway).
///
/// Covers the acceptance core: the tap opens the canonical chat by registry
/// identity, and a failing registry lookup shows a retryable error WITHOUT
/// navigating or creating (no transient fork).
final class BotChatTapUITests: XCTestCase {

    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // Explicit terminate avoids the relaunch race where the next test's
        // app launch is killed while this instance is still tearing down.
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

    func testCanonicalTapOpensBotChat() throws {
        let app = launch()

        // Roster → first bot row (scripted fleet has bots with routes).
        let rosterRow = app.descendants(matching: .any)["fleet.roster.row.workstation#default"]
        XCTAssertTrue(rosterRow.waitForExistence(timeout: 10))
        rosterRow.tap()

        // Bot detail shows the canonical Bot Chat open button.
        let openButton = app.descendants(matching: .any)["fleet.bot-chat.open"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 10))

        // Resolve succeeds → we land on the conversation screen.
        openButton.tap()
        let conversation = app.descendants(matching: .any)["fleet.conversation.header"]
            .waitForExistence(timeout: 10)
        XCTAssertTrue(conversation, "canonical tap must navigate to the conversation")
    }

    func testFailingRegistryLookupShowsErrorAndNeverNavigates() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_BOT_CHAT_FAIL": "1"])

        let rosterRow = app.descendants(matching: .any)["fleet.roster.row.workstation#default"]
        XCTAssertTrue(rosterRow.waitForExistence(timeout: 10))
        rosterRow.tap()

        let openButton = app.descendants(matching: .any)["fleet.bot-chat.open"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 10))
        openButton.tap()

        // Fail-closed: an error appears, the conversation screen does NOT.
        let error = app.descendants(matching: .any)["fleet.bot-chat.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10),
                      "unconfirmed registry must surface a retryable error")
        // The open button is still on screen (no navigation happened) and no
        // transcript exists — verified WITHOUT a trailing idle wait, which
        // races the runner's teardown kill on relaunch-heavy suites.
        XCTAssertTrue(openButton.exists, "a failing lookup must keep the user on bot detail")
        XCTAssertFalse(app.descendants(matching: .any)["fleet.conversation.transcript"].exists,
                       "a failing lookup must never navigate or fork")
    }
}
