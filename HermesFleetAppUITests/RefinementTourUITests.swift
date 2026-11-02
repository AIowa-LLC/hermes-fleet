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

    // MARK: Phase 3 — themes, app icon, avatars, motion moments

    private func selectTheme(_ app: XCUIApplication, _ name: String) {
        let row = element(app, "fleet.settings.accent")
        guard tapIfPresent(row) else { return }
        _ = tapIfPresent(app.buttons[name].firstMatch, timeout: 5)
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// Per theme: the Settings Theme row, the home, and a conversation, in
    /// the current appearance. Leaves the default (Fleet) applied.
    func testTourThemes() throws {
        for (index, name) in ["Fleet", "Violet", "Ocean", "Orchid", "Graphite"].enumerated() {
            let id = "\(16 + index)-theme-\(name.lowercased())"
            let settings = makeApp(["HERMES_FLEET_AUTO_NAV": "settings"])
            settings.launch()
            Thread.sleep(forTimeInterval: 2.0)
            selectTheme(settings, name)
            shot("\(id)-settings")
            settings.terminate()

            launchShot("fleet", "\(id)-home")

            let chat = makeApp(["HERMES_FLEET_AUTO_NAV": "bot-detail", "HERMES_FLEET_LONG_CHAT_FIXTURE": "1"])
            chat.launch()
            if openDefaultSession(chat).exists {
                Thread.sleep(forTimeInterval: 1.5)
                shot("\(id)-chat")
            }
            chat.terminate()
        }
        let reset = makeApp(["HERMES_FLEET_AUTO_NAV": "settings"])
        reset.launch()
        Thread.sleep(forTimeInterval: 2.0)
        selectTheme(reset, "Fleet")
        reset.terminate()
    }

    func testTourAppIcon() throws {
        let app = makeApp(["HERMES_FLEET_AUTO_NAV": "settings"])
        app.launch()
        Thread.sleep(forTimeInterval: 2.0)
        guard tapIfPresent(element(app, "fleet.settings.app-icon")) else { shot("21-app-icon-unreached"); return }
        shot("21-app-icon-menu")
        guard tapIfPresent(element(app, "fleet.settings.app-icon.violet"), timeout: 5) else { return }
        Thread.sleep(forTimeInterval: 1.0)
        shot("22-app-icon-changed")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let ok = springboard.alerts.buttons["OK"].firstMatch
        if ok.waitForExistence(timeout: 3) { ok.tap() }
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)
        shot("23-app-icon-home-screen")
        app.activate()
        Thread.sleep(forTimeInterval: 1.5)
        if tapIfPresent(element(app, "fleet.settings.app-icon")) {
            _ = tapIfPresent(element(app, "fleet.settings.app-icon.standard"), timeout: 5)
            if ok.waitForExistence(timeout: 3) { ok.tap() }
        }
        app.terminate()
    }

    func testTourPetPicker() throws {
        let app = makeApp()
        app.launch()
        UITabNavigation.openBotsTab(app)
        guard tapIfPresent(element(app, "fleet.roster.row.workstation#default"), timeout: 15) else { return }
        shot("24-bots-avatars")
        if app.buttons["Configuration"].firstMatch.exists { app.buttons["Configuration"].firstMatch.tap() }
        guard tapIfPresent(element(app, "fleet.bot-detail.edit")) else { return }
        guard tapIfPresent(element(app, "fleet.bot.avatar.pet")) else { return }
        _ = element(app, "fleet.bot.pet.cell.spark-fox").waitForExistence(timeout: 15)
        shot("25-pet-picker")
        app.terminate()
    }

    func testTourApprovedMoment() throws {
        let app = makeApp(["HERMES_FLEET_APPROVAL_DEMO": "1", "HERMES_FLEET_APPROVAL_BIOMETRIC": "success"])
        app.launch()
        UITabNavigation.openGatewaysTab(app)
        _ = tapIfPresent(element(app, "fleet.gateways.row.workstation"))
        UITabNavigation.openGatewayBots(app)
        _ = tapIfPresent(element(app, "fleet.roster.row.workstation#default"))
        guard tapIfPresent(element(app, "fleet.bot-detail.sessions.row.workstation.default.s1")) else { return }
        let composer = app.textFields["fleet.conversation.composer"]
        guard composer.waitForExistence(timeout: 10) else { return }
        let deadline = Date().addingTimeInterval(15)
        while !composer.isEnabled && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        composer.tap()
        composer.typeText("hello approvals")
        _ = tapIfPresent(element(app, "fleet.conversation.send"))
        guard element(app, "approval.banner").waitForExistence(timeout: 15) else { return }
        shot("26-approval-banner")
        guard tapIfPresent(element(app, "approval.approve"), timeout: 5) else { return }
        let once = app.buttons["Approve once"].firstMatch
        if once.waitForExistence(timeout: 2) { once.tap() }
        // The confirmation holds ~1.6 s; capture frames straight away
        // (a waitForExistence round-trip can outlast it).
        for frame in 0..<8 {
            let screenshot = XCUIScreen.main.screenshot()
            let seen = element(app, "approval.approved-moment").exists
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "\(variant)-27-approved-frame\(frame)-\(seen)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if seen, let dir = ProcessInfo.processInfo.environment["REFINE_SHOTS_DIR"], !dir.isEmpty {
                try? screenshot.pngRepresentation.write(
                    to: URL(fileURLWithPath: dir).appendingPathComponent("\(variant)-27-approved-moment.png"))
                break
            }
            print("approved-moment frame \(frame) seen=\(seen)")
        }
        app.terminate()
    }
}
