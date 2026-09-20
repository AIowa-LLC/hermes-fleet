import XCTest

/// Dogfood r8 — deterministic thinking-level (reasoning slider) suite
/// (scripted fleet): the chip renders in the conversation header chip zone
/// and opens the overlay; dragging the capsule applies a stop through the
/// session-scoped config.set seam (recorded by the scripted box); the AX
/// adjustable action steps a level; a failed apply surfaces the inline
/// error (never silent); dismissal paths work.
final class ReasoningSliderUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "missing element: \(identifier)")
        return element
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.isHittable || element.isEnabled, "element not hittable/enabled")
        element.tap()
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openConversation(_ app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        tap(firstMatch(in: app, identifier: "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        tap(firstMatch(in: app, identifier: "fleet.roster.row.workstation#default"))
        XCTAssertTrue(
            firstMatch(in: app, identifier: "fleet.bot-detail.header").waitForExistence(timeout: 10),
            "Bot detail should render before drilling into the conversation"
        )
        tap(firstMatch(in: app, identifier: "fleet.bot-detail.sessions.row.workstation.default.s1"))
        XCTAssertTrue(
            app.textFields["fleet.conversation.composer"].waitForExistence(timeout: 10),
            "conversation canvas should open with a composer"
        )
    }

    /// Chip payload assert: the level word rides AX `.value` (the label is
    /// the fixed "Thinking level"), per the chip-assert house rule.
    private func chipWord(_ chip: XCUIElement) -> String {
        (chip.value as? String) ?? ""
    }

    func testChipRendersWithDefaultLevelAndOpensOverlay() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openConversation(app)

        // The chip renders in the header chip zone with the gateway default.
        let chip = firstMatch(in: app, identifier: "fleet.conversation.reasoning.chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "reasoning gauge should render in the composer right cluster")
        XCTAssertTrue(chipWord(chip).contains("Medium"),
                      "chip reads the scripted default level: \(chipWord(chip))")

        // r8.1: the gauge sits in the composer RIGHT cluster — after the
        // field, before the mic and send (ChatGPT order). Asserted BEFORE
        // opening the overlay (the scrim must not be in the way). HStack
        // frames are deterministic left-to-right.
        let field = app.textFields["fleet.conversation.composer"]
        let mic = firstMatch(in: app, identifier: "fleet.conversation.mic")
        let send = firstMatch(in: app, identifier: "fleet.conversation.send")
        XCTAssertTrue(chip.frame.minX > field.frame.maxX,
                      "gauge must sit right of the field: \(chip.frame) vs \(field.frame)")
        XCTAssertTrue(mic.exists && mic.frame.minX > chip.frame.maxX,
                      "mic must sit right of the gauge (gauge, mic, send)")
        XCTAssertTrue(send.frame.minX > mic.frame.maxX,
                      "send must be the last element")

        // Tapping opens the overlay (not a sheet): value + slider + scrim.
        chip.tap()
        let slider = firstMatch(in: app, identifier: "fleet.conversation.reasoning.slider")
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.conversation.reasoning.value").exists,
                      "value readout should render")

        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.conversation.reasoning.slider").exists,
                      "slider capsule should render")
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.conversation.reasoning.value").exists,
                      "value readout should render")
        XCTAssertTrue(app.staticTexts["Medium"].exists, "readout shows the current word")
        attachScreenshot(of: app, name: "r8-reasoning-overlay-default")
    }

    func testDragAppliesStopAndUpdatesChip() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openConversation(app)

        let chip = firstMatch(in: app, identifier: "fleet.conversation.reasoning.chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        let slider = firstMatch(in: app, identifier: "fleet.conversation.reasoning.slider")
        XCTAssertTrue(slider.waitForExistence(timeout: 10))

        // Drag the capsule toward the last stop. The AX-adjustable element
        // exposes the slider; a coordinate drag on its frame drives the
        // DragGesture (minimumDistance 0 — tap-to-jump and drag share one
        // seam, so a precise landing is not required).
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)

        // The readout flips to the snapped stop's word (a staticText whose
        // label is exactly the word) — far-right drag = Ultra, the true
        // top of the 8-stop ladder (r8.4).
        XCTAssertTrue(app.staticTexts["Ultra"].waitForExistence(timeout: 10),
                      "readout should show Ultra after the drag")

        // Dismiss via the scrim edge (the panel covers the center).
        let scrim = firstMatch(in: app, identifier: "fleet.conversation.reasoning.scrim")
        scrim.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.15)).tap()

        // The chip carries the applied stop (config.get readback through
        // the scripted box: the served level flipped with the set call).
        let chipAfter = firstMatch(in: app, identifier: "fleet.conversation.reasoning.chip")
        XCTAssertTrue(chipWord(chipAfter).contains("Ultra"),
                      "chip should show Ultra after apply + dismiss: \(chipWord(chipAfter))")
        attachScreenshot(of: app, name: "r8-reasoning-chip-ultra")
    }

    func testAdjustableActionStepsLevel() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openConversation(app)

        let chip = firstMatch(in: app, identifier: "fleet.conversation.reasoning.chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        let slider = firstMatch(in: app, identifier: "fleet.conversation.reasoning.slider")
        XCTAssertTrue(slider.waitForExistence(timeout: 10))

        // The slider is one AX adjustable element. The AX-adjust API
        // (adjust(toNormalizedSliderPosition:)) needs a real .slider
        // element; the custom capsule is an adjustable Other, so the AX
        // path is driven with a SHORT controlled coordinate drag up the
        // ladder (the ADR-0011 exposed-zone pattern) — several stops up
        // from Medium with 8-stop spacing (r8.4).
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertTrue(app.staticTexts["Max"].waitForExistence(timeout: 10),
                      "the drag should reach Max")
        attachScreenshot(of: app, name: "r8-reasoning-ax-adjust")
    }

    func testScrimTapDismissesWithoutChangeWhenNoDrag() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openConversation(app)

        let chip = firstMatch(in: app, identifier: "fleet.conversation.reasoning.chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        XCTAssertTrue(chipWord(chip).contains("Medium"), "precondition: scripted default Medium, got \(chipWord(chip))")
        chip.tap()
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.conversation.reasoning.slider")
            .waitForExistence(timeout: 10))

        // Dismiss WITHOUT touching the slider.
        firstMatch(in: app, identifier: "fleet.conversation.reasoning.scrim")
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()

        // The slider vanishes (dismissal landed).
        let gone = NSPredicate(format: "exists == 0")
        let sliderGone = XCTNSPredicateExpectation(
            predicate: gone,
            object: app.descendants(matching: .any)
                .matching(identifier: "fleet.conversation.reasoning.slider").firstMatch)
        wait(for: [sliderGone], timeout: 10)

        // The chip still reads Medium — dismissal without a drag never writes.
        let chipFinal = firstMatch(in: app, identifier: "fleet.conversation.reasoning.chip")
        XCTAssertTrue(chipWord(chipFinal).contains("Medium"),
                      "dismiss-without-drag must not change the level: \(chipWord(chipFinal))")
    }
}
