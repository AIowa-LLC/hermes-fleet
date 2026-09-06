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
        tap(firstMatch(in: app, identifier: "fleet.bots.row.workstation#default"))
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
        XCTAssertFalse(bannerLabel.contains("sk-live-demo"),
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

    func testYoloToggleShowsDangerConfirmation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_APPROVAL_DEMO"] = "1"
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

    // MARK: - Helpers (same shapes as the U6 suite)

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
