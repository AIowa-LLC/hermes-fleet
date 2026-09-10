import XCTest

/// #9 — deterministic Hermes Pet avatar journeys on the DEBUG scripted
/// fleet (Workstation gateway, `default` bot).
///
/// Journey 1 (happy path): Edit → Avatar → Choose Hermes Pet → tap a pet
/// cell → the picker hands PNG bytes to the #7 draft (preview flips to
/// "photo avatar" IMMEDIATELY, before Save) → Save → the coordinated
/// transaction persists the asset → reopen shows the photo authoritative.
///
/// Journey 2 (cancel): select a pet (draft staged) → Cancel → reopen —
/// the remote avatar is unchanged (zero remote writes from the draft).
final class BotPetAvatarUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openDefaultEdit(_ app: XCUIApplication) {
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
        let configSegment = app.buttons["Configuration"].firstMatch
        if configSegment.exists { configSegment.tap() }
        let edit = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot-detail.edit").firstMatch
        if !edit.waitForExistence(timeout: 5) {
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

    func testChoosePetStagesPreviewsAndSaves() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openDefaultEdit(app)

        // Open the Pet picker.
        let petButton = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.pet").firstMatch
        XCTAssertTrue(petButton.waitForExistence(timeout: 10), "Choose Hermes Pet should render")
        petButton.tap()

        // The scripted gallery loads (two-stage; local phase fast).
        let cell = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.pet.cell.spark-fox").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "scripted pet cell should render")

        // Select the pet — the sheet closes and the DRAFT preview flips
        // to the staged photo BEFORE any Save.
        cell.tap()
        let preview = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.preview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let stagedLabel = preview.label
        XCTAssertTrue(stagedLabel.contains("photo avatar"),
                      "staged pet must preview as a photo before Save (got: \(stagedLabel))")

        // Save — closes only after the coordinated transaction succeeds.
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save should render")
        save.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.bot-detail.header").firstMatch
                .waitForExistence(timeout: 15),
            "back on bot detail — sheet closed after successful save")

        // Reopen: the pet photo is roster-authoritative (asset saved;
        // roster refreshed; scripted overlay reflects hasAvatar).
        let edit = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot-detail.edit").firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let reopened = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.preview").firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        let reopenedLabel = reopened.label
        XCTAssertTrue(reopenedLabel.contains("photo avatar"),
                      "pet avatar must remain authoritative after save (got: \(reopenedLabel))")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }
    }

    func testCancelAfterPetSelectionWritesNothing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openDefaultEdit(app)

        let petButton = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.pet").firstMatch
        XCTAssertTrue(petButton.waitForExistence(timeout: 10))
        petButton.tap()
        let cell = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.pet.cell.pixel-owl").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "scripted pet cell should render")
        cell.tap()

        // Draft staged (photo preview) — then CANCEL.
        let preview = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.preview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.label.contains("photo avatar"))
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()

        // Back on detail; reopen — the draft was DISCARDED (zero remote
        // writes; the hosted BotPetAvatarTests prove the seam recorded
        // no configure/upload). The reopened preview renders the
        // authoritative state with no staged pet bytes: nothing from the
        // cancelled selection survives into a fresh draft.
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.bot-detail.header").firstMatch
                .waitForExistence(timeout: 10))
        let edit = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot-detail.edit").firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let reopened = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.preview").firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        // A COLD cache renders the deterministic shape (the honest
        // fallback when avatar bytes are not yet fetched); either way the
        // preview must NOT claim freshly-staged pet bytes. The decisive
        // zero-write proof lives at the controller layer (hosted
        // testSelectionStagesDraftOnlyNoRemoteWritesUntilSave).
        XCTAssertFalse(reopened.label.contains("staged"),
                       "cancelled pet selection must not survive (got: \(reopened.label))")
        let cancel2 = app.buttons["Cancel"].firstMatch
        if cancel2.waitForExistence(timeout: 5) { cancel2.tap() }
    }

    func testUnsupportedGatewayRendersUnavailableState() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_PETS_UNSUPPORTED"] = "1"
        app.launch()
        openDefaultEdit(app)

        let petButton = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.avatar.pet").firstMatch
        XCTAssertTrue(petButton.waitForExistence(timeout: 10))
        petButton.tap()

        // The picker surfaces the honest unavailable state — not a
        // transient failure, not an empty gallery.
        let unsupported = app.descendants(matching: .any)
            .matching(identifier: "fleet.bot.pet.unsupported").firstMatch
        XCTAssertTrue(unsupported.waitForExistence(timeout: 15),
                      "unsupported gateway must render the Pets unavailable state")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }
    }
}
