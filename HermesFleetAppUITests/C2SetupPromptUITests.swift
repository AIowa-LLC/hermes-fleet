import XCTest

/// C2 — existing users add another server through the same QR-first guidance
/// as first run: "Connect to Hermes" with Scan QR code, Paste link, Cancel, and a secondary
/// "Other ways to connect" that holds the legacy Telegram setup prompt. Keep the registered
/// suite name stable.
final class C2SetupPromptUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(simulatedScan: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        if let simulatedScan { app.launchEnvironment["HERMES_FLEET_PAIRING_SIMULATED_SCAN"] = simulatedScan }
        app.launch()
        return app
    }

    private func invitation(id: String) -> String {
        "https://pairing.fixture.test/pair#v=1&i=\(id)&s=\(String(repeating: "S", count: 43))"
    }

    private func openFromSettings(_ app: XCUIApplication) {
        UITabNavigation.openSettings(app)
        let row = app.buttons["fleet.settings.connect-server"]
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "configured users must have a path to connect another server")
        for _ in 0..<8 where !row.isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(row.isHittable, "the Settings enrollment entry must be onscreen before tapping")
        row.tap()
    }

    private func openFromGateways(_ app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        let add = app.buttons["fleet.gateways.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
    }

    /// Asserts the sheet's actions, then scan -> back -> scan again.
    private func exerciseAddSheet(_ app: XCUIApplication, simulated: Bool) {
        let scan = app.buttons["fleet.add-gateway.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10), "Scan QR code must be visible")
        XCTAssertEqual(scan.label, "Scan QR code")
        XCTAssertEqual(app.buttons["fleet.add-gateway.paste"].label, "Paste link")
        XCTAssertTrue(app.buttons["fleet.add-gateway.cancel"].exists)
        XCTAssertTrue(app.buttons["fleet.add-gateway.advanced"].exists, "Other ways to connect stays available")
        XCTAssertFalse(app.textFields["fleet.onboarding.address"].exists,
                       "the old address-first flow must not be the default")
        XCTAssertEqual(app.staticTexts["fleet.add-gateway.title"].label, "Connect to Hermes")
        XCTAssertTrue(app.descendants(matching: .any)["fleet.add-gateway.step.1"].firstMatch.label.contains("/fleet pair"))
        XCTAssertFalse(app.buttons["fleet.add-gateway.copy-owner-prompt"].exists,
                       "the Telegram prompt is no longer on the default path")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Telegram")).firstMatch.exists)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "add-gateway-sheet"
        shot.lifetime = .keepAlways
        add(shot)

        guard simulated else { return }
        for round in 1...2 {
            scan.tap()
            let simulate = app.buttons["fleet.gateways.scan.simulate"]
            XCTAssertTrue(simulate.waitForExistence(timeout: 10), "round \(round): simulated scanner")
            simulate.tap()
            XCTAssertTrue(app.buttons["fleet.pairing.confirm"].waitForExistence(timeout: 10),
                          "round \(round): scan must preview, not add")
            let back = app.buttons["fleet.pairing.back"]
            XCTAssertTrue(back.exists)
            back.tap()
            XCTAssertTrue(scan.waitForExistence(timeout: 10),
                          "round \(round): backing out returns to the add-server sheet")
        }
    }

    func testSettingsAddServerShowsQRFirstActionsAndRescan() throws {
        let app = launch(simulatedScan: invitation(id: "ok0123456789abcdef"))
        openFromSettings(app)
        exerciseAddSheet(app, simulated: true)
        app.buttons["fleet.add-gateway.cancel"].tap()
        XCTAssertTrue(app.buttons["fleet.settings.connect-server"].waitForExistence(timeout: 10),
                      "cancel returns to Settings with the fleet intact")
        XCTAssertFalse(app.buttons["fleet.first-run.scan"].exists, "cancel must not reset into onboarding")
        UITabNavigation.openGatewaysTab(app)
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 10),
                      "the already-saved gateway survives scan/cancel/rescan")
    }

    func testGatewaysPlusShowsQRFirstActionsAndRescan() throws {
        let app = launch(simulatedScan: invitation(id: "ok0123456789abcdef"))
        openFromGateways(app)
        exerciseAddSheet(app, simulated: true)
        app.buttons["fleet.add-gateway.cancel"].tap()
        XCTAssertTrue(app.buttons["fleet.gateways.add"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["fleet.first-run.scan"].exists, "cancel must not reset into onboarding")
        XCTAssertTrue(app.staticTexts["Workstation"].exists, "the saved gateway is untouched")
    }

    func testAdvancedSetupKeepsOwnerSignInReachable() throws {
        let app = launch()
        openFromSettings(app)
        let advanced = app.buttons["fleet.add-gateway.advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        for _ in 0..<6 where !advanced.isHittable { app.swipeUp(velocity: .fast) }
        advanced.tap()
        XCTAssertTrue(app.buttons["fleet.add-gateway.advanced.manual"].waitForExistence(timeout: 10))
        let legacyCopy = app.buttons["fleet.add-gateway.legacy.copy-owner-prompt"]
        for _ in 0..<6 where !legacyCopy.exists { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(legacyCopy.exists, "the legacy Telegram prompt lives under Other ways to connect")
        legacyCopy.tap()
        XCTAssertTrue(app.buttons["fleet.add-gateway.legacy.copy-owner-prompt"].label.contains("Copied"))
        for _ in 0..<6 where !app.buttons["fleet.add-gateway.advanced.owner"].isHittable { app.swipeDown(velocity: .fast) }
        app.buttons["fleet.add-gateway.advanced.owner"].tap()
        XCTAssertTrue(app.textFields["fleet.onboarding.address"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.onboarding.dismiss"].exists)
        app.buttons["fleet.onboarding.dismiss"].tap()
        // Still on the Advanced page of the add-server sheet.
        XCTAssertTrue(app.buttons["fleet.add-gateway.advanced.cancel"].waitForExistence(timeout: 10))
        app.buttons["fleet.add-gateway.advanced.cancel"].tap()
        XCTAssertTrue(app.buttons["fleet.settings.connect-server"].waitForExistence(timeout: 10))
    }
}
