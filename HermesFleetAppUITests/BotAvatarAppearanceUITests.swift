import XCTest

/// #7 — deterministic avatar appearance user journeys on the DEBUG
/// scripted fleet (Workstation gateway, `default` bot, which has an
/// existing custom image asset).
///
/// Proves the acceptance path end-to-end through the real controls:
///   1. open Edit on `default` — the preview renders the draft (image)
///   2. choose Cloud — the preview flips to the Cloud shape IMMEDIATELY
///      (staged draft, before Save; the image is staged for removal)
///   3. tap Save — the sheet closes only after the coordinated
///      metadata+asset transaction succeeds
///   4. reopen Edit — the preview still shows Cloud (roster-authoritative
///      after refresh: the image asset is gone, the shape persists)
/// Plus the Cancel journey: image → shape → Cancel discards the draft.
final class BotAvatarAppearanceUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openDefaultEdit(_ app: XCUIApplication) {
        // NOTE: routed through the Bots tab (union roster), NOT the
        // Gateways → Detail drill-in — that deeper navigation path is
        // currently flaky-to-crashing on this simulator for pre-existing
        // suites too (verified on pristine main).
        UITabNavigation.openBotsTab(app)
        let botRow = app.descendants(matching: .any)
            .matching(identifier: "fleet.roster.row.workstation#default").firstMatch
        XCTAssertTrue(botRow.waitForExistence(timeout: 15), "default bot row should render")
        botRow.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.bot-detail.header").firstMatch
                .waitForExistence(timeout: 10),
            "bot detail must open")
        // The Edit affordance lives on the Configuration segment (FOS-5).
        let configSegment = app.buttons["Configuration"].firstMatch
        if configSegment.exists { configSegment.tap() }
        let edit = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot-detail.edit").firstMatch
        if !edit.waitForExistence(timeout: 5) {
            // Fall back to the segmented control's children (iOS variant).
            app.segmentedControls.firstMatch.buttons["Configuration"].firstMatch.tap()
        }
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Edit button should render")
        edit.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.bot.avatar.preview").firstMatch
                .waitForExistence(timeout: 10),
            "the Edit sheet must render the draft preview")
    }

    private func previewLabel(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.preview").firstMatch.label
    }

    /// The staged shape picker selection (a Form picker renders as a menu
    /// on iOS 26; the value row shows the current selection).
    private func chooseShape(_ app: XCUIApplication, _ shape: String) {
        let picker = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.shape").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "shape picker should render")
        picker.tap()
        // Menu items materialize as buttons in the presented menu.
        let option = app.buttons[shape].firstMatch
        if option.waitForExistence(timeout: 5) {
            option.tap()
        } else {
            app.descendants(matching: .any)[shape].firstMatch.tap()
        }
    }

    func testDefaultBotImageToShapeJourney() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openDefaultEdit(app)

        // `default` has an existing image asset; the seeded draft previews it.
        let seeded = previewLabel(app)
        XCTAssertTrue(seeded.contains("photo avatar") || seeded.contains("shape"),
                      "seeded preview renders (got: \(seeded))")

        chooseShape(app, "Cloud")

        // The preview flips to the Cloud shape IMMEDIATELY — before Save,
        // from the staged draft, not stale roster metadata.
        let cloudPreview = previewLabel(app)
        XCTAssertTrue(cloudPreview.contains("cloud shape"),
                      "preview must show Cloud before Save (got: \(cloudPreview))")

        // Save — the sheet closes only after the coordinated transaction
        // succeeds (metadata CAS + asset clear + roster refresh).
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save should render")
        save.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.bot-detail.header").firstMatch
                .waitForExistence(timeout: 15),
            "back on bot detail — sheet closed after successful save")

        // Reopen: the preview still shows Cloud — roster-authoritative
        // (the image asset was cleared, the shape persisted).
        let edit = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot-detail.edit").firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let reopened = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.preview").firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        let reopenedLabel = reopened.label
        XCTAssertTrue(reopenedLabel.contains("cloud shape"),
                      "Cloud must remain authoritative after save + roster refresh (got: \(reopenedLabel))")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }
    }

    func testImageToShapeCancelRetainsImage() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openDefaultEdit(app)

        let seeded = previewLabel(app)
        chooseShape(app, "Cloud")
        let staged = previewLabel(app)
        XCTAssertTrue(staged.contains("cloud shape"),
                      "staged draft previews Cloud (got: \(staged))")

        // Cancel: zero remote writes — the staged draft is discarded.
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Cancel should render")
        cancel.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.bot-detail.header").firstMatch
                .waitForExistence(timeout: 15),
            "back on bot detail after cancel")

        // Reopen: the preview is back to the seeded appearance — the
        // image asset is untouched (Cancel never wrote).
        let edit = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot-detail.edit").firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let reopened = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.preview").firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        XCTAssertEqual(reopened.label, seeded,
                       "Cancel must discard the staged draft (seeded: \(seeded), reopened: \(reopened.label))")
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }
    }
}
