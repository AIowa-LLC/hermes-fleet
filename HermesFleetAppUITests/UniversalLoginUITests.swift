import XCTest

/// Universal login (Build 17) against the scripted simulator fleet: the Connect to Hermes
/// screen, paste/scan intake, the confirm step, the waiting screen with its match code, and the
/// scripted owner's decision. Synthetic hosts and keys only; nothing here touches a network.
final class UniversalLoginUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 43-character base64url pin (32 bytes of 0x03) and a 43-character synthetic secret.
    private var pin: String {
        Data(repeating: 3, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func link(id: String) -> String {
        "https://pairing.fixture.test/pair#v=2&i=\(id)&s=\(String(repeating: "S", count: 43))&k=\(pin)"
    }

    private func launch(
        paste: String? = nil, scan: String? = nil, emptyFleet: Bool = true, approveAfter: String = "6"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        if emptyFleet { app.launchEnvironment["HERMES_FLEET_ZERO_GATEWAYS"] = "1" }
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_PAIRING_APPROVE_AFTER"] = approveAfter
        if let paste { app.launchEnvironment["HERMES_FLEET_PAIRING_SIMULATED_PASTE"] = paste }
        if let scan { app.launchEnvironment["HERMES_FLEET_PAIRING_SIMULATED_SCAN"] = scan }
        app.launch()
        if emptyFleet {
            let splash = app.descendants(matching: .any)["fleet.splash.artwork"].firstMatch
            XCTAssertTrue(splash.waitForNonExistence(timeout: 10), "launch artwork must release the screen")
            XCTAssertTrue(app.buttons["fleet.first-run.paste"].waitForExistence(timeout: 15))
        }
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: paste -> confirm -> awaiting approval -> approved -> connected

    func testPasteConfirmAwaitApprovalThenConnect() throws {
        // Keep the synthetic owner pending while UI automation inspects and taps the copy control.
        let app = launch(paste: link(id: "ok0123456789abcdef"), approveAfter: "30")

        app.buttons["fleet.first-run.paste"].tap()
        XCTAssertTrue(app.buttons["fleet.pairing.confirm"].waitForExistence(timeout: 10),
                      "pasting previews the link; it does not connect")
        XCTAssertTrue(element(app, "fleet.pairing.approval-hint").exists,
                      "a v2 link explains that a code will be shown")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        attach("universal-login-confirm")

        app.buttons["fleet.pairing.confirm"].tap()

        // The waiting screen: the code, the command to send, the terminal alternative, Cancel.
        let code = element(app, "fleet.pairing.approval.code")
        XCTAssertTrue(code.waitForExistence(timeout: 10), "the match code must be shown while waiting")
        XCTAssertEqual(code.label, "Match code 4, 8, 2, 9, 1, 3", "VoiceOver reads the digits one by one")
        XCTAssertTrue(element(app, "fleet.pairing.approval.command").label.contains("/fleet approve 482913"))
        XCTAssertTrue(element(app, "fleet.pairing.approval.terminal").label.contains("hermes fleet pair"))
        XCTAssertTrue(app.buttons["fleet.pairing.approval.copy"].exists)
        XCTAssertTrue(app.buttons["fleet.pairing.approval.cancel"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "nothing is added before the owner approves")
        attach("universal-login-awaiting-approval")

        app.buttons["fleet.pairing.approval.copy"].tap()
        XCTAssertTrue(app.buttons["fleet.pairing.approval.copy"].label.contains("Copied"))

        // The scripted owner approves; the phone collects the credential and connects.
        UITabNavigation.shellReady(app, timeout: 30)
        XCTAssertFalse(app.otherElements["fleet.root.onboarding"].exists)
        attach("universal-login-connected")
    }

    // MARK: scan -> confirm -> cancel while waiting (additional server)

    func testScanConfirmThenCancelWhileWaitingLeavesTheFleetUntouched() throws {
        let app = launch(scan: link(id: "pending0123456789abcd"), emptyFleet: false, approveAfter: "never")
        UITabNavigation.openGatewaysTab(app)
        app.buttons["fleet.gateways.add"].tap()

        let scan = app.buttons["fleet.add-gateway.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        scan.tap()
        let simulate = app.buttons["fleet.gateways.scan.simulate"]
        XCTAssertTrue(simulate.waitForExistence(timeout: 10))
        simulate.tap()
        XCTAssertTrue(app.buttons["fleet.pairing.confirm"].waitForExistence(timeout: 10))
        app.buttons["fleet.pairing.confirm"].tap()

        XCTAssertTrue(element(app, "fleet.pairing.approval.code").waitForExistence(timeout: 10))
        // Still waiting after several poll intervals: an undecided request stays on screen.
        sleep(3)
        XCTAssertTrue(element(app, "fleet.pairing.approval.code").exists)

        app.buttons["fleet.pairing.approval.cancel"].tap()
        XCTAssertTrue(app.buttons["fleet.add-gateway.scan"].waitForExistence(timeout: 10),
                      "cancelling returns to the Connect to Hermes screen")
        XCTAssertFalse(element(app, "fleet.pairing.approval.code").exists)
        app.buttons["fleet.add-gateway.cancel"].tap()
        XCTAssertTrue(app.buttons["fleet.gateways.add"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Workstation"].exists, "the saved gateway is untouched")
    }

    // MARK: owner denies

    func testADeniedRequestShowsHowToGetANewLink() throws {
        let app = launch(paste: link(id: "denied0123456789abcdef"), approveAfter: "2")
        app.buttons["fleet.first-run.paste"].tap()
        XCTAssertTrue(app.buttons["fleet.pairing.confirm"].waitForExistence(timeout: 10))
        app.buttons["fleet.pairing.confirm"].tap()

        XCTAssertTrue(element(app, "fleet.pairing.denied").waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "fleet.pairing.ended.guidance").label.contains("/fleet pair"))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        attach("universal-login-denied")
        app.buttons["fleet.pairing.denied.done"].tap()
        XCTAssertTrue(app.buttons["fleet.first-run.paste"].waitForExistence(timeout: 10))
    }

    // MARK: request lapses

    func testAnExpiredRequestShowsHowToGetANewLink() throws {
        let app = launch(paste: link(id: "lapsed0123456789abcdef"), approveAfter: "2")
        app.buttons["fleet.first-run.paste"].tap()
        XCTAssertTrue(app.buttons["fleet.pairing.confirm"].waitForExistence(timeout: 10))
        app.buttons["fleet.pairing.confirm"].tap()

        XCTAssertTrue(element(app, "fleet.pairing.expired").waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "fleet.pairing.ended.guidance").label.contains("hermes fleet pair"))
        app.buttons["fleet.pairing.expired.done"].tap()
        XCTAssertTrue(app.buttons["fleet.first-run.paste"].waitForExistence(timeout: 10))
    }

    // MARK: not a link

    func testPastingSomethingThatIsNotALinkExplainsItAndLeavesNothingAdded() throws {
        let app = launch(paste: "hello there")
        app.buttons["fleet.first-run.paste"].tap()
        XCTAssertTrue(element(app, "fleet.pairing.failure.message").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["fleet.pairing.confirm"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }
}
