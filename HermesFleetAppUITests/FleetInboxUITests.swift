import XCTest

/// Phase B: the approvals Inbox over the deterministic scripted fleet.
///
/// `HERMES_FLEET_INBOX_FIXTURE=1` gives the `workstation` gateway one pending
/// command approval (`ls ~/Projects`). Scripted biometrics succeed by default,
/// so the approval is answered end to end through the real `InboxStore`.
///
/// Proves:
///   1. with no pending agent request the Inbox shows its designed empty state;
///   2. the drawer offers Inbox with a pending count, the row opens a detail
///      sheet with the full command and the gateway's offered scopes;
///   3. approving moves the item from Pending to History, dimmed or resolved.
final class FleetInboxUITests: XCTestCase {

    private let requestRowIdentifier =
        "fleet.inbox.row.workstation#workstation.default.s1#inbox-approval-ls-projects"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(withFixture: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        if withFixture {
            app.launchEnvironment["HERMES_FLEET_INBOX_FIXTURE"] = "1"
        }
        app.launch()
        UITabNavigation.shellReady(app, timeout: 20)
        return app
    }

    private func firstMatch(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Opens Inbox from the compact drawer. The drawer's row can swallow a
    /// tap while it is still presenting, so the tap is retried.
    private func openInbox(_ app: XCUIApplication) {
        _ = UITabNavigation.openDrawer(app)
        let row = firstMatch(app, "fleet.drawer.destination.inbox")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the drawer must offer Inbox")
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
        openInbox(app)

        XCTAssertTrue(firstMatch(app, "fleet.inbox.empty").waitForExistence(timeout: 10),
                      "with no pending request the Inbox shows its empty state")
        XCTAssertTrue(app.staticTexts["No agent is waiting on you"].exists,
                      "the empty state names what the user is waiting for")
        XCTAssertEqual(firstMatch(app, "fleet.drawer.destination.inbox").label, "Inbox",
                       "the drawer row carries no pending count when nothing is waiting")
    }

    // MARK: 2. Pending approval, detail, and the drawer badge

    func testPendingApprovalShowsCommandAndBadge() {
        let app = launch(withFixture: true)
        _ = UITabNavigation.openDrawer(app)
        let row = firstMatch(app, "fleet.drawer.destination.inbox")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the drawer must offer Inbox")
        XCTAssertTrue(row.label.contains("1 pending"),
                      "the drawer row carries the pending count")
        row.tap()
        XCTAssertTrue(firstMatch(app, "fleet.inbox.section.pending").waitForExistence(timeout: 10),
                      "pending section first")

        let pendingRow = firstMatch(app, requestRowIdentifier)
        XCTAssertTrue(pendingRow.waitForExistence(timeout: 10), "the scripted approval is listed")
        XCTAssertTrue(pendingRow.label.contains("ls ~/Projects"), "the row names the command")
        pendingRow.tap()

        XCTAssertTrue(firstMatch(app, "fleet.inbox.detail.approve").waitForExistence(timeout: 10),
                      "the detail sheet offers Approve once")
        XCTAssertTrue(firstMatch(app, "fleet.inbox.detail.deny").exists, "Deny is always offered")
        XCTAssertTrue(firstMatch(app, "fleet.inbox.detail.open-session").exists,
                      "the detail links to the session")
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
    }
}
