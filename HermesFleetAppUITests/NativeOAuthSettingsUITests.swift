import XCTest

/// The native OAuth settings entry must keep the existing strategy picker
/// visible as a fallback when a gateway is old or local sign-in is canceled.
@MainActor
final class NativeOAuthSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOAuthSettingsShowsExistingStrategyFallback() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        UITabNavigation.openGatewayDetail(app, gateway: "workstation")
        let connectionRow = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateway-detail.workstation.connection").firstMatch
        for _ in 0..<8 where !(connectionRow.exists && connectionRow.isHittable) {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(connectionRow.waitForExistence(timeout: 10))
        connectionRow.tap()

        let authenticationButton = app.buttons["Authentication"].firstMatch
        XCTAssertTrue(authenticationButton.waitForExistence(timeout: 10))
        authenticationButton.tap()

        let strategyPicker = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateways.auth.strategy").firstMatch
        XCTAssertTrue(strategyPicker.waitForExistence(timeout: 10))
        strategyPicker.tap()
        let oauthOption = app.buttons["Sign in with OAuth"].firstMatch
        XCTAssertTrue(oauthOption.waitForExistence(timeout: 10))
        oauthOption.tap()

        XCTAssertTrue(app.buttons["fleet.gateways.auth.oauth-sign-in"].waitForExistence(timeout: 10))
        let hint = app.staticTexts["fleet.gateways.auth.oauth-hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 10))
        XCTAssertTrue(hint.label.contains("choose another existing strategy above"))
    }
}
