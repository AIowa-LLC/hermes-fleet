import XCTest

/// F3 — QR-first enrollment and invitation safety. Simulator scans carry
/// synthetic HTTPS fixtures into the real PairingCoordinator; they never
/// contact a server or contain live credentials.
final class F3OnboardingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // Name kept: scripts/c1_critical_smoke.sh selects this case by id.
    func testFirstRunShowsOnlyQRPathAndCopyableOwnerInstructions() throws {
        let app = launch()

        XCTAssertTrue(app.otherElements["fleet.root.onboarding"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["fleet.first-run.title"].exists)
        XCTAssertEqual(app.staticTexts["fleet.first-run.title"].label, "Connect to Hermes")
        XCTAssertTrue(app.staticTexts["fleet.first-run.intro"].exists)
        XCTAssertTrue(app.staticTexts["fleet.first-run.expiry"].exists)

        // The three steps of the universal-login flow (docs/universal-login.md).
        let step1 = app.descendants(matching: .any)["fleet.first-run.step.1"].firstMatch
        XCTAssertTrue(step1.exists)
        XCTAssertTrue(step1.label.contains("/fleet pair"), "step 1 names /fleet pair")
        XCTAssertTrue(step1.label.contains("hermes fleet pair"), "step 1 names the terminal command")
        XCTAssertTrue(app.descendants(matching: .any)["fleet.first-run.step.2"].firstMatch.label.contains("scan its QR code"))
        XCTAssertTrue(app.descendants(matching: .any)["fleet.first-run.step.3"].firstMatch.label.contains("Approve the code"))

        let scan = app.buttons["fleet.first-run.scan"]
        XCTAssertTrue(scan.exists)
        XCTAssertTrue(scan.isEnabled)
        XCTAssertEqual(scan.label, "Scan QR code")
        let paste = app.buttons["fleet.first-run.paste"]
        XCTAssertTrue(paste.exists)
        XCTAssertEqual(paste.label, "Paste link")

        // No Telegram, and no legacy setup prompt, on the default path.
        XCTAssertFalse(app.staticTexts["fleet.first-run.owner-prompt"].exists)
        XCTAssertFalse(app.buttons["fleet.first-run.copy-owner-prompt"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Telegram")).firstMatch.exists,
                       "the default path must not mention Telegram")
        XCTAssertFalse(app.textFields["fleet.onboarding.address"].exists)
        XCTAssertFalse(app.textFields["fleet.onboarding.username"].exists)
        XCTAssertFalse(app.secureTextFields["fleet.onboarding.password"].exists)
        XCTAssertFalse(app.buttons["fleet.onboarding.advanced"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        attachScreenshot(of: app, name: "f3-first-run-connect-to-hermes")
    }

    func testOtherWaysToConnectHoldsOwnerSignInManualSetupAndTheLegacyPrompt() throws {
        let app = launch()
        let other = app.buttons["fleet.first-run.advanced"]
        for _ in 0..<6 where !other.isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()

        XCTAssertTrue(app.buttons["fleet.first-run.advanced.owner"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.first-run.advanced.manual"].exists)
        let copy = app.buttons["fleet.first-run.legacy.copy-owner-prompt"]
        for _ in 0..<6 where !copy.exists { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(copy.exists, "the v1 Telegram setup message lives under Other ways to connect")
        let prompt = app.staticTexts["fleet.first-run.legacy.owner-prompt"]
        XCTAssertTrue(prompt.exists)
        XCTAssertTrue(prompt.label.contains("private Telegram message from the verified owner"))
        copy.tap()
        XCTAssertTrue(app.buttons["fleet.first-run.legacy.copy-owner-prompt"].label.contains("Copied"))
        attachScreenshot(of: app, name: "f3-other-ways-to-connect")
    }

    func testInvitationPreviewRequiresExplicitPhoneConfirmation() throws {
        let app = launch(withInvitation: invitation(id: "ok0123456789abcdef"))
        openSimulatedScanner(in: app)

        XCTAssertTrue(app.staticTexts["fleet.pairing.preview.name"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["fleet.pairing.preview.host"].exists)
        XCTAssertTrue(app.staticTexts["fleet.pairing.permission-explanation"].exists)
        XCTAssertTrue(app.buttons["fleet.pairing.confirm"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists,
                       "scanning only previews; it must not add the phone")
        attachScreenshot(of: app, name: "f3-pairing-explicit-review")

        app.buttons["fleet.pairing.confirm"].tap()
        UITabNavigation.shellReady(app, timeout: 15)
        XCTAssertFalse(app.otherElements["fleet.root.onboarding"].exists)
        attachScreenshot(of: app, name: "f3-pairing-connected")
    }

    func testBackingOutBeforeConfirmationLeavesInvitationUsable() throws {
        let app = launch(withInvitation: invitation(id: "ok1123456789abcdef"))
        openSimulatedScanner(in: app)
        XCTAssertTrue(app.staticTexts["fleet.pairing.preview.name"].waitForExistence(timeout: 10))

        app.buttons["fleet.pairing.back"].tap()
        XCTAssertTrue(app.buttons["fleet.first-run.scan"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)

        // The same unconfirmed, single-use invitation can be previewed again.
        openSimulatedScanner(in: app)
        XCTAssertTrue(app.staticTexts["fleet.pairing.preview.name"].waitForExistence(timeout: 10))
        app.buttons["fleet.pairing.back"].tap()
    }

    func testUnreachablePreviewCanRetryWithoutReScanning() throws {
        let app = launch(withInvitation: invitation(id: "offline123456789abcdef"))
        openSimulatedScanner(in: app)

        XCTAssertTrue(app.staticTexts["fleet.pairing.failure.message"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.pairing.retry"].exists)
        app.buttons["fleet.pairing.retry"].tap()
        XCTAssertTrue(app.staticTexts["fleet.pairing.preview.name"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }

    func testExpiredInvitationOffersRescanWithoutExposingLink() throws {
        let expired = invitation(id: "expired123456789a")
        let app = launch(withInvitation: expired)
        openSimulatedScanner(in: app)

        XCTAssertTrue(app.staticTexts["fleet.pairing.failure.message"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.pairing.rescan"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", expired)).firstMatch.exists,
                       "the invitation secret must never be rendered in the UI")
        app.buttons["fleet.pairing.rescan"].tap()
        XCTAssertTrue(app.buttons["fleet.first-run.scan"].waitForExistence(timeout: 5))
    }

    func testCameraDenialHasSettingsRecoveryAndNoManualCredentialPath() throws {
        let app = launch(withInvitation: invitation(id: "ok2123456789abcdef"), cameraDenied: true)
        app.buttons["fleet.first-run.scan"].tap()

        XCTAssertTrue(app.staticTexts["fleet.gateways.scan.denied"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.gateways.scan.denied.settings"].exists)
        XCTAssertFalse(app.textFields["fleet.onboarding.address"].exists)
        XCTAssertFalse(app.textFields["fleet.onboarding.username"].exists)
        app.buttons["fleet.gateways.scan.cancel"].tap()
        XCTAssertTrue(app.buttons["fleet.first-run.scan"].waitForExistence(timeout: 5))
    }

    func testAdvancedOwnerSignInRemainsAvailableForAddingAnotherServer() throws {
        let app = launch(emptyFleet: false, scenario: "success")
        openAddServerEnrollment(in: app)
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        signIn(in: app, username: "owner", password: "synthetic-password")

        XCTAssertTrue(app.buttons["fleet.onboarding.connect-phone"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["fleet.onboarding.permission-explanation"].exists)
        app.buttons["fleet.onboarding.connect-phone"].tap()
        XCTAssertTrue(app.buttons["fleet.gateways.row.onboarding-fixture"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.firstMatch.exists || app.buttons["fleet.drawer.open"].exists,
                      "adding another server stays within the configured Fleet shell")
    }

    func testManualOnboardingWrongCredentialsCanBeRetried() throws {
        let app = launch(emptyFleet: false, scenario: "success")
        openAddServerEnrollment(in: app)
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        signIn(in: app, username: "owner", password: "wrong-password")
        XCTAssertTrue(app.staticTexts["fleet.onboarding.error"].waitForExistence(timeout: 10))

        let password = app.secureTextFields["fleet.onboarding.password"]
        password.tap()
        password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 32))
        password.typeText("synthetic-password")
        app.buttons["fleet.onboarding.retry"].tap()
        XCTAssertTrue(app.buttons["fleet.onboarding.connect-phone"].waitForExistence(timeout: 10))
    }

    func testManualOnboardingRequiresTLSReviewBeforeOwnerCredentials() throws {
        let app = launch(emptyFleet: false, scenario: "tls-first-use")
        openAddServerEnrollment(in: app)
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        XCTAssertTrue(app.staticTexts["fleet.onboarding.tls-fingerprint"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["fleet.onboarding.username"].exists)
        app.buttons["fleet.onboarding.tls-approve"].tap()
        XCTAssertTrue(app.textFields["fleet.onboarding.username"].waitForExistence(timeout: 10))
    }

    func testManualOnboardingReportsUnsupportedProviderAndKeepsAdvancedPath() throws {
        let app = launch(emptyFleet: false, scenario: "unsupported")
        openAddServerEnrollment(in: app)
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        XCTAssertTrue(app.staticTexts["fleet.onboarding.unsupported-provider"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["fleet.onboarding.retry"].exists)
        XCTAssertTrue(app.buttons["fleet.onboarding.dismiss"].exists)
        app.buttons["fleet.onboarding.advanced"].tap()
        XCTAssertTrue(app.textFields["fleet.gateways.form.endpoint"].waitForExistence(timeout: 10))
    }

    func testManualOnboardingPinMismatchBlocksOwnerCredentials() throws {
        let app = launch(emptyFleet: false, scenario: "pin-change")
        openAddServerEnrollment(in: app)
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        XCTAssertTrue(app.staticTexts["fleet.onboarding.error"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["fleet.onboarding.username"].exists)
        XCTAssertTrue(app.buttons["fleet.onboarding.advanced"].exists)
    }

    func testManualOnboardingDuplicateDoesNotReEnrollExistingGateway() throws {
        let app = launch(emptyFleet: false, scenario: "duplicate")
        openAddServerEnrollment(in: app)
        enterFixtureAddress(in: app)
        app.buttons["fleet.onboarding.continue"].tap()
        signIn(in: app, username: "owner", password: "synthetic-password")
        XCTAssertTrue(app.staticTexts["fleet.onboarding.error"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["fleet.onboarding.connect-phone"].exists)
        XCTAssertTrue(app.buttons["fleet.onboarding.back"].exists)
    }

    func testAdvancedGatewayFormRemainsAvailableAndDismissible() throws {
        let app = launch(emptyFleet: false)
        openAddServerEnrollment(in: app)
        let advanced = app.buttons["fleet.onboarding.advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        for _ in 0..<6 where !advanced.isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(advanced.isHittable)
        advanced.tap()
        XCTAssertTrue(app.textFields["fleet.gateways.form.endpoint"].waitForExistence(timeout: 10))
        app.buttons["fleet.gateways.form.cancel"].tap()
        app.buttons["fleet.onboarding.dismiss"].tap()
        // The owner sign-in sheet was nested in the add-server sheet.
        let cancelAdd = app.buttons["fleet.add-gateway.advanced.cancel"]
        XCTAssertTrue(cancelAdd.waitForExistence(timeout: 10))
        cancelAdd.tap()
        UITabNavigation.shellReady(app, timeout: 10)
    }

    func testBackgroundAndRelaunchDiscardUnconfirmedInvitation() throws {
        let app = launch(withInvitation: invitation(id: "slow0123456789abcdef"))
        app.buttons["fleet.first-run.scan"].tap()
        XCTAssertTrue(app.buttons["fleet.gateways.scan.simulate"].waitForExistence(timeout: 10))
        app.buttons["fleet.gateways.scan.simulate"].tap()
        XCTAssertTrue(app.staticTexts["fleet.pairing.previewing"].waitForExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["fleet.first-run.scan"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["fleet.pairing.confirm"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["fleet.first-run.scan"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["fleet.pairing.confirm"].exists)
        XCTAssertFalse(app.staticTexts["fleet.pairing.failure.message"].exists)
    }

    private func launch(
        emptyFleet: Bool = true,
        scenario: String? = nil,
        withInvitation raw: String? = nil,
        cameraDenied: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        if emptyFleet { app.launchEnvironment["HERMES_FLEET_ZERO_GATEWAYS"] = "1" }
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        if let scenario { app.launchEnvironment["HERMES_FLEET_ONBOARDING_SCENARIO"] = scenario }
        if let raw { app.launchEnvironment["HERMES_FLEET_PAIRING_SIMULATED_SCAN"] = raw }
        if cameraDenied { app.launchEnvironment["HERMES_FLEET_PAIRING_CAMERA_DENIED"] = "1" }
        app.launch()
        if emptyFleet {
            // The onboarding hierarchy can exist underneath the launch
            // artwork. A tap before that overlay leaves can hit the artwork
            // instead of Scan; wait for the actual interactive surface.
            let splash = app.descendants(matching: .any)["fleet.splash.artwork"].firstMatch
            if splash.exists {
                attachScreenshot(of: app, name: "f3-launch-artwork-before-onboarding")
            }
            XCTAssertTrue(splash.waitForNonExistence(timeout: 10),
                          "launch artwork must release the onboarding surface")
            let scan = app.buttons["fleet.first-run.scan"]
            XCTAssertTrue(scan.waitForExistence(timeout: 15))
            XCTAssertTrue(scan.isEnabled)
            XCTAssertTrue(scan.isHittable, "Scan must be visible and interactive before tapping")
        }
        return app
    }

    private func openSimulatedScanner(in app: XCUIApplication) {
        app.buttons["fleet.first-run.scan"].tap()
        let simulate = app.buttons["fleet.gateways.scan.simulate"]
        XCTAssertTrue(simulate.waitForExistence(timeout: 10), "the simulator fixture must use the normal scanner callback")
        simulate.tap()
    }

    private func openAddServerEnrollment(in app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        let add = app.buttons["fleet.gateways.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        // DEV14: additional servers default to the QR-first sheet; owner
        // sign-in remains available as a secondary Advanced setup path.
        let advanced = app.buttons["fleet.add-gateway.advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        for _ in 0..<6 where !advanced.isHittable { app.swipeUp(velocity: .fast) }
        advanced.tap()
        let owner = app.buttons["fleet.add-gateway.advanced.owner"]
        XCTAssertTrue(owner.waitForExistence(timeout: 10))
        owner.tap()
        XCTAssertTrue(app.textFields["fleet.onboarding.address"].waitForExistence(timeout: 10),
                      "owner enrollment remains available for existing fleets")
    }

    private func enterFixtureAddress(in app: XCUIApplication) {
        let address = app.textFields["fleet.onboarding.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.press(forDuration: 1.1)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
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

    private func invitation(id: String) -> String {
        "https://pairing.fixture.test/pair#v=1&i=\(id)&s=\(String(repeating: "S", count: 43))"
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
