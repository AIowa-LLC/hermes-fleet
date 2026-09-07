import XCTest

/// R10-T1 — deterministic attachment-tray UI suite (scripted fleet, no live
/// gateway): the composer "+" menu stages a fixture attachment through the
/// `ScriptedAttachmentSeam` (demo hook `HERMES_FLEET_ATTACHMENT_PICK=1`
/// injects the pick so the suite never drives the system photo/document
/// picker), the chip renders with name + size, send succeeds, and the
/// transcript shows the `@file:` ref. The failure-hook pass proves the
/// never-silent error banner.
final class R10AttachmentTrayUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "missing element: \(identifier)")
        return element
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.isHittable || element.isEnabled, "element not hittable/enabled")
        element.tap()
    }

    private func openConversation(_ app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        tap(app.descendants(matching: .any).matching(identifier: "fleet.gateways.row.workstation").firstMatch)
        tap(app.descendants(matching: .any).matching(identifier: "fleet.bots.row.workstation#default").firstMatch)
        tap(app.descendants(matching: .any).matching(identifier: "fleet.bot-detail.sessions.row.workstation.default.s1").firstMatch)
        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "conversation canvas should open with a composer")
        // Poll until enabled (phase .ready).
        let deadline = Date().addingTimeInterval(15)
        while !composer.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(composer.isEnabled, "composer should enable once the session is ready")
    }

    func testAttachChipRendersSendCitesRefInTranscript() throws {
        let app = XCUIApplication()
        // Demo hook: simulate the picked-file handoff through the scripted
        // seam (the system document picker is not deterministically drivable).
        app.launchEnvironment["HERMES_FLEET_ATTACHMENT_PICK"] = "1"
        app.launch()
        openConversation(app)

        // The "+" attach affordance renders in the ready composer (existence
        // only — opening the menu popover is not deterministically drivable).
        _ = firstMatch(in: app, identifier: "fleet.conversation.attach")

        // The demo-hook pick stages over file.attach; the chip appears with
        // name + human-readable size.
        let chip = firstMatch(in: app, identifier: "fleet.conversation.attachment.chip.notes.md")
        XCTAssertTrue(chip.label.contains("bytes"), "chip caption carries the size: \(chip.label)")

        // Type a prompt and send.
        let composer = app.textFields["fleet.conversation.composer"]
        composer.tap()
        composer.typeText("analyze the notes")
        tap(firstMatch(in: app, identifier: "fleet.conversation.send"))

        // The transcript's user row cites the staged @file: ref (the scripted
        // turn echoes it back too, but the user bubble is the assertion).
        let deadline = Date().addingTimeInterval(15)
        var cited = false
        while Date() < deadline {
            if app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "@file:attachments/notes.md")).firstMatch.exists {
                cited = true
                break
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(cited, "transcript should cite the staged @file: ref")

        // The tray cleared with the send.
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "fleet.conversation.attachment.chip.notes.md")
                .firstMatch.exists ||
            app.descendants(matching: .any)
                .matching(identifier: "fleet.conversation.attachment.chip.notes.md")
                .firstMatch.waitForExistence(timeout: 2),
            "chip should clear after send")
    }

    func testWireFailureSurfacesErrorBannerNeverSilent() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_ATTACHMENT_PICK"] = "1"
        app.launchEnvironment["HERMES_FLEET_ATTACHMENT_FAIL"] = "1"
        app.launch()
        openConversation(app)

        // The failure surfaces as the composer banner — never silent.
        let banner = firstMatch(in: app, identifier: "fleet.conversation.attachment.error")
        XCTAssertTrue(banner.label.contains("too large") || banner.label.contains("fixture"),
                      "banner carries the honest failure: \(banner.label)")
    }
}
