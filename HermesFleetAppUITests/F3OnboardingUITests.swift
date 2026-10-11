import XCTest

/// F3 — owner enrollment and first-run gate regressions. All gateway
/// interactions use the DEBUG scripted enrollment service and synthetic
/// fixture credentials; these tests never contact a live server.
final class F3OnboardingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String = "success", emptyFleet: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        if emptyFleet { app.launchEnvironment["HERMES_FLEET_ZERO_GATEWAYS"] = "1" }
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_ONBOARDING_SCENARIO"] = scenario
        app.launch()
        return app
    }

    func testFreshInstallShowsAddressAndPrerequisitesWithoutPromptFlow() throws {
        let app = launch()
        XCTAssertTrue(app.textFields["fleet.onboarding.address"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["fleet.onboarding.continue"].exists)
        XCTAssertTrue(app.staticTexts["fleet.onboarding.prerequisite"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["fleet.onboarding.copy"].exists)
        XCTAssertFalse(app.buttons["fleet.onboarding.scan"].exists)
        XCTAssertFalse(app.buttons["fleet.onboarding.docs"].exists)
        attachScreenshot(of: app, name: "f3-owner-enrollment-address")
    }

    func testProviderDetectionPasswordSignInAndExplicitPhoneEnrollment() throws {
        let app = launch()
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()

        let username = app.textFields["fleet.onboarding.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10), "provider discovery should open its sign-in form")
        XCTAssertTrue(app.staticTexts["fleet.onboarding.provider"].exists,
                      "the detected provider is named before credentials are entered")
        username.tap()
        username.typeText("owner")
        let password = app.secureTextFields["fleet.onboarding.password"]
        password.tap()
        password.typeText("synthetic-password")
        app.buttons["fleet.onboarding.sign-in"].tap()

        let connect = app.buttons["fleet.onboarding.connect-phone"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "sign-in should lead to a deliberate confirmation")
        XCTAssertTrue(app.staticTexts["fleet.onboarding.server-name"].exists,
                      "server name should come from authenticated metadata")
        XCTAssertTrue(app.staticTexts["fleet.onboarding.permission-explanation"].exists,
                      "the account-level operator access must be explained before enrollment")
        connect.tap()

        UITabNavigation.shellReady(app, timeout: 15)
        XCTAssertFalse(app.otherElements["fleet.root.onboarding"].exists)
        attachScreenshot(of: app, name: "f3-owner-enrollment-connected")
    }

    func testCancelDuringLateEnrollmentDoesNotAdoptPhone() throws {
        let app = launch("delayed-enroll")
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        signIn(in: app, username: "owner", password: "synthetic-password")
        let connect = app.buttons["fleet.onboarding.connect-phone"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        let connecting = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Connecting…"),
            object: connect)
        XCTAssertEqual(XCTWaiter.wait(for: [connecting], timeout: 5), .completed)
        let cancel = app.buttons["fleet.onboarding.cancel-flow"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(app.textFields["fleet.onboarding.address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["fleet.onboarding.request-pending"].exists)
        let continueButton = app.buttons["fleet.onboarding.continue"]
        XCTAssertFalse(continueButton.isEnabled,
                       "a new enrollment must wait until the canceled request and rollback settle")
        let shellAppeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: app.tabBars.firstMatch)
        shellAppeared.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [shellAppeared], timeout: 11), .completed)
        XCTAssertTrue(app.textFields["fleet.onboarding.address"].exists,
                      "a late server response must not move the canceled flow to the Fleet shell")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let requestSettled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: continueButton)
        XCTAssertEqual(XCTWaiter.wait(for: [requestSettled], timeout: 5), .completed)
    }

    func testCancelDelayedEnrollmentFromAddGatewayKeepsFleetUnchanged() throws {
        let app = launch("delayed-enroll", emptyFleet: false)
        UITabNavigation.openGatewaysTab(app)
        let gatewayRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "fleet.gateways.row."))
        XCTAssertTrue(app.otherElements["fleet.gateways.row.workstation"].waitForExistence(timeout: 10))
        let initialGatewayRowCount = gatewayRows.count
        XCTAssertGreaterThan(initialGatewayRowCount, 0)

        app.buttons["fleet.gateways.add"].tap()
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        signIn(in: app, username: "owner", password: "synthetic-password")
        let connect = app.buttons["fleet.onboarding.connect-phone"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        let connecting = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Connecting…"),
            object: connect)
        XCTAssertEqual(XCTWaiter.wait(for: [connecting], timeout: 5), .completed)
        app.buttons["fleet.onboarding.dismiss"].tap()

        let lateGateway = app.descendants(matching: .any)["fleet.gateways.row.onboarding-fixture"]
        let lateAdoption = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: lateGateway)
        lateAdoption.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [lateAdoption], timeout: 11), .completed)
        XCTAssertEqual(gatewayRows.count, initialGatewayRowCount,
                       "canceling Add Gateway must not adopt the delayed phone enrollment")
        XCTAssertTrue(app.otherElements["fleet.gateways.row.workstation"].exists)
    }

    func testWrongCredentialsCanBeRetriedSuccessfully() throws {
        let app = launch()
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        signIn(in: app, username: "owner", password: "wrong-password")
        XCTAssertTrue(app.staticTexts["fleet.onboarding.error"].waitForExistence(timeout: 10))
        let password = app.secureTextFields["fleet.onboarding.password"]
        XCTAssertTrue(password.exists)
        password.tap()
        password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 32))
        password.typeText("synthetic-password")
        app.buttons["fleet.onboarding.retry"].tap()
        XCTAssertTrue(app.buttons["fleet.onboarding.connect-phone"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.onboarding.back"].exists)
        app.buttons["fleet.onboarding.connect-phone"].tap()
        UITabNavigation.shellReady(app, timeout: 15)
    }

    func testUnsupportedProviderOffersRetryEditCancelAndAdvancedSetup() throws {
        let app = launch("unsupported")
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        XCTAssertTrue(app.staticTexts["fleet.onboarding.unsupported-provider"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.onboarding.retry"].exists)
        XCTAssertTrue(app.buttons["fleet.onboarding.cancel"].exists)
        XCTAssertTrue(app.buttons["fleet.onboarding.advanced"].exists)
        app.buttons["fleet.onboarding.cancel"].tap()
        XCTAssertTrue(app.textFields["fleet.onboarding.address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["fleet.onboarding.advanced"].exists)
    }

    func testUnavailableServerCanRetryOrEditAddress() throws {
        let app = launch("unavailable")
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        XCTAssertTrue(app.staticTexts["fleet.onboarding.error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.onboarding.retry"].exists)
        XCTAssertTrue(app.textFields["fleet.onboarding.address"].exists)
    }

    func testFirstUseTLSKeyRequiresExplicitReviewBeforeProviderDiscovery() throws {
        let app = launch("tls-first-use")
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        XCTAssertTrue(app.staticTexts["fleet.onboarding.tls-fingerprint"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["fleet.onboarding.username"].exists,
                       "credentials must not be requested before key approval")
        app.buttons["fleet.onboarding.tls-approve"].tap()
        XCTAssertTrue(app.textFields["fleet.onboarding.username"].waitForExistence(timeout: 10))
    }

    func testPinMismatchBlocksSignInAndKeepsAddressEditable() throws {
        let app = launch("pin-change")
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        XCTAssertTrue(app.staticTexts["fleet.onboarding.error"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["fleet.onboarding.username"].exists,
                       "a changed key must block password entry")
        XCTAssertTrue(app.textFields["fleet.onboarding.address"].exists)
        XCTAssertTrue(app.buttons["fleet.onboarding.advanced"].exists)
    }

    func testRateLimitedProviderDiscoveryCanRetry() throws {
        let app = launch("rate-limit")
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        XCTAssertTrue(app.staticTexts["fleet.onboarding.error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.onboarding.retry"].exists)
    }

    func testCredentialStorageFailureKeepsEnrollmentRetryVisible() throws {
        let app = launch("keychain-failure")
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        signIn(in: app, username: "owner", password: "synthetic-password")
        XCTAssertTrue(app.buttons["fleet.onboarding.connect-phone"].waitForExistence(timeout: 10))
        app.buttons["fleet.onboarding.connect-phone"].tap()
        XCTAssertTrue(app.staticTexts["fleet.onboarding.error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.onboarding.retry"].exists)
    }

    func testDuplicateGatewayIsNotReplaced() throws {
        let app = launch("duplicate", emptyFleet: false)
        UITabNavigation.openGatewaysTab(app)
        app.buttons["fleet.gateways.add"].tap()
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        signIn(in: app, username: "owner", password: "synthetic-password")
        XCTAssertTrue(app.staticTexts["fleet.onboarding.error"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["fleet.onboarding.connect-phone"].exists,
                       "a duplicate server must never be re-enrolled")
        XCTAssertTrue(app.buttons["fleet.onboarding.back"].exists)
    }

    func testAdvancedGatewayFormRemainsAvailableAndDismissible() throws {
        let app = launch()
        app.buttons["fleet.onboarding.advanced"].tap()
        XCTAssertTrue(app.textFields["fleet.gateways.form.endpoint"].waitForExistence(timeout: 10))
        app.buttons["fleet.gateways.form.cancel"].tap()
        XCTAssertTrue(app.textFields["fleet.onboarding.address"].waitForExistence(timeout: 5))
    }

    private func enterFixtureAddress(in app: XCUIApplication) {
        let address = app.textFields["fleet.onboarding.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.press(forDuration: 1.1)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        address.typeText("https://onboarding.fixture.test")
    }

    private func signIn(in app: XCUIApplication, username: String, password: String) {
        let usernameField = app.textFields["fleet.onboarding.username"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 10))
        usernameField.tap()
        usernameField.typeText(username)
        let passwordField = app.secureTextFields["fleet.onboarding.password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["fleet.onboarding.sign-in"].tap()
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
