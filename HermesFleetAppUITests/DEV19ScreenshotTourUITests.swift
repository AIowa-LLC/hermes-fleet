import XCTest

/// DEV19 release evidence — a best-effort screenshot tour of the screens the
/// build changed, over the deterministic scripted fleet (no live gateway).
///
/// ENVIRONMENTAL (not CI): it records images, it does not assert product
/// behavior (the deterministic suites do). Run it per appearance variant:
///
///   TEST_RUNNER_DEV19_SHOTS_DIR=/abs/dir TEST_RUNNER_DEV19_SHOTS_VARIANT=dark \
///   xcodebuild … test -only-testing:HermesFleetAppUITests/DEV19ScreenshotTourUITests
///
/// Light/dark follow the simulator appearance (`xcrun simctl ui <udid>
/// appearance dark`); the `ax5` variant launches at the largest accessibility
/// text size. Every image is also attached to the test result.
final class DEV19ScreenshotTourUITests: XCTestCase {

    private var variant: String {
        ProcessInfo.processInfo.environment["DEV19_SHOTS_VARIANT"] ?? "default"
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func makeApp(_ environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        if variant == "ax5" {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                    "UICTContentSizeCategoryAccessibilityXXXL"]
        }
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
        Thread.sleep(forTimeInterval: 0.8)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(variant)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["DEV19_SHOTS_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(variant)-\(name).png")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }
    }

    private func openScriptedConversation(_ app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        tapIfPresent(element(app, "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        tapIfPresent(element(app, "fleet.roster.row.workstation#default"))
        tapIfPresent(element(app, "fleet.bot-detail.sessions.row.workstation.default.s1"))
    }

    func testTourBotsGatewaysAndSettings() throws {
        let app = makeApp()
        app.launch()
        UITabNavigation.openBotsTab(app)
        shot("01-bots-roster")
        UITabNavigation.openGatewaysTab(app)
        shot("02-gateways")
        UITabNavigation.openSettings(app)
        shot("03-settings")
    }

    func testTourLongChatPaged() throws {
        let app = makeApp(["HERMES_FLEET_LONG_CHAT_FIXTURE": "1"])
        app.launch()
        openScriptedConversation(app)
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Long chat message 25000"))
            .firstMatch.waitForExistence(timeout: 15)
        shot("04-long-chat-newest")
        let loadEarlier = element(app, "fleet.conversation.load-earlier")
        let deadline = Date().addingTimeInterval(30)
        while !loadEarlier.isHittable && Date() < deadline { app.swipeDown(velocity: .fast) }
        shot("05-long-chat-load-earlier")
        if loadEarlier.isHittable {
            loadEarlier.tap()
            _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Long chat message 24800"))
                .firstMatch.waitForExistence(timeout: 15)
            shot("06-long-chat-after-load")
        }
    }

    func testTourLongChatUnsupported() throws {
        let app = makeApp(["HERMES_FLEET_LONG_CHAT_FIXTURE": "1", "HERMES_FLEET_LONG_CHAT_UNSUPPORTED": "1"])
        app.launch()
        openScriptedConversation(app)
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "can't send it in pages"))
            .firstMatch.waitForExistence(timeout: 15)
        shot("07-long-chat-unsupported")
    }

    func testTourConversationThinking() throws {
        let app = makeApp(["HERMES_FLEET_REASONING_DEMO": "1", "HERMES_FLEET_REASONING_DEMO_HOLD_MS": "6000"])
        app.launch()
        openScriptedConversation(app)
        let composer = app.textFields["fleet.conversation.composer"]
        if composer.waitForExistence(timeout: 15) {
            let deadline = Date().addingTimeInterval(15)
            while !composer.isEnabled && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            composer.tap()
            composer.typeText("Plan the release checklist")
            tapIfPresent(element(app, "fleet.conversation.send"))
            _ = element(app, "fleet.conversation.working").waitForExistence(timeout: 10)
            shot("08-conversation-thinking")
            Thread.sleep(forTimeInterval: 4)
            shot("09-conversation-streaming")
        }
    }

    func testTourGroupChatFindAndCopy() throws {
        let app = makeApp(["HERMES_FLEET_AUTO_NAV": "roster"])
        app.launch()
        let row = element(app, "fleet.room.row.room-alpha")
        var attempts = 0
        while !(row.exists && row.isHittable) && attempts < 20 {
            app.swipeUp(velocity: .slow)
            attempts += 1
        }
        guard tapIfPresent(row) else { shot("10-group-unreached"); return }
        _ = element(app, "fleet.room.entry.2").waitForExistence(timeout: 10)
        shot("10-group-chat")
        if tapIfPresent(element(app, "fleet.room.find")) {
            let field = element(app, "fleet.room.find.field")
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText("crew")
            }
            shot("11-group-find")
            tapIfPresent(element(app, "fleet.room.find.close"), timeout: 3)
        }
        let entry = element(app, "fleet.room.entry.2")
        if entry.waitForExistence(timeout: 5) {
            entry.press(forDuration: 1.0)
            shot("12-group-copy-menu")
        }
    }

    func testTourHTTPWarning() throws {
        let app = makeApp()
        app.launch()
        UITabNavigation.openGatewaysTab(app)
        guard tapIfPresent(element(app, "fleet.gateways.add")) else { return }
        let advanced = app.buttons["fleet.add-gateway.advanced"]
        if advanced.waitForExistence(timeout: 10) {
            for _ in 0..<6 where !advanced.isHittable { app.swipeUp(velocity: .fast) }
            tapIfPresent(advanced)
            tapIfPresent(app.buttons["fleet.add-gateway.advanced.manual"])
        }
        let endpoint = app.textFields["fleet.gateways.form.endpoint"]
        if endpoint.waitForExistence(timeout: 10) {
            endpoint.tap()
            endpoint.typeText("http://gateway.example.com:9120")
            _ = element(app, "fleet.gateways.form.cleartext-warning").waitForExistence(timeout: 5)
            shot("13-http-warning")
        }
    }
}
