import XCTest

/// Card E — the image-generation animation in the real shell, against the
/// deterministic scripted fleet.
///
/// The scripted turn (`HERMES_FLEET_IMAGE_DEMO=1`) runs a verified
/// `image_generate` call; `HERMES_FLEET_IMAGE_DEMO_HOLD_MS` keeps it in
/// flight so the branded indeterminate animation is observable,
/// `HERMES_FLEET_IMAGE_DEMO_FAIL=1` completes it with an explicit failure,
/// and `HERMES_FLEET_IMAGE_DEMO_ORDER=streaming` uses the second real wire
/// shape (turn streams first, tool runs mid-turn).
///
/// Proves:
///   1. the animation starts from the verified generation frame, renders
///      inside the CITING tool row, and hands off to the delivered image;
///   2. a failed generation stops the animation and delivers no image;
///   3. a user interrupt stops the animation (the work it claims is over).
///
/// Motion itself is not asserted here: under XCUITest the wing renders in the
/// still variant by default (continuous motion fights the idle wait; the
/// variant decision is unit-tested in `ImageGenerationActivityTests` and the
/// call-site routing in `ImageGenerationAnimationWiringGuardTests`).
final class ImageGenerationAnimationUITests: XCTestCase {

    /// Contract identifier stems (the citing row id is appended by the app).
    private static let animationPrefix = "fleet.conversation.imagegen.activity."
    private static let animationIdentifier = "fleet.conversation.imagegen.activity.row-2"
    private static let deliveredImageIdentifier = "fleet.artifact.image.row-2.scripted_generation.png"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(imageDemo: Bool, holdMs: Int? = nil, fail: Bool = false, order: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        if imageDemo {
            app.launchEnvironment["HERMES_FLEET_IMAGE_DEMO"] = "1"
        }
        if let holdMs {
            app.launchEnvironment["HERMES_FLEET_IMAGE_DEMO_HOLD_MS"] = String(holdMs)
        }
        if fail {
            app.launchEnvironment["HERMES_FLEET_IMAGE_DEMO_FAIL"] = "1"
        }
        if let order {
            app.launchEnvironment["HERMES_FLEET_IMAGE_DEMO_ORDER"] = order
        }
        app.launch()
        UITabNavigation.shellReady(app, timeout: 20)
        return app
    }

    private func transcript(_ app: XCUIApplication) -> XCUIElement {
        app.scrollViews["fleet.conversation.transcript"]
    }

    private func animation(_ app: XCUIApplication) -> XCUIElement {
        transcript(app).staticTexts
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", Self.animationPrefix))
            .firstMatch
    }

    private func animation(in row: XCUIElement) -> XCUIElement {
        row.staticTexts[Self.animationIdentifier].firstMatch
    }

    private func deliveredImage(_ app: XCUIApplication) -> XCUIElement {
        transcript(app).buttons[Self.deliveredImageIdentifier].firstMatch
    }

    private func sendPrompt(_ app: XCUIApplication, text: String) {
        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText(text)
        let send = app.descendants(matching: .any)["fleet.conversation.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 15))
        send.tap()
    }

    // MARK: 1. Verified start → animation → delivered image

    func testVerifiedGenerationAnimatesThenHandsOffToTheDeliveredImage() {
        let app = launch(imageDemo: true, holdMs: 8_000)
        openConversation(app)
        sendPrompt(app, text: "draw a cat")

        let stage = animation(app)
        XCTAssertTrue(stage.waitForExistence(timeout: 20),
                      "the verified generation frame must start the branded animation")
        XCTAssertEqual(stage.label, "Generating image", "the animation announces what it is")
        XCTAssertEqual(stage.value as? String, "In progress",
                       "the animation reports state, never a fabricated quantity")
        attachScreenshot(app, name: "imagegen-generating")

        // The animation belongs to the CITING tool row (user, tool, assistant).
        let toolRow = transcript(app).descendants(matching: .any)["fleet.conversation.row.row-2"]
        XCTAssertTrue(toolRow.waitForExistence(timeout: 10))
        let rowStage = animation(in: toolRow)
        XCTAssertTrue(rowStage.exists,
                      "the animation must render inside the citing tool row, not as a detached row")

        // Wait for the positive handoff state first. Querying disappearance
        // while the tool row is reconfiguring produced XCUITest snapshot
        // timeouts on hosted runners. Resolve the exact accessibility role
        // and identifier directly; the image identifier includes its citing
        // row id, and the image is the stable completion signal.
        let image = toolRow.buttons[Self.deliveredImageIdentifier].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 40),
                      "the delivered image must render in the citing row")
        XCTAssertTrue(rowStage.waitForNonExistence(timeout: 5),
                      "the delivered result must stop the animation")
        attachScreenshot(app, name: "imagegen-delivered")
    }

    /// Light/dark appearance evidence: the captured attachments come from a
    /// run whose simulator appearance is set externally
    /// (`xcrun simctl ui <udid> appearance light|dark`) — the same lifecycle
    /// assertions run in both appearances.
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: 2. Failure stops the animation, no image

    func testFailedGenerationStopsTheAnimationWithoutAnImage() {
        let app = launch(imageDemo: true, holdMs: 8_000, fail: true)
        openConversation(app)
        sendPrompt(app, text: "draw a cat")

        let stage = animation(app)
        XCTAssertTrue(stage.waitForExistence(timeout: 20),
                      "precondition: the animation is running while the call is in flight")
        XCTAssertTrue(stage.waitForNonExistence(timeout: 30),
                      "an explicitly failed generation must stop the animation")

        // No delivered image follows a failure — assert after a settle so a
        // late artifact render cannot slip past the check.
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertFalse(deliveredImage(app).exists,
                       "a failed generation delivers no image")
    }

    // MARK: 3. Cancellation stops the animation

    func testInterruptStopsTheAnimation() {
        // `ORDER=streaming` mirrors the second real wire shape: the turn
        // streams first and the tool runs mid-turn — the window in which the
        // composer's Stop control exists (phase is `.ready` until
        // `message.start`, so a tools-first generation presents no Stop).
        let app = launch(imageDemo: true, holdMs: 20_000, order: "streaming")
        openConversation(app)
        sendPrompt(app, text: "draw a cat")

        let stage = animation(app)
        XCTAssertTrue(stage.waitForExistence(timeout: 20),
                      "precondition: the generation is in flight")

        let stop = app.descendants(matching: .any)["fleet.conversation.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15), "the stop control must be available mid-turn")
        stop.tap()

        XCTAssertTrue(stage.waitForNonExistence(timeout: 8),
                      "the interrupt must stop the animation well before the (20 s) generation would complete")
    }

    // MARK: Navigation helper (the scripted workstation/default conversation)

    private func openConversation(_ app: XCUIApplication) {
        _ = UITabNavigation.openGatewaysTab(app)
        tap(app.descendants(matching: .any)["fleet.gateways.row.workstation"])
        UITabNavigation.openGatewayBots(app, gateway: "workstation")
        tap(app.descendants(matching: .any)["fleet.roster.row.workstation#default"])
        tap(app.descendants(matching: .any)["fleet.bot-detail.sessions.row.workstation.default.s1"])

        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(20)
        while !composer.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(composer.isEnabled, "composer should enable after session open")
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "required UI element should appear")
        element.tap()
    }
}
