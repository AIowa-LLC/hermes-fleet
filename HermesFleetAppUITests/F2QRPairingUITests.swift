import XCTest

/// F2 — QR-code gateway pairing: one scan fills the Add-Gateway form.
///
/// Deterministic on the simulator (and CI): VisionKit's live scanner reports
/// unsupported on simulators, so the scanner sheet shows its fallback body,
/// which — in DEBUG, opted in via launch environment — exposes the SAME
/// decode + apply entry point the camera uses ("Simulate Scanned Code").
/// The test therefore drives production logic end to end:
///
///   Add Gateway → Scan Pairing Code → (simulated) scan → form filled → Save
///   → gateway registered.
final class F2QRPairingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// C1 hardening: the scanner sheet must render its camera-denied
    /// recovery state — real copy + Open Settings — and never a dead
    /// spinner or a camera surface. Driven via the DEBUG-only
    /// `HERMES_FLEET_PAIRING_CAMERA_DENIED` seam (the simulator camera is
    /// unsupported, so the real denied path is unreachable there).
    func testScannerDeniedStateShowsRecoveryCopyAndSettingsLink() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_PAIRING_CAMERA_DENIED"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        let add = app.buttons["fleet.gateways.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()

        let nameField = app.textFields["fleet.gateways.form.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))

        let scan = app.buttons["fleet.gateways.form.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()

        let denied = app.staticTexts["fleet.gateways.scan.denied"]
        XCTAssertTrue(denied.waitForExistence(timeout: 10),
                      "denied state must surface real copy, not a dead spinner")
        let settings = app.buttons["fleet.gateways.scan.denied.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5),
                      "denied state must offer the Settings deep link")
        // The manual path stays reachable: cancel back to the form.
        let cancel = app.buttons["fleet.gateways.scan.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(nameField.waitForExistence(timeout: 10),
                      "cancel must return to the manual-entry form")
    }

    /// C1 IA re-order: the scanner must be demoted BELOW the manual entry
    /// fields with a clear "requires pairing support" label — manual entry
    /// is the tier-1 primary path.
    func testScannerEntryIsDemotedBelowManualEntryWithSupportLabel() throws {
        let app = XCUIApplication()
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        let add = app.buttons["fleet.gateways.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()

        let nameField = app.textFields["fleet.gateways.form.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        let scan = app.buttons["fleet.gateways.form.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        // The scan button must come AFTER the manual endpoint field in the
        // accessible element order — manual entry is tier 1.
        XCTAssertTrue(nameField.frame.maxY < scan.frame.minY,
                      "scanner entry must render below the manual entry fields")
        let supportLabel = app.staticTexts["fleet.gateways.form.scan.support-note"]
        XCTAssertTrue(supportLabel.waitForExistence(timeout: 5),
                      "scanner section must carry the pairing-support caveat")
        attachScreenshotF2(of: app, name: "c1-scanner-demoted")
    }

    /// The raw QR text the gateway side would render (F2 v1 payload).
    private var simulatedScan: String {
        "{\"password\":\"NOT-A-CREDENTIAL\",\"url\":\"http://127.0.0.1:8642\",\"username\":\"fixture-user\",\"v\":1}"
    }

    func testScanFillsFormAndSaveRegistersGateway() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_PAIRING_SIMULATED_SCAN"] = simulatedScan
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        // Open the Add-Gateway form (DEBUG scripted fleet renders the roster).
        let add = app.buttons["fleet.gateways.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "Add Gateway toolbar button should appear")
        add.tap()

        let nameField = app.textFields["fleet.gateways.form.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "Add-Gateway form should appear")

        // Open the pairing scanner.
        let scan = app.buttons["fleet.gateways.form.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5), "Scan Pairing Code button should be in the form")
        scan.tap()

        // On the simulator the live scanner is unavailable → fallback body
        // with the DEBUG simulated-scan hook (same decode+apply path).
        let simulate = app.buttons["fleet.gateways.scan.simulate"]
        XCTAssertTrue(simulate.waitForExistence(timeout: 10),
                      "simulator fallback should expose the simulated scan (DEBUG + launch env)")
        simulate.tap()

        // Back on the form: every field filled from ONE scan.
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "scanner should dismiss back to the form")
        XCTAssertEqual(nameField.value as? String, "127.0.0.1",
                       "display name derives from the endpoint host")
        let endpoint = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertEqual(endpoint.value as? String, "http://127.0.0.1:8642")
        let username = app.textFields["fleet.gateways.form.username"]
        XCTAssertEqual(username.value as? String, "fixture-user")
        // Password is a secure field — assert presence, never the value.
        XCTAssertTrue(app.secureTextFields["fleet.gateways.form.password"].exists,
                      "password field filled (value never asserted)")

        // Save: the gateway lands in the registry.
        let save = app.buttons["fleet.gateways.form.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "scanned draft must satisfy form validity")
        save.tap()

        XCTAssertTrue(app.staticTexts["127.0.0.1"].waitForExistence(timeout: 15),
                      "saved gateway row should appear in the list")
        attachScreenshotF2(of: app, name: "f2-paired-gateway-row")
    }

    func testScanRejectsNonPairingCodeWithoutClobberingForm() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_PAIRING_SIMULATED_SCAN"] = "{\"hello\":\"world\"}"
        app.launch()
        UITabNavigation.openGatewaysTab(app)

        let add = app.buttons["fleet.gateways.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()

        let nameField = app.textFields["fleet.gateways.form.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText("Typed Name")

        let scan = app.buttons["fleet.gateways.form.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()

        let simulate = app.buttons["fleet.gateways.scan.simulate"]
        XCTAssertTrue(simulate.waitForExistence(timeout: 10))
        simulate.tap()

        // The scanner stays up with a non-secret error; typed state intact.
        XCTAssertTrue(app.staticTexts["fleet.gateways.scan.error"].waitForExistence(timeout: 5)
                      || app.otherElements["fleet.gateways.scan.error"].waitForExistence(timeout: 5)
                      || app.images["fleet.gateways.scan.error"].waitForExistence(timeout: 5),
                      "a rejected scan should surface a non-secret error")
        let cancel = app.buttons["fleet.gateways.scan.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()

        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        XCTAssertEqual(nameField.value as? String, "Typed Name",
                       "a rejected scan must never clobber typed fields")
    }
}

// MARK: - Add to Fleet pairing links (cold launch, running app, outcomes)

/// A pairing link delivered to the app and driven through the real SwiftUI screens against the
/// scripted simulator pairing service. Synthetic evidence: the real wire protocol is verified
/// against genuine TLS servers in the FleetNetworking tests, and the real Universal Link path
/// needs a verified domain (see docs/fleet-device-pairing.md).
///
/// Delivery paths covered here: (1) cold launch with the link in the launch environment, and
/// (2) an open-URL. NOTE: `XCUIApplication.open(_:)` RELAUNCHES the app process (verified by
/// process id), so path (2) is also a fresh launch from a URL, not delivery into a running
/// instance. Delivery into an already-running instance is covered by the hosted
/// `PairingFlowTests` (links arriving while a flow is active, duplicates, replacement) and by
/// the simulator-driven run recorded in the build 6 receipt; the in-app paste entry below is
/// the one path that stays in one process across several links.
extension F2QRPairingUITests {
    private var pairedName: String { "Scripted Pairing Gateway" }

    private func pairingLink(_ prefix: String = "ok") -> String {
        let id = prefix + String(repeating: "AbCdEfGh", count: 3)
        return "https://pairing.example.test/pair#v=1&i=\(id)&s=0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"
    }

    private func openURL(for link: String) -> URL {
        var components = URLComponents()
        components.scheme = "hermes-fleet"
        components.host = "pairing-test"
        components.queryItems = [URLQueryItem(name: "link", value: link)]
        return components.url!
    }

    private func launchRunningApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.shellReady(app)
        return app
    }

    private func gatewayIsListed(_ app: XCUIApplication) -> Bool {
        _ = UITabNavigation.openGatewaysTab(app)
        return app.staticTexts[pairedName].waitForExistence(timeout: 4)
    }

    /// Cold launch: the link arrives before the app is ready. The confirmation screen waits
    /// for hydration, shows who and what, and nothing is added until the person confirms.
    func testPairingLinkAtColdLaunchShowsConfirmationAndAddsOnlyAfterConfirm() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_PAIRING_TEST_LINK"] = pairingLink()
        app.launch()

        let name = app.staticTexts["fleet.pairing.confirm.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 30), "a link opened at launch must reach the confirmation screen")
        XCTAssertEqual(name.label, pairedName)
        XCTAssertTrue(app.staticTexts["fleet.pairing.confirm.address"].label.contains("pairing.example.test"),
                      "the exact address is shown")
        XCTAssertTrue(app.staticTexts["fleet.pairing.confirm.access"].exists || app.otherElements["fleet.pairing.confirm.access"].exists,
                      "the requested access is shown")
        attachScreenshotF2(of: app, name: "pairing-cold-launch-confirmation")

        app.buttons["fleet.pairing.confirm"].tap()
        XCTAssertTrue(app.staticTexts["fleet.pairing.completed"].waitForExistence(timeout: 15),
                      "the person is told the gateway was added")
        app.buttons["fleet.pairing.done"].tap()
        XCTAssertTrue(gatewayIsListed(app), "the confirmed gateway is in the fleet")
    }

    /// Open-URL delivery (the app is relaunched by the URL). Cancelling adds nothing, and the
    /// same link still works afterwards because nothing was consumed.
    func testPairingLinkOpenedByURLCanBeCancelledWithoutAddingAnything() throws {
        let app = launchRunningApp()
        _ = UITabNavigation.openGatewaysTab(app)
        XCTAssertFalse(app.staticTexts[pairedName].exists)

        app.open(openURL(for: pairingLink()))
        let name = app.staticTexts["fleet.pairing.confirm.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 20), "a link opened by URL shows the confirmation")
        XCTAssertEqual(name.label, pairedName)
        XCTAssertFalse(app.staticTexts[pairedName].isHittable && app.staticTexts["Added to Fleet"].exists)

        app.buttons["fleet.pairing.cancel"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.otherElements["fleet.pairing.sheet"], timeout: 10)
                      || waitForDisappearance(of: name, timeout: 10))
        XCTAssertFalse(gatewayIsListed(app), "cancelling must add nothing")

        // The same link still works afterwards: nothing was consumed.
        app.open(openURL(for: pairingLink()))
        XCTAssertTrue(app.staticTexts["fleet.pairing.confirm.name"].waitForExistence(timeout: 20))
    }

    func testExpiredLinkSaysSoAndOffersNoRetry() throws {
        let app = launchRunningApp()
        app.open(openURL(for: pairingLink("expired")))
        let title = app.staticTexts["fleet.pairing.failure.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "This link has expired")
        XCTAssertFalse(app.buttons["fleet.pairing.retry"].exists, "an expired link cannot be retried")
        attachScreenshotF2(of: app, name: "pairing-expired")
    }

    func testUsedAndCancelledAndUnknownLinksEachGetTheirOwnMessage() throws {
        let app = launchRunningApp()
        let cases = [("used", "This link was already used"), ("cancelled", "This link was cancelled"),
                     ("invalid", "This link isn't valid")]
        for (prefix, expected) in cases {
            app.open(openURL(for: pairingLink(prefix)))
            let title = app.staticTexts["fleet.pairing.failure.title"]
            XCTAssertTrue(title.waitForExistence(timeout: 20), prefix)
            XCTAssertEqual(title.label, expected, prefix)
            app.buttons["fleet.pairing.failure.close"].tap()
            XCTAssertTrue(waitForDisappearance(of: title, timeout: 10), prefix)
        }
    }

    /// Offline: the message explains that a link does not create a network path, and Try Again
    /// continues with the very same link once the gateway is reachable.
    func testOfflineLinkExplainsReachabilityAndRetriesTheSameLink() throws {
        let app = launchRunningApp()
        app.open(openURL(for: pairingLink("offline")))
        let message = app.staticTexts["fleet.pairing.failure.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 20))
        XCTAssertTrue(message.label.contains("doesn't create a network path"), message.label)
        let retry = app.buttons["fleet.pairing.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(app.staticTexts["fleet.pairing.confirm.name"].waitForExistence(timeout: 20),
                      "retrying the same link reaches the confirmation")
    }

    /// Both links go through the in-app paste entry, so they share one process: the second link
    /// is for the gateway the first one added, which must be reported without being used.
    func testAGatewayAlreadyInFleetIsReportedAndTheSecondLinkIsNotUsed() throws {
        let app = launchRunningApp()

        func pasteLink(_ link: String) {
            // The Gateways screen may already be showing (it stays up after a pairing).
            if !app.buttons["fleet.gateways.add"].exists { _ = UITabNavigation.openGatewaysTab(app) }
            let add = app.buttons["fleet.gateways.add"]
            XCTAssertTrue(add.waitForExistence(timeout: 15))
            add.tap()
            let entry = app.buttons["fleet.gateways.form.pairing-link"]
            XCTAssertTrue(entry.waitForExistence(timeout: 10))
            entry.tap()
            let field = app.textViews["fleet.pairing.field"].waitForExistence(timeout: 10)
                ? app.textViews["fleet.pairing.field"] : app.textFields["fleet.pairing.field"]
            field.tap()
            field.typeText(link)
            app.buttons["fleet.pairing.continue"].tap()
        }

        pasteLink(pairingLink("ok"))
        XCTAssertTrue(app.buttons["fleet.pairing.confirm"].waitForExistence(timeout: 20))
        app.buttons["fleet.pairing.confirm"].tap()
        XCTAssertTrue(app.buttons["fleet.pairing.done"].waitForExistence(timeout: 15))
        app.buttons["fleet.pairing.done"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.textFields["fleet.gateways.form.name"], timeout: 10),
                      "after a successful pairing the Add Gateway form closes too")
        attachScreenshotF2(of: app, name: "pairing-after-first-link")
        XCTAssertTrue(app.staticTexts[pairedName].waitForExistence(timeout: 10), "the first link added the gateway")

        pasteLink(pairingLink("ok2"))
        XCTAssertTrue(app.staticTexts["fleet.pairing.already-added"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["fleet.pairing.confirm"].exists, "a duplicate is never offered for confirmation")
        attachScreenshotF2(of: app, name: "pairing-duplicate-link-result")
    }

    /// Add Gateway keeps manual entry and the QR scanner, and adds the pairing-link option.
    func testAddGatewayOffersPairingLinkAlongsideManualAndQR() throws {
        let app = launchRunningApp()
        _ = UITabNavigation.openGatewaysTab(app)
        let add = app.buttons["fleet.gateways.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()

        XCTAssertTrue(app.textFields["fleet.gateways.form.name"].waitForExistence(timeout: 10), "manual entry stays")
        XCTAssertTrue(app.buttons["fleet.gateways.form.scan"].waitForExistence(timeout: 5), "QR scanning stays")
        let link = app.buttons["fleet.gateways.form.pairing-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 5), "Add with Pairing Link is offered")
        link.tap()

        // A multi-line field surfaces as a text view.
        let field = app.textViews["fleet.pairing.field"].exists ? app.textViews["fleet.pairing.field"]
            : app.textFields["fleet.pairing.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)
                      || app.textViews["fleet.pairing.field"].waitForExistence(timeout: 5))
        field.tap()
        field.typeText("this is not a link")
        app.buttons["fleet.pairing.continue"].tap()
        let title = app.staticTexts["fleet.pairing.failure.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "That isn't a pairing link")
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }
}

/// Bounded screenshot evidence helper (F2-local; mirrors the P0-2 pattern).
extension XCTestCase {
    func attachScreenshotF2(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
