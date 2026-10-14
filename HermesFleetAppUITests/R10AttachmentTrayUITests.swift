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
        XCTAssertTrue(element.waitForExistence(timeout: 10), "element should exist before activation")
        let deadline = Date().addingTimeInterval(10)
        while !element.isHittable && Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.2)))
        }
        XCTAssertTrue(element.isHittable, "element should be hittable before activation")
        element.tap()
    }

    /// On iOS 26 the document picker is embedded in the host app's accessibility
    /// tree as a DOC.browsingRoot element. Its visible X is exposed as a Cancel
    /// button beneath that root; the separate DocumentsApp process is not
    /// discoverable while this picker is presented.
    private func waitForSystemPicker(
        in app: XCUIApplication,
        selectedAction: XCUIElement,
        pickerName: String
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(20)
        let closePredicate = NSPredicate(format: "label IN %@", ["Cancel", "Close"])
        let filesBrowser = app.otherElements
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.browsingRoot Source:"))
            .firstMatch
        let filesCloseButton = filesBrowser.descendants(matching: .button)
            .matching(closePredicate)
            .firstMatch
        // PHPicker is presented by the OS outside the host app's accessibility
        // tree. Query its owner through SpringBoard instead of reusing an
        // app-scoped element whose activation frame can be invalid.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let photoCloseButton = springboard.buttons
            .matching(closePredicate)
            .firstMatch

        while Date() < deadline {
            if pickerName == "File" {
                if !selectedAction.exists,
                   filesBrowser.exists,
                   filesCloseButton.exists,
                   filesCloseButton.isHittable {
                    return filesCloseButton
                }
            } else if !selectedAction.exists,
                      photoCloseButton.exists,
                      photoCloseButton.isHittable {
                return photoCloseButton
            }

            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.2)))
        }

        // Capture expensive diagnostics only after the readiness budget has
        // expired, so screenshot/hierarchy collection cannot consume the
        // time reserved for the picker to present.
        XCTContext.runActivity(named: "\(pickerName) picker readiness failure") { activity in
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "\(pickerName) picker at readiness failure"
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)

            let hierarchyText = """
            Host app accessibility hierarchy:
            \(app.debugDescription)

            SpringBoard accessibility hierarchy:
            \(springboard.debugDescription)
            """
            let hierarchy = XCTAttachment(
                data: Data(hierarchyText.utf8),
                uniformTypeIdentifier: "public.plain-text"
            )
            hierarchy.name = "\(pickerName) picker accessibility hierarchies at readiness failure"
            hierarchy.lifetime = .keepAlways
            activity.add(hierarchy)
        }
        XCTFail("\(pickerName) picker should dismiss Add and expose its hittable Cancel or Close control within 20 seconds")
        return pickerName == "File" ? filesCloseButton : photoCloseButton
    }

    private func dismissPhotoPicker(
        by tapping: XCUIElement,
        in app: XCUIApplication,
        returningTo addButton: XCUIElement
    ) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let photoCloseButton = springboard.buttons
            .matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"]))
            .firstMatch

        tap(tapping)

        let deadline = Date().addingTimeInterval(10)
        while photoCloseButton.exists && Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.2)))
        }
        XCTAssertFalse(photoCloseButton.exists, "Photos picker should dismiss after tapping its system-owned close control")

        while !addButton.isHittable && Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.2)))
        }
        XCTAssertTrue(addButton.isHittable, "conversation Add action should be reachable after the Photos picker closes")
    }

    private func dismissFilePicker(
        by tapping: XCUIElement,
        in app: XCUIApplication,
        returningTo addButton: XCUIElement
    ) {
        let filesBrowser = app.otherElements
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.browsingRoot Source:"))
            .firstMatch

        tap(tapping)

        let deadline = Date().addingTimeInterval(10)
        while filesBrowser.exists && Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.2)))
        }
        XCTAssertFalse(filesBrowser.exists, "Files picker should dismiss after tapping its Cancel control")

        while !addButton.isHittable && Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.2)))
        }
        XCTAssertTrue(addButton.isHittable, "conversation Add action should be reachable after the Files picker closes")
    }

    private func openConversation(_ app: XCUIApplication) {
        UITabNavigation.openGatewaysTab(app)
        tap(app.descendants(matching: .any).matching(identifier: "fleet.gateways.row.workstation").firstMatch)
        UITabNavigation.openGatewayBots(app)
        tap(app.descendants(matching: .any).matching(identifier: "fleet.roster.row.workstation#default").firstMatch)
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
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
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
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openConversation(app)

        // The failure surfaces as the composer banner — never silent.
        let banner = firstMatch(in: app, identifier: "fleet.conversation.attachment.error")
        XCTAssertTrue(banner.label.contains("too large") || banner.label.contains("fixture"),
                      "banner carries the honest failure: \(banner.label)")
    }

    func testAddActionsPresentAndCanReopenSystemPickers() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        openConversation(app)

        let add = firstMatch(in: app, identifier: "fleet.conversation.attach")

        tap(add)
        let fileAction = firstMatch(in: app, identifier: "fleet.conversation.attach.file")
        tap(fileAction)
        let cancelFile = waitForSystemPicker(in: app, selectedAction: fileAction, pickerName: "File")
        dismissFilePicker(by: cancelFile, in: app, returningTo: add)

        tap(add)
        let repeatedFileAction = firstMatch(in: app, identifier: "fleet.conversation.attach.file")
        tap(repeatedFileAction)
        let cancelRepeatedFile = waitForSystemPicker(in: app, selectedAction: repeatedFileAction, pickerName: "File")
        dismissFilePicker(by: cancelRepeatedFile, in: app, returningTo: add)

        tap(add)
        let photoAction = firstMatch(in: app, identifier: "fleet.conversation.attach.photo")
        tap(photoAction)
        let cancelPhoto = waitForSystemPicker(in: app, selectedAction: photoAction, pickerName: "Photo")
        dismissPhotoPicker(by: cancelPhoto, in: app, returningTo: add)

        tap(add)
        let repeatedPhotoAction = firstMatch(in: app, identifier: "fleet.conversation.attach.photo")
        tap(repeatedPhotoAction)
        let cancelRepeatedPhoto = waitForSystemPicker(in: app, selectedAction: repeatedPhotoAction, pickerName: "Photo")
        dismissPhotoPicker(by: cancelRepeatedPhoto, in: app, returningTo: add)
    }
}
