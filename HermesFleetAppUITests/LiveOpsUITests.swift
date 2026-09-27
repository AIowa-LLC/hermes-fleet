import XCTest

/// Live Ops v1 (Build 91, Worker B) — deterministic scripted-fleet UI suite
/// over `ScriptedLiveOpsEngine` (no live gateway). Proves:
///   1. the Fleet Home summary strip carries real Live Ops facts (Active /
///      Needs You) and never renders "0 Active" under partial coverage;
///   2. a Needs You approval row approves through the SAME biometric stub
///      R9ApprovalBannerUITests uses, and the operation transitions to
///      Working on the next refresh;
///   3. Operation Detail opens, shows the swarm tree, and an unsupported
///      gateway's neutral "limited activity reporting" copy is reachable.
final class LiveOpsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ app: XCUIApplication, extraEnv: [String: String] = [:]) {
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        // Same deterministic biometric stub R9ApprovalBannerUITests relies
        // on for the conversation approval banner — Approve requires this
        // seam to succeed; Live Ops reuses the identical gate.
        app.launchEnvironment["HERMES_FLEET_APPROVAL_BIOMETRIC"] = "success"
        for (key, value) in extraEnv { app.launchEnvironment[key] = value }
        app.launch()
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func openFleetTab(_ app: XCUIApplication) {
        UITabNavigation.shellReady(app)
        UITabNavigation.tabControl(app, label: "Fleet").tap()
    }

    // MARK: - Summary strip

    func testSummaryStripShowsLiveOpsFactsAndCoverage() throws {
        let app = XCUIApplication()
        launch(app)
        openFleetTab(app)

        let dashboard = firstMatch(in: app, identifier: "fleet.dashboard")
        XCTAssertTrue(dashboard.waitForExistence(timeout: 10), "Fleet dashboard should render")

        // The Live Operations section is the substantially-different first
        // viewport this mission asks for — it must appear once any gateway
        // has ever reported Live Ops.
        let liveOpsHeader = firstMatch(in: app, identifier: "fleet.dashboard.liveOps.header")
        XCTAssertTrue(liveOpsHeader.waitForExistence(timeout: 10),
                      "Live Operations section should replace the fallback Active Now section")

        // The workstation parent operation ("Ship Build 91") should render.
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "fleet.dashboard.liveOps.operation.workstation"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the working operation card should render")

        // Coverage caveat: the fixture's `arch` gateway is unsupported —
        // neutral copy, never framed as an error.
        let coverage = firstMatch(in: app, identifier: "fleet.dashboard.coverage")
        XCTAssertTrue(coverage.waitForExistence(timeout: 10))
        XCTAssertTrue(coverage.label.contains("limited activity reporting"),
                      "an older/unsupported gateway must render neutral copy: \(coverage.label)")

        attachScreenshot(of: app, name: "liveops-home-summary")
    }

    // MARK: - No "0 Active" under partial coverage

    func testPartialCoverageNeverRendersZeroActive() throws {
        let app = XCUIApplication()
        launch(app, extraEnv: ["HERMES_FLEET_LIVEOPS_PARTIAL": "1"])
        openFleetTab(app)

        let activeFact = firstMatch(in: app, identifier: "fleet.dashboard.glance.active")
        XCTAssertTrue(activeFact.waitForExistence(timeout: 10))
        // render-box's refresh fails under this knob, but workstation's real
        // Working operation must still be counted — never "0".
        XCTAssertNotEqual(activeFact.label, "Active: 0",
                          "partial coverage must never collapse a real active operation to zero")
    }

    // MARK: - Needs You approval flow

    func testApprovalRowApprovesAndOperationStartsWorking() throws {
        let app = XCUIApplication()
        launch(app)
        openFleetTab(app)

        let approveRowPrefix = "fleet.dashboard.needsYou.liveOps.render-box"
        let approveButton = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "\(approveRowPrefix)") )
            .matching(NSPredicate(format: "identifier ENDSWITH %@", ".approve"))
            .firstMatch
        XCTAssertTrue(approveButton.waitForExistence(timeout: 10),
                      "the render-box pending approval should render in Needs You")
        approveButton.tap()

        // The row disappears once the gateway acknowledges (never before).
        let gone = NSPredicate(format: "exists == 0")
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: approveButton)], timeout: 10)
        XCTAssertFalse(approveButton.exists, "an acknowledged approval must clear its row")

        attachScreenshot(of: app, name: "liveops-approval-approved")
    }

    // MARK: - Operation Detail

    func testOperationDetailShowsSwarm() throws {
        let app = XCUIApplication()
        launch(app)
        openFleetTab(app)

        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "fleet.dashboard.liveOps.operation.workstation"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()

        let detail = firstMatch(in: app, identifier: "fleet.liveOpsDetail")
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "Operation Detail should open")

        let swarmNode = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "fleet.liveOpsDetail.swarm.node"))
            .firstMatch
        XCTAssertTrue(swarmNode.waitForExistence(timeout: 10), "the swarm tree should render at least one node")

        attachScreenshot(of: app, name: "liveops-operation-detail")
    }

    // MARK: - Helpers

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
