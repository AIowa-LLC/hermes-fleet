import XCTest

private func openAdvancedSetup(in app: XCUIApplication) {
    // Additional servers default to the QR-first sheet; the manual form is a
    // secondary path under Advanced setup.
    let addServerTitle = app.staticTexts["fleet.add-gateway.title"]
    XCTAssertTrue(addServerTitle.waitForExistence(timeout: 10), "add-server sheet should appear after Add Gateway")
    let advanced = app.buttons["fleet.add-gateway.advanced"]
    XCTAssertTrue(advanced.waitForExistence(timeout: 10), "Advanced setup should be available")
    for _ in 0..<6 where !advanced.isHittable { app.swipeUp(velocity: .fast) }
    XCTAssertTrue(advanced.isHittable, "scroll the footer into view before tapping Advanced")
    advanced.tap()
    let manual = app.buttons["fleet.add-gateway.advanced.manual"]
    XCTAssertTrue(manual.waitForExistence(timeout: 10), "manual setup should be listed under Advanced")
    manual.tap()
    XCTAssertTrue(app.textFields["fleet.gateways.form.name"].waitForExistence(timeout: 10), "manual gateway form should appear")
}

/// S3 (B2) — cleartext-warning UI behavior in the gateway form.
///
/// The add/edit gateway sheet must warn before saving an `http://` endpoint
/// whose host is NOT a private/loopback address, and must gate Save on the
/// user explicitly confirming the cleartext send. This suite drives the
/// DEBUG build (scripted fleet, deterministic) through the U2 add-gateway
/// form:
///   - public http host  → warning appears, Save disabled until confirmed
///   - private http host (RFC1918) → no warning, Save enabled
///   - loopback http host → no warning, Save enabled
final class S3CleartextWarningUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Public http endpoint → warning + save-gating

    func testPublicHTTPEndpointShowsWarningAndGatesSave() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        XCTAssertTrue(
            UITestLaunchSupport.launch(app, ready: app.staticTexts["Workstation"].firstMatch),
            "scripted fleet should launch and render Workstation")
        UITabNavigation.openGatewaysTab(app)

        // Open the add-gateway form.
        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        openAdvancedSetup(in: app)
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        enter("Public Gateway", into: nameField, in: app)
        enter("http://gateway.example.com:9120", into: endpointField, in: app)

        // Prominent warning must appear for a public http host.
        let warning = firstMatch(in: app, identifier: "fleet.gateways.form.cleartext-warning")
        XCTAssertTrue(warning.waitForExistence(timeout: 5),
                      "cleartext warning should appear for public http endpoint")
        XCTAssertTrue(
            warning.label.contains("Fleet can't verify application-layer encryption for HTTP"),
            "warning must distinguish HTTP from a trusted encrypted tunnel: \(warning.label)")
        XCTAssertTrue(
            warning.label.contains("A trusted encrypted tunnel may protect traffic in transit"),
            "warning must not claim an assumed tunnel is present: \(warning.label)")

        // Save must be gated until the user confirms. Query the toolbar
        // BUTTON element directly — a disabled SwiftUI toolbar item surfaces
        // as an "Other" container via descendants(.any), and that container
        // reports isEnabled=true even when the button is disabled.
        let save = saveButton(in: app)
        XCTAssertTrue(save.waitForExistence(timeout: 5), "save button should exist")
        XCTAssertFalse(save.isEnabled,
                       "Save must be disabled while cleartext warning is unconfirmed")

        // Explicit confirmation unlocks Save. The endpoint field keeps focus
        // (and the software keyboard up), and the confirmation row is the
        // last content in the sheet — so the tap point lands within a couple
        // of points of the keyboard's top edge. On a runner whose keyboard
        // sits slightly higher the synthesized tap is delivered to the
        // keyboard and the Toggle silently never commits, which no amount of
        // waiting fixes (merge-group run 34699513638, shard 4). Dismiss the
        // keyboard first: measured locally the row is then ~18pt clear of it.
        // Tap the accessibility switch directly. Coordinate taps at the
        // row's right edge have repeatedly missed the control on hosted
        // runners even after the keyboard is dismissed.
        dismissKeyboard(app)

        let confirm = app.switches["fleet.gateways.form.cleartext-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation toggle should appear")
        moveAboveKeyboard(confirm, in: app)
        XCTAssertTrue(waitUntilHittable(confirm, timeout: 10),
                      "confirmation toggle should become hittable")
        // XCTest resolves the switch as the entire Form row; its default
        // center tap lands on the text label, which does not flip the switch
        // on these simulator builds. Tap the actual switch side of that row.
        confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        // The switch must actually flip to ON (value "1") — proof the user
        // explicitly confirmed the cleartext send.
        XCTAssertTrue(waitUntilValue(confirm, isOn: true, timeout: 10),
                      "confirmation toggle should read ON after tap")
        XCTAssertTrue(waitUntilEnabled(save, timeout: 10),
                      "Save should be enabled after explicit cleartext confirmation")
    }

    // MARK: - Private (RFC1918) http endpoint → no warning, Save enabled

    func testPrivateHTTPEndpointShowsNoWarning() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        XCTAssertTrue(
            UITestLaunchSupport.launch(app, ready: app.staticTexts["Workstation"].firstMatch),
            "scripted fleet should launch and render Workstation")
        UITabNavigation.openGatewaysTab(app)

        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        openAdvancedSetup(in: app)
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        enter("LAN Gateway", into: nameField, in: app)
        enter("http://10.0.0.37:9120", into: endpointField, in: app)

        // No warning for an RFC1918 private host; Save enabled immediately.
        let warning = firstMatch(in: app, identifier: "fleet.gateways.form.cleartext-warning")
        XCTAssertFalse(warning.waitForExistence(timeout: 2),
                       "no cleartext warning for a private RFC1918 host")

        let save = saveButton(in: app)
        XCTAssertTrue(waitUntilEnabled(save, timeout: 5),
                      "Save should be enabled for a private endpoint without confirmation")
    }

    // MARK: - Loopback http endpoint → no warning

    func testLoopbackHTTPEndpointShowsNoWarning() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        XCTAssertTrue(
            UITestLaunchSupport.launch(app, ready: app.staticTexts["Workstation"].firstMatch),
            "scripted fleet should launch and render Workstation")
        UITabNavigation.openGatewaysTab(app)

        tap(firstMatch(in: app, identifier: "fleet.gateways.add"))
        openAdvancedSetup(in: app)
        let nameField = app.textFields["fleet.gateways.form.name"]
        let endpointField = app.textFields["fleet.gateways.form.endpoint"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "name field should appear")
        enter("Local Gateway", into: nameField, in: app)
        enter("http://127.0.0.1:8642", into: endpointField, in: app)

        let warning = firstMatch(in: app, identifier: "fleet.gateways.form.cleartext-warning")
        XCTAssertFalse(warning.waitForExistence(timeout: 2),
                       "no cleartext warning for a loopback host")

        let save = saveButton(in: app)
        XCTAssertTrue(waitUntilEnabled(save, timeout: 5),
                      "Save should be enabled for a loopback endpoint without confirmation")
    }

    // MARK: - Helpers

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let any = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if any.exists { return any }
        let btn = app.buttons[identifier].firstMatch
        if btn.exists { return btn }
        let cell = app.cells[identifier].firstMatch
        if cell.exists { return cell }
        return any
    }

    /// The Save toolbar button, queried as a BUTTON. A disabled SwiftUI
    /// toolbar item surfaces as an "Other" container under descendants(.any)
    /// whose isEnabled is always true — so enabled-state assertions must
    /// query the button type directly.
    private func saveButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["fleet.gateways.form.save"].firstMatch
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "element \(element) should appear")
        element.tap()
    }

    /// A focused field can accept input without exposing a software keyboard.
    /// Keep one focus fallback, then verify the actual value used by the
    /// warning and Save gate. A missed focus or failed input still fails.
    private func enter(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        field.tap()
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 2) {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "keyboard should be visible for text entry")
        var entered = ""
        for chunk in textChunks(text, maximumLength: 4) {
            field.typeText(chunk)
            entered.append(contentsOf: chunk)
            completeKeyboardEntry(entered, into: field)
            XCTAssertEqual(field.value as? String, entered,
                           "gateway field should retain each typed segment")
        }
        XCTAssertEqual(field.value as? String, text, "gateway field should retain the typed input")
    }

    private func textChunks(_ text: String, maximumLength: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count == maximumLength {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Short text batches avoid losing trailing keyboard events while the
    /// SwiftUI field refreshes. On the iOS 26 runner, typeText can return with
    /// a stable prefix (for example, "Local Gatew" from "Local Gateway").
    /// Once that prefix is unchanged across accessibility snapshots, enter
    /// only the missing suffix. The caller checks each segment and the full
    /// expected string.
    private func completeKeyboardEntry(_ expected: String, into field: XCUIElement) {
        let deadline = Date().addingTimeInterval(6)
        var lastValue: String?
        var stableSince = Date()
        var suffixRetries = 0

        while Date() < deadline {
            let current = field.value as? String ?? ""
            if current == expected { return }

            if current != lastValue {
                lastValue = current
                stableSince = Date()
            } else if suffixRetries < 2,
                      expected.hasPrefix(current),
                      current.count < expected.count,
                      Date().timeIntervalSince(stableSince) >= 0.5 {
                field.typeText(String(expected.dropFirst(current.count)))
                suffixRetries += 1
                stableSince = Date()
            }

            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
    }

    @discardableResult
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.isEnabled
    }

    @discardableResult
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isHittable && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.isHittable
    }

    /// Poll a switch until its `value` reads "1" (ON) — proves the toggle
    /// actually committed (a missed tap leaves value "0").
    @discardableResult
    private func waitUntilValue(_ element: XCUIElement, isOn: Bool, timeout: TimeInterval) -> Bool {
        let wanted = isOn ? "1" : "0"
        let deadline = Date().addingTimeInterval(timeout)
        while (element.value as? String) != wanted && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return (element.value as? String) == wanted
    }

    /// Resign the endpoint field's focus and wait — bounded, on the real
    /// condition — until the software keyboard is off-screen. The keyboard
    /// covers the bottom of the sheet, which is where the confirmation row
    /// lives, so this must happen before the switch is tapped. A single-line
    /// SwiftUI TextField submits and resigns on Return; that is the only
    /// dismissal affordance here (iPhone keyboards have no dismiss key and
    /// this sheet opts into no scroll-dismisses-keyboard behaviour). If the
    /// keyboard is somehow still up afterwards, scroll the form so the row
    /// clears it rather than tapping into an ambiguous band.
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }
        let endpoint = app.textFields["fleet.gateways.form.endpoint"]
        if endpoint.exists {
            endpoint.typeText("\n")
        }
        let deadline = Date().addingTimeInterval(10)
        while app.keyboards.count > 0 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    /// The keyboard can remain visible after Return on some simulator builds.
    /// XCUITest's synthesized switch tap then lands at the row's center, which
    /// can be underneath the keyboard even though `isHittable` is true. Scroll
    /// the form until the whole control is above the keyboard and fail with an
    /// explicit geometry assertion if it cannot be exposed.
    private func moveAboveKeyboard(_ element: XCUIElement, in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        for _ in 0..<5 {
            if element.frame.maxY + 8 < keyboard.frame.minY { break }
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(element.frame.maxY + 8 < keyboard.frame.minY,
                      "confirmation control should be fully above the software keyboard before tapping; control=\(element.frame), keyboard=\(keyboard.frame)")
    }

}
