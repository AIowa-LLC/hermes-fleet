import XCTest

/// Refinement-program evidence — a best-effort screenshot tour of the
/// surfaces the visual refinement phases touch, over the deterministic
/// scripted fleet (no live gateway).
///
/// ENVIRONMENTAL (not CI): it records images, it does not assert product
/// behavior (the deterministic suites do). Run it once per appearance:
///
///   xcrun simctl ui <udid> appearance dark
///   TEST_RUNNER_REFINE_SHOTS_DIR=/abs/dir TEST_RUNNER_REFINE_SHOTS_VARIANT=dark \
///   xcodebuild … test -only-testing:HermesFleetAppUITests/RefinementTourUITests
///
/// Every image is also attached to the test result.
final class RefinementTourUITests: XCTestCase {

    private var variant: String {
        ProcessInfo.processInfo.environment["REFINE_SHOTS_VARIANT"] ?? "default"
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func makeApp(_ environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    private func tapIfPresent(_ target: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        guard target.waitForExistence(timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(5)
        while !target.isHittable && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard target.isHittable else { return false }
        target.tap()
        return true
    }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 1.0)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(variant)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["REFINE_SHOTS_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(variant)-\(name).png")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }
    }

    private func launchShot(_ autoNav: String, _ name: String, scrollToBottom: Bool = false) {
        let app = makeApp(["HERMES_FLEET_AUTO_NAV": autoNav])
        app.launch()
        Thread.sleep(forTimeInterval: 2.5)
        if scrollToBottom {
            for _ in 0..<4 { app.swipeUp() }
        }
        shot(name)
        app.terminate()
    }

    func testTourShellSurfaces() throws {
        launchShot("fleet", "01-home")
        launchShot("chats", "02-chats")
        launchShot("groups", "03-groups")
        launchShot("settings", "04-settings-bottom", scrollToBottom: true)
        launchShot("about", "05-about")
    }

    func testTourDrawerOpen() throws {
        let app = makeApp(["HERMES_FLEET_AUTO_NAV": "fleet"])
        app.launch()
        UITabNavigation.openDrawer(app)
        shot("06-drawer")
        app.terminate()
    }

    func testTourGateways() throws {
        let app = makeApp()
        app.launch()
        UITabNavigation.openGatewaysTab(app)
        shot("07-gateways")
        app.terminate()
    }

    func testTourConversationComposer() throws {
        // The long-chat fixture gives the floating composer a transcript to
        // sit over (an empty chat shows chrome against bare canvas only).
        let app = makeApp(["HERMES_FLEET_AUTO_NAV": "bot-detail", "HERMES_FLEET_LONG_CHAT_FIXTURE": "1"])
        app.launch()
        let row = element(app, "fleet.bot-detail.sessions.row.workstation.default.s1")
        var attempts = 0
        while !(row.exists && row.isHittable) && attempts < 12 {
            app.swipeUp(velocity: .slow)
            attempts += 1
        }
        tapIfPresent(row)
        let composer = app.textFields["fleet.conversation.composer"]
        _ = composer.waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 2.0)
        shot("08-conversation")
        if tapIfPresent(composer) {
            composer.typeText("Ship the fleet report")
            shot("09-conversation-composing")
        }
        app.terminate()
    }

    func testTourSupportLink() throws {
        let app = makeApp(["HERMES_FLEET_AUTO_NAV": "about"])
        app.launch()
        guard tapIfPresent(element(app, "fleet.about.project-support")) else { return }
        Thread.sleep(forTimeInterval: 3.0)
        shot("10-support-link")
        app.terminate()
    }

    // MARK: Phase 2 — home top, rooms, streaming, code, attachments

    private func openDefaultSession(_ app: XCUIApplication) -> XCUIElement {
        let row = element(app, "fleet.bot-detail.sessions.row.workstation.default.s1")
        var attempts = 0
        while !(row.exists && row.isHittable) && attempts < 12 {
            app.swipeUp(velocity: .slow)
            attempts += 1
        }
        tapIfPresent(row)
        let composer = app.textFields["fleet.conversation.composer"]
        if composer.waitForExistence(timeout: 15) {
            let deadline = Date().addingTimeInterval(15)
            while !composer.isEnabled && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        }
        return composer
    }

    func testTourRoomConversation() throws {
        let app = makeApp(["HERMES_FLEET_AUTO_NAV": "groups"])
        app.launch()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "fleet.groups.row.")).firstMatch
        guard tapIfPresent(row, timeout: 15) else { shot("11-room-unreached"); return }
        Thread.sleep(forTimeInterval: 2.0)
        shot("11-room-conversation")
        app.terminate()
    }

    func testTourStreamingPresence() throws {
        let app = makeApp(["HERMES_FLEET_AUTO_NAV": "bot-detail",
                           "HERMES_FLEET_REASONING_DEMO": "1",
                           "HERMES_FLEET_REASONING_DEMO_HOLD_MS": "6000"])
        app.launch()
        let composer = openDefaultSession(app)
        guard tapIfPresent(composer) else { return }
        composer.typeText("Plan the release checklist")
        tapIfPresent(element(app, "fleet.conversation.send"))
        _ = element(app, "fleet.conversation.working").waitForExistence(timeout: 10)
        shot("12-conversation-thinking")
        Thread.sleep(forTimeInterval: 4)
        shot("13-conversation-streaming")
        app.terminate()
    }

    func testTourCodeBlock() throws {
        let app = makeApp(["HERMES_FLEET_AUTO_NAV": "bot-detail"])
        app.launchArguments += ["-issue5-markdown-fixture"]
        app.launch()
        let composer = openDefaultSession(app)
        guard tapIfPresent(composer) else { return }
        composer.typeText("Show me the release snippet")
        tapIfPresent(element(app, "fleet.conversation.send"))
        let block = element(app, "fleet.conversation.code.block")
        _ = block.waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 3)
        // At rest the reply's end is in view and the card sits just above
        // the viewport; drag the transcript down by about one card height.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = start.withOffset(CGVector(dx: 0, dy: 170))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        Thread.sleep(forTimeInterval: 0.8)
        shot("14-code-block")
        app.terminate()
    }

    func testTourAttachmentTray() throws {
        let app = makeApp(["HERMES_FLEET_AUTO_NAV": "bot-detail",
                           "HERMES_FLEET_ATTACHMENT_PICK": "1"])
        app.launch()
        _ = openDefaultSession(app)
        _ = element(app, "fleet.conversation.attachment.chip.notes.md").waitForExistence(timeout: 15)
        shot("15-attachment-tray")
        app.terminate()
    }
}
