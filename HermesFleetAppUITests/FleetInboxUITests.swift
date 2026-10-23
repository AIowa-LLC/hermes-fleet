import XCTest

/// Phase B: the approvals Inbox over the deterministic scripted fleet.
///
/// `HERMES_FLEET_INBOX_FIXTURE=1` seeds one pending command approval
/// (`ls ~/Projects`) on the `workstation` gateway, delivered through a
/// registered answer source. Scripted biometrics succeed by default, so the
/// approval is answered end to end through the real `InboxStore`.
/// `HERMES_FLEET_INBOX_OFFLINE=1` also seeds it, but leaves every gateway
/// disconnected.
///
/// Proves:
///   1. with no pending request the Inbox shows its designed empty state;
///   2. the drawer offers Inbox with a pending count, and the row opens a
///      detail sheet with the full command and the offered scopes;
///   3. approving moves the item from Pending to History;
///   4. with no gateway connected the inbox shows its offline banner and the
///      decisions are visible but disabled.
///
/// Screenshots for each state are attached (`.keepAlways`) to the result
/// bundle and exported from it.
final class FleetInboxUITests: XCTestCase {

    private let requestRowIdentifier =
        "fleet.inbox.row.workstation#workstation.default.s1#inbox-approval-ls-projects"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(withFixture: Bool, offline: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        if withFixture {
            app.launchEnvironment["HERMES_FLEET_INBOX_FIXTURE"] = "1"
        }
        if offline {
            app.launchEnvironment["HERMES_FLEET_INBOX_OFFLINE"] = "1"
        }
        app.launch()
        // Each case gets a fresh process: the next launch must not overlap a
        // still-running instance (the drawer's Menu button was not ready then).
        addTeardownBlock { app.terminate() }
        UITabNavigation.shellReady(app, timeout: 20)
        // Hydration can still be settling after the tab shell appears; the
        // roster is the first real screen, and the drawer is only reliably
        // hittable once it is on screen.
        XCTAssertTrue(firstMatch(app, "fleet.roster").waitForExistence(timeout: 30),
                      "the roster should be on screen before the drawer opens")
        return app
    }

    private func firstMatch(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Records the current screen as a kept attachment for later export.
    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens Inbox from the compact drawer. The drawer's row can swallow a
    /// tap while it is still presenting, so the tap is retried. The row label
    /// is checked while the drawer is open, because the row is only in the
    /// accessibility tree then.
    private func openInbox(_ app: XCUIApplication, expectedDrawerLabel: String? = nil) {
        _ = UITabNavigation.openDrawer(app)
        let row = firstMatch(app, "fleet.drawer.destination.inbox")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the drawer must offer Inbox")
        if let expectedDrawerLabel {
            XCTAssertEqual(row.label, expectedDrawerLabel,
                           "the drawer row carries no pending count when nothing is waiting")
        }
        for _ in 0..<4 {
            row.tap()
            usleep(700_000)
            if firstMatch(app, "fleet.inbox").waitForExistence(timeout: 3) { return }
            if !app.buttons["fleet.drawer.open"].exists { break }
            _ = UITabNavigation.openDrawer(app)
            if !row.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(firstMatch(app, "fleet.inbox").waitForExistence(timeout: 10),
                      "the Inbox destination must open from the drawer")
    }

    // MARK: 1. Designed empty state

    func testEmptyInboxExplainsItself() {
        let app = launch(withFixture: false)
        openInbox(app, expectedDrawerLabel: "Inbox")

        XCTAssertTrue(firstMatch(app, "fleet.inbox.empty").waitForExistence(timeout: 10),
                      "with no pending request the Inbox shows its empty state")
        XCTAssertTrue(app.staticTexts["No agent is waiting on you"].exists,
                      "the empty state names what the user is waiting for")
        attachScreen("inbox-empty")
    }

    // MARK: 2. Pending approval, drawer count, and detail

    func testPendingApprovalShowsCommandAndBadge() {
        let app = launch(withFixture: true)
        // The drawer row carries the pending count; the helper checks it while
        // the drawer is open and retries the tap while the drawer is presenting.
        openInbox(app, expectedDrawerLabel: "Inbox, 1 pending")

        XCTAssertTrue(firstMatch(app, "fleet.inbox.section.pending").waitForExistence(timeout: 10),
                      "pending section first")
        let pendingRow = firstMatch(app, requestRowIdentifier)
        XCTAssertTrue(pendingRow.waitForExistence(timeout: 10), "the scripted approval is listed")
        XCTAssertTrue(pendingRow.label.contains("ls ~/Projects"), "the row names the command")
        attachScreen("inbox-pending-list")

        pendingRow.tap()
        XCTAssertTrue(firstMatch(app, "fleet.inbox.detail.approve").waitForExistence(timeout: 10),
                      "the detail sheet offers Approve once")
        XCTAssertTrue(firstMatch(app, "fleet.inbox.detail.deny").exists, "Deny is always offered")
        XCTAssertTrue(firstMatch(app, "fleet.inbox.detail.open-session").exists,
                      "the detail links to the session")
        attachScreen("inbox-detail-pending")
    }

    // MARK: 3. Approve moves the item to History

    func testApprovingMovesTheItemToHistory() {
        let app = launch(withFixture: true)
        openInbox(app)

        let pendingRow = firstMatch(app, requestRowIdentifier)
        XCTAssertTrue(pendingRow.waitForExistence(timeout: 10), "the scripted approval is listed")
        pendingRow.tap()

        let approve = firstMatch(app, "fleet.inbox.detail.approve")
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "Approve once is offered")
        approve.tap()

        XCTAssertTrue(firstMatch(app, "fleet.inbox.section.history").waitForExistence(timeout: 15),
                      "the resolved item moves into History")
        let historyRow = firstMatch(app, requestRowIdentifier)
        XCTAssertTrue(historyRow.waitForExistence(timeout: 10), "the same item stays listed in History")
        XCTAssertTrue(historyRow.label.contains("Approved"), "History shows the approval outcome")
        XCTAssertTrue(firstMatch(app, "fleet.inbox.pending.empty").exists,
                      "nothing is left pending once the approval is answered")
        attachScreen("inbox-history")
    }

    // MARK: 4. Offline: banner, and decisions visible but disabled

    func testOfflineShowsBannerAndDisablesDecisions() {
        let app = launch(withFixture: true, offline: true)
        openInbox(app)

        XCTAssertTrue(firstMatch(app, "fleet.inbox.offline").waitForExistence(timeout: 15),
                      "with no gateway connected the Inbox shows its offline banner")
        attachScreen("inbox-offline")

        let pendingRow = firstMatch(app, requestRowIdentifier)
        XCTAssertTrue(pendingRow.waitForExistence(timeout: 10), "the pending item is still listed")
        pendingRow.tap()

        let approve = firstMatch(app, "fleet.inbox.detail.approve")
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "Approve stays visible while offline")
        XCTAssertFalse(approve.isEnabled, "Approve is disabled while offline")
        let deny = firstMatch(app, "fleet.inbox.detail.deny")
        XCTAssertTrue(deny.exists, "Deny stays visible while offline")
        XCTAssertFalse(deny.isEnabled, "Deny is disabled while offline")
        XCTAssertTrue(firstMatch(app, "fleet.inbox.detail.offline").exists,
                      "the detail explains why the decisions are off")
        attachScreen("inbox-detail-offline")
    }
}
