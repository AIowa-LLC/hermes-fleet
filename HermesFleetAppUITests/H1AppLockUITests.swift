import XCTest

/// H1 (R4) — biometric app lock: cold-launch gate, failed-biometric passcode
/// fallback, and toggle persistence across restart.
///
/// Drives the DEBUG build (scripted fleet, deterministic) with the H1
/// launch-env seam wired in `FleetServiceGraph.makeLockController`:
///   - `HERMES_FLEET_APP_LOCK=enabled` + `HERMES_FLEET_LOCK_AUTH=fail`
///     → cold launch is LOCKED (roster content does NOT render), and the
///     failed biometric automatically shows the passcode prompt. Tapping
///     "Use Passcode" (scripted passcode success) unlocks → roster renders.
///   - `HERMES_FLEET_APP_LOCK=enabled` + `HERMES_FLEET_LOCK_AUTH=success`
///     → the scripted biometric success unlocks to the roster.
///   - `HERMES_FLEET_APP_LOCK=follow` + `HERMES_FLEET_LOCK_AUTH=success`
///     → default-ON toggle gates at cold launch, auto-unlock reaches the
///     Settings toggle; flipping it OFF survives the restart (acceptance).
///
/// Queries target real buttons/static texts (not the ZStack container
/// identifier, which SwiftUI does not surface as a queryable element).
final class H1AppLockUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Cold launch requires auth before roster renders; failed
    // biometric → automatic passcode prompt

    func testColdLaunchLockedBeforeRosterAndFailedBiometricPasscode() throws {
        let app = XCUIApplication()
        // Force the gate ON and make biometrics FAIL: the app must show ONLY
        // the lock screen at cold launch — no roster content behind it.
        // Reset the persisted toggle so the default-ON gate is deterministic.
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "enabled"
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "fail"
        app.launchEnvironment["HERMES_FLEET_LOCK_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()

        // The failed biometric must automatically show the passcode prompt
        // (the ONLY interactive element on the lock screen).
        let passcodeButton = app.buttons["fleet.app-lock.passcode.unlock"]
        XCTAssertTrue(passcodeButton.waitForExistence(timeout: 15),
                      "cold launch must show the lock screen with the passcode fallback (acceptance)")
        // Evidence: capture the LOCKED frame (minimal Signal-red overlay,
        // roster NOT rendered) before unlocking.
        attachScreenshot(of: app, name: "h1-cold-launch-LOCKED")

        // Roster/conversation content must NOT render behind the lock.
        XCTAssertFalse(app.staticTexts["Workstation"].exists,
                       "roster content must not render while the app is locked")

        // Use Passcode → scripted passcode success → content renders.
        //
        // De-flake (t_6c35ed56 forensics, QA run 469 xcresult + screen
        // recording): the cold-launch biometric→passcode branch swap has a
        // window where the AX hierarchy ALREADY reports the passcode button
        // but the view is not yet painted/hit-testable (the recording shows
        // a fully blank screen below the status bar at the tap instant —
        // the tap's coordinates were exact, button center). A tap synthesized
        // in that window is swallowed and the app stays on the passcode
        // screen forever, so NO roster timeout would ever fix it. Wait for
        // hittability first, then VERIFY the unlock actually happened and
        // re-tap (bounded) while the lock screen is still presenting.
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"),
                                   evaluatedWith: passcodeButton)
        wait(for: [hittable], timeout: 10)

        passcodeButton.tap()
        // Total budget 20s: covers BOTH the re-tap path (swallowed first tap,
        // button still exists) and a slow post-unlock roster render (button
        // already gone — keep waiting, never re-tap a vanished lock screen).
        let retryDeadline = Date().addingTimeInterval(20)
        var rosterVisible = app.staticTexts["Workstation"].waitForExistence(timeout: 5)
        while !rosterVisible, Date() < retryDeadline {
            if passcodeButton.exists {
                // First tap raced the transition — the passcode view is still
                // up, so the unlock never ran. Tap again now that the view
                // has settled (bounded retries keep this deterministic).
                passcodeButton.tap()
            }
            rosterVisible = app.staticTexts["Workstation"].waitForExistence(timeout: 5)
        }
        XCTAssertTrue(rosterVisible,
                      "roster should render after a successful passcode unlock")
        attachScreenshot(of: app, name: "h1-cold-launch-unlocked")
    }

    // MARK: - Unlock with biometric success

    func testBiometricSuccessUnlocksToRoster() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "enabled"
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launch()

        // Scripted biometric success → the gate releases and the roster
        // renders (the DEBUG fleet's first gateway is Workstation).
        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 15),
                      "scripted biometric success should unlock to the roster")
        attachScreenshot(of: app, name: "h1-biometric-success-unlocked")
    }

    // MARK: - Toggle defaults ON + persists across restart

    func testLockToggleDefaultsOnAndPersistsAcrossRestart() throws {
        // First launch: follow-setting mode, default-ON toggle → locked at
        // cold launch, then the scripted biometric success unlocks. Reset the
        // persisted toggle so the default-ON assertion is deterministic.
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "follow"
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_LOCK_RESET"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 15),
                      "roster reachable after default-ON lock + biometric unlock")

        // Open Settings (U3: a root tab, no longer a Gateways sheet) → the
        // App Lock toggle is ON by default (acceptance).
        UITabNavigation.openSettings(app)

        let toggle = app.switches["fleet.settings.app-lock.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "App Lock toggle should appear")
        XCTAssertEqual(toggle.value as? String, "1",
                       "App Lock toggle must default to ON (acceptance)")

        // Flip the toggle OFF — tap the switch KNOB (right edge), the same
        // pitfall S3 documented: a center tap can land on the row label and
        // miss the SwiftUI Toggle control.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(waitUntilValue(toggle, isOn: false, timeout: 5),
                      "App Lock toggle should read OFF after tap")
        // U3: Settings is a tab, not a sheet — no Done dismissal; leaving the
        // tab persists the toggle immediately (UserDefaults write-through).

        // Restart the app. The reset flag must NOT be applied on relaunch —
        // we want the PERSISTED OFF toggle to drive the cold start.
        app.launchEnvironment["HERMES_FLEET_LOCK_RESET"] = nil
        app.terminate()
        app.launch()

        XCTAssertTrue(app.staticTexts["Workstation"].waitForExistence(timeout: 15),
                      "roster should render immediately when the toggle is OFF")
        XCTAssertFalse(app.buttons["fleet.app-lock.passcode.unlock"].exists,
                       "no lock screen when the persisted toggle is OFF")

        // Prove the toggle really persisted: reopen Settings and read OFF.
        UITabNavigation.openSettings(app)
        let toggleAgain = app.switches["fleet.settings.app-lock.toggle"]
        XCTAssertTrue(toggleAgain.waitForExistence(timeout: 10))
        XCTAssertEqual(toggleAgain.value as? String, "0",
                       "App Lock toggle must persist OFF across restart (acceptance)")
        attachScreenshot(of: app, name: "h1-toggle-off-persisted")
    }

    // MARK: - Helpers

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let any = app.descendants(matching: .any)[identifier]
        if any.exists { return any }
        if app.buttons[identifier].exists { return app.buttons[identifier] }
        return any
    }

    @discardableResult
    private func waitUntilValue(_ element: XCUIElement, isOn: Bool, timeout: TimeInterval) -> Bool {
        let wanted = isOn ? "1" : "0"
        let deadline = Date().addingTimeInterval(timeout)
        while (element.value as? String) != wanted && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return (element.value as? String) == wanted
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
