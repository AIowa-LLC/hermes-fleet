import XCTest

/// i7-gapfill — avatar control-surface UI journeys on the DEBUG scripted
/// fleet (audit residuals R1 + R4). The scripted seam is now asset-capable
/// (`supportsAvatarUpload` / `supportsPortraitGeneration`), so the
/// Photos / Files / Generate / Clear controls render deterministically.
///
/// Journey 1 (generated portrait, R1): Edit → Generate Portrait → the
///   gateway returns a deterministic preview → Use this portrait stages it
///   into the #7 draft (preview flips to "photo avatar" BEFORE Save) →
///   Save → reopen shows the photo authoritative.
/// Journey 2 (clear, R4): Edit on `default` (has an image asset) →
///   Clear custom avatar → the preview falls back to the deterministic
///   default shape immediately → Save → reopen shows the shape.
/// Journey 3 (non-default bot, R4): Edit on `researcher` → choose
///   Hexagon → preview flips before Save → Save → reopen authoritative.
final class BotAvatarSourcesUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openBotEdit(_ app: XCUIApplication, row: String) {
        UITabNavigation.openBotsTab(app)
        let botRow = app.descendants(matching: .any)
            .matching(identifier: row).firstMatch
        XCTAssertTrue(botRow.waitForExistence(timeout: 15), "bot row should render")
        botRow.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.bot-detail.header").firstMatch
                .waitForExistence(timeout: 10),
            "bot detail must open")
        let configSegment = app.buttons["Configuration"].firstMatch
        if configSegment.exists { configSegment.tap() }
        let edit = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot-detail.edit").firstMatch
        if !edit.waitForExistence(timeout: 5) {
            app.segmentedControls.firstMatch.buttons["Configuration"].firstMatch.tap()
        }
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Edit button should render")
        edit.tap()
        // The Avatar section sits below the metadata section; on a cold
        // sheet presentation the lazy Form can take a beat — swipe the
        // preview into the materialized window if it does not appear.
        let preview = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.preview").firstMatch
        for _ in 0..<4 where !preview.waitForExistence(timeout: 4) {
            app.swipeUp()
        }
        XCTAssertTrue(
            preview.waitForExistence(timeout: 10),
            "the Edit sheet must render the draft preview")
    }

    private func previewLabel(_ app: XCUIApplication) -> String {
        let preview = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.preview").firstMatch
        // Lazy Form: earlier swipes (toward the picker/confirm rows) can
        // scroll the preview OUT of the materialized window — scroll it
        // back into view before reading the label.
        for _ in 0..<6 where !preview.exists {
            app.swipeDown()
        }
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                      "preview must re-materialize after scrolling back")
        return preview.label
    }

    private func saveAndReopen(_ app: XCUIApplication) -> String {
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save should render")
        save.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.bot-detail.header").firstMatch
                .waitForExistence(timeout: 15),
            "back on bot detail — sheet closed after successful save")
        let edit = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot-detail.edit").firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let preview = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.preview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        return preview.label
    }

    /// R1: generated portrait → confirm → staged preview → Save →
    /// roster-authoritative photo.
    func testGeneratePortraitPreviewConfirmStagesAndSaves() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openBotEdit(app, row: "fleet.roster.row.workstation#default")

        // The avatar source controls render on the asset-capable seam.
        let generate = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.generate").firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 10),
                      "Generate Portrait must render on the scripted asset-capable fleet")

        // Generate → the gateway alert → Generate (empty optional style).
        generate.tap()
        let alert = app.alerts["Generate Portrait"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "generation alert should present")
        alert.buttons["Generate"].firstMatch.tap()

        // The deterministic portrait preview lands; confirm stages it into
        // the draft — the preview flips to a photo BEFORE Save. The confirm
        // row renders at the section's end: scroll it into view.
        let confirm = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.confirm").firstMatch
        for _ in 0..<6 where !confirm.exists {
            app.swipeUp()
        }
        XCTAssertTrue(confirm.waitForExistence(timeout: 15),
                     "the generated portrait preview + confirm button should render")
        for _ in 0..<3 where !confirm.isHittable {
            app.swipeUp()
        }
        confirm.tap()
        let staged = previewLabel(app)
        XCTAssertTrue(staged.contains("photo avatar"),
                      "confirmed portrait must stage as a photo before Save (got: \(staged))")

        // Save → reopen: the photo is roster-authoritative (asset saved
        // through the coordinated transaction; roster refreshed).
        let reopened = saveAndReopen(app)
        XCTAssertTrue(reopened.contains("photo avatar"),
                      "the saved portrait must be authoritative after refresh (got: \(reopened))")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }
    }

    /// R4: the Clear button falls back to the deterministic default shape
    /// immediately, and Save makes it authoritative.
    func testClearCustomAvatarFallsBackToShapeAndSaves() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openBotEdit(app, row: "fleet.roster.row.workstation#default")

        // `default` has an image asset → Clear renders.
        let clear = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.clear").firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 10),
                      "Clear custom avatar must render for a bot with an image asset")

        clear.tap()
        let staged = previewLabel(app)
        XCTAssertTrue(staged.contains("shape"),
                      "clearing must fall back to a shape preview immediately (got: \(staged))")
        XCTAssertFalse(staged.contains("photo avatar"),
                       "the staged clear must stop previewing the image")

        let reopened = saveAndReopen(app)
        XCTAssertTrue(reopened.contains("shape"),
                      "after save the shape (not the old image) is authoritative (got: \(reopened))")
        XCTAssertFalse(reopened.contains("photo avatar"),
                       "the cleared image must not mask the saved shape")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }
    }

    /// R4: the same shape journey on a NON-default bot (`researcher`).
    func testResearcherBotShapeJourney() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openBotEdit(app, row: "fleet.roster.row.workstation#researcher")

        // Choose Hexagon through the real picker control. The Avatar
        // section is taller than the viewport on the capable seam, and a
        // lazy Form only materializes rows near the viewport — swipe until
        // the picker enters the tree, then until it is hittable.
        let picker = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.shape").firstMatch
        for _ in 0..<8 where !picker.exists {
            app.swipeUp()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "shape picker should render after scrolling")
        for _ in 0..<4 where !picker.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(picker.isHittable, "shape picker must scroll into view (lazy Form)")
        picker.tap()
        let option = app.buttons["Hexagon"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Hexagon option should render")
        option.tap()

        let staged = previewLabel(app)
        XCTAssertTrue(staged.contains("hexagon shape"),
                      "preview must flip to Hexagon before Save (got: \(staged))")

        let reopened = saveAndReopen(app)
        XCTAssertTrue(reopened.contains("hexagon shape"),
                      "Hexagon must remain authoritative for the non-default bot (got: \(reopened))")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }
    }

    /// R1 (control-surface honesty): when the gateway does NOT support
    /// avatar assets, the editor must render the honest unavailable copy
    /// and NOT the Photos/Files/Generate/Clear controls.
    func testUnsupportedGatewayRendersHonestUnavailableCopyNotControls() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_AVATAR_UNSUPPORTED"] = "1"
        app.launch()
        openBotEdit(app, row: "fleet.roster.row.workstation#default")

        let unsupported = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.unsupported").firstMatch
        XCTAssertTrue(unsupported.waitForExistence(timeout: 10),
                      "the honest unavailable copy must render on a non-capable gateway")
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.bot.avatar.photos").firstMatch.exists,
            "Photos control must NOT render on a non-capable gateway")
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.bot.avatar.generate").firstMatch.exists,
            "Generate control must NOT render on a non-capable gateway")
        // The shape/color pickers remain available (metadata-only edits
        // never needed the asset surface).
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.bot.avatar.shape").firstMatch.exists,
            "the shape picker stays available without asset support")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }
    }
}
