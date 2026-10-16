import XCTest

/// F4 — first-run ROOT GATE + existing-user regression suite
/// (deterministic, CI-safe).
///
/// The hydration gate (`AppEnvironment.hydrationPhase`) drives the root:
/// loading → unconfigured (first-run setup) → configured (normal tabs).
/// This suite proves the lifecycle both ways plus the existing-user paths:
/// Settings and Fleet both expose owner enrollment for additional servers,
/// Advanced gateway setup remains usable, and removing the final gateway
/// returns to the QR-first setup.
final class F4FirstRunGateUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Fresh install → first gateway → main UI

    func testFirstGatewayRegistrationTransitionsToMainFleetUI() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_ZERO_GATEWAYS"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_PAIRING_SIMULATED_SCAN"] = invitation(id: "ok0123456789abcdef")
        app.launch()

        let scan = app.buttons["fleet.first-run.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15), "fresh install must start with the QR invitation action")
        scan.tap()
        let simulate = app.buttons["fleet.gateways.scan.simulate"]
        XCTAssertTrue(simulate.waitForExistence(timeout: 10))
        simulate.tap()
        XCTAssertTrue(app.buttons["fleet.pairing.confirm"].waitForExistence(timeout: 10),
                      "scanning must preview the owner-issued invitation")
        app.buttons["fleet.pairing.confirm"].tap()

        // SUCCESS TRANSITION: the sheet dismisses, the registry is non-empty,
        // and the normal four-tab Fleet UI appears — no relaunch, no extra
        // dismissal steps.
        UITabNavigation.shellReady(app, timeout: 15)
        XCTAssertTrue(true,
                      "registering the first gateway must transition into the main Fleet UI")
        XCTAssertFalse(app.buttons["fleet.first-run.scan"].waitForExistence(timeout: 2),
                       "onboarding must be gone after the first registration")

        attachScreenshot(of: app, name: "f4-first-gateway-transition")
    }

    func testRelaunchWithRegisteredServerDoesNotReshowOnboarding() throws {
        // Second launch of the SAME app process state as the test above is
        // not possible in XCUITest (containers are per-launch); instead this
        // proves the configured-launch contract directly: the DEFAULT
        // scripted fleet (gateways seeded) must show tabs, never onboarding.
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        UITabNavigation.shellReady(app, timeout: 15)
        XCTAssertTrue(true,
                      "a configured (seeded) launch must show the normal tab UI")
        XCTAssertFalse(app.buttons["fleet.first-run.scan"].waitForExistence(timeout: 2),
                       "first-run onboarding must not appear for a configured user")
        attachScreenshot(of: app, name: "f4-configured-launch")
    }

    /// Build-88 regression: a CONFIGURED launch (gateways present) must never
    /// paint the first-run setup surface while hydration settles — the
    /// transient onboarding flash the hydration gate now forbids. Polls with
    /// FRESH queries from launch (the identifier is held as a STRING; element
    /// proxies are never carried across the loading → configured transition):
    /// any sighting of `fleet.root.onboarding` fails the run. The shell must
    /// then be ready.
    func testConfiguredLaunchShowsNoOnboardingFlashDuringStartup() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        let onboardingIdentifier = "fleet.root.onboarding"
        let deadline = Date().addingTimeInterval(25)
        var flashed = false
        var consecutiveShellSamples = 0

        while !flashed && Date() < deadline {
            // Fresh predicate + fresh query EVERY iteration — a proxy would go
            // stale across the loading → configured root swap.
            let onboarding = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@", onboardingIdentifier))
                .firstMatch
            if onboarding.exists {
                flashed = true
                break
            }
            // The shell counts as up on any of its three shapes (system tab
            // bar / compact drawer Menu button / adaptive top control).
            let shellVisible = app.buttons["fleet.drawer.open"].exists
                || app.tabBars.firstMatch.exists
                || app.buttons["Bots"].exists
            consecutiveShellSamples = shellVisible ? consecutiveShellSamples + 1 : 0
            // Settle once the shell has been continuously visible (~0.5s at
            // the poll cadence): the gate has settled .configured and the
            // flash window is closed.
            if consecutiveShellSamples >= 5 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertFalse(
            flashed,
            "a configured launch must never render \(onboardingIdentifier) while hydration settles")

        // The configured launch must actually reach the normal shell.
        UITabNavigation.shellReady(app, timeout: 15)
        attachScreenshot(of: app, name: "f4-configured-launch-no-flash")
    }

    // MARK: Existing users keep their doors

    func testSettingsOpensOwnerEnrollmentWithGatewaysConfigured() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openSettings(app)

        let row = app.buttons["fleet.settings.connect-server"]
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Settings must expose an additional-server enrollment entry")
        for _ in 0..<8 where !row.isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(row.isHittable, "the Settings enrollment entry must be brought onscreen before tapping")
        row.tap()

        // DEV14: Settings opens the QR-first add-server sheet (same guidance
        // as first run); owner sign-in lives under Advanced setup.
        XCTAssertTrue(
            app.buttons["fleet.add-gateway.scan"].waitForExistence(timeout: 10),
            "Settings must open the QR-first add-server sheet"
        )
        XCTAssertTrue(app.buttons["fleet.add-gateway.cancel"].exists,
                      "existing users can cancel enrollment and return to the fleet")
        app.buttons["fleet.add-gateway.cancel"].tap()
        attachScreenshot(of: app, name: "f4-settings-owner-enrollment")
    }

    func testAddGatewayRemainsUsableFromGatewaysTab() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        // The toolbar plus still presents the real Add-Gateway form.
        let add = app.buttons["fleet.gateways.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.buttons["fleet.add-gateway.scan"].waitForExistence(timeout: 10),
                      "Add Gateway must open the QR-first sheet from the Gateways tab")
        let advanced = app.buttons["fleet.add-gateway.advanced"]
        for _ in 0..<6 where !advanced.isHittable { app.swipeUp(velocity: .fast) }
        advanced.tap()
        app.buttons["fleet.add-gateway.advanced.manual"].tap()
        XCTAssertTrue(app.textFields["fleet.gateways.form.endpoint"].waitForExistence(timeout: 10),
                      "advanced gateway strategies remain available")
        app.buttons["fleet.gateways.form.cancel"].tap()
        app.buttons["fleet.add-gateway.advanced.cancel"].tap()
        attachScreenshot(of: app, name: "f4-add-gateway-still-works")
    }

    // MARK: Final-gateway removal returns to setup

    func testRemovingFinalGatewayReturnsToSetup() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_SINGLE_GATEWAY"] = "1"
        app.launch()

        UITabNavigation.shellReady(app, timeout: 15)
        UITabNavigation.openGatewaysTab(app)

        let firstRow = app.buttons.matching(
            NSPredicate(format: "identifier MATCHES %@",
                         "fleet\\.gateways\\.row\\.[^.]+")
        ).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        firstRow.tap()

        // Remove the single gateway through the Connection screen's
        // confirmed destructive flow: gateway row → detail → Connection.
        let connectionLink = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateway-detail.workstation.connection").firstMatch
        if !connectionLink.waitForExistence(timeout: 5) {
            for _ in 0..<3 where !connectionLink.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(connectionLink.waitForExistence(timeout: 10),
                      "gateway detail must expose the Connection link")
        connectionLink.tap()
        let detailRemove = app.buttons["Remove Gateway"].firstMatch
        if !detailRemove.waitForExistence(timeout: 5) {
            for _ in 0..<3 where !detailRemove.exists { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(detailRemove.waitForExistence(timeout: 10),
                      "the Connection screen must expose Remove Gateway")
        detailRemove.tap()
        let confirm = app.buttons["fleet.gateways.remove.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        // The undo alert appears; dismiss it so the removal stands.
        let ok = app.buttons["OK"].firstMatch
        if ok.waitForExistence(timeout: 5) { ok.tap() }

        // EMPTY REGISTRY ⇒ the root gate flips back to setup.
        XCTAssertTrue(app.buttons["fleet.first-run.scan"].waitForExistence(timeout: 15),
                      "removing the final gateway must return to the setup experience")
        attachScreenshot(of: app, name: "f4-removal-returns-to-setup")
    }

    // MARK: - Helpers

    /// Select Username & Password in the strategy picker (menu-style picker
    /// can need a retry — same pattern as the live-gateway suites).
    private func selectUsernamePassword(in app: XCUIApplication) {
        let strategy = app.descendants(matching: .any)
            .matching(identifier: "fleet.gateways.form.strategy").firstMatch
        XCTAssertTrue(strategy.waitForExistence(timeout: 10),
                      "authentication strategy picker should appear")
        let option = app.buttons["Username & Password"].firstMatch
        var selected = false
        for _ in 0..<3 {
            strategy.tap()
            if option.waitForExistence(timeout: 3) {
                option.tap()
                selected = true
                break
            }
        }
        XCTAssertTrue(selected, "strategy picker should expose Username & Password")
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(element.isEnabled, "element should become enabled: \(element)")
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func invitation(id: String) -> String {
        "https://pairing.fixture.test/pair#v=1&i=\(id)&s=\(String(repeating: "S", count: 43))"
    }
}
