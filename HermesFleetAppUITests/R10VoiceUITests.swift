import XCTest

/// R10-T4 — deterministic voice UI suite (scripted fleet, no live speech, no
/// audio hardware). The scripted voice seam is env-knobbed:
/// - `HERMES_FLEET_VOICE_DENIED=1` (the mandated deterministic suite): mic
///   tap → authorization denied → the honest gate banner with a Settings
///   button; NO capture ever starts.
/// - `HERMES_FLEET_VOICE_TRANSCRIPT=1`: mic tap → fixed FINAL transcript →
///   review chip above the composer (review-first; Send submits through the
///   normal composer path).
/// Live mic/speech tests are LOCAL-ONLY environmental suites — never here.
final class R10VoiceUITests: XCTestCase {

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
        let deadline = Date().addingTimeInterval(15)
        while !composer.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(composer.isEnabled, "composer should enable once the session is ready")
    }

    /// DENIED path (the mandated deterministic authorization-gate test): the
    /// mic button renders, tapping it surfaces the honest denied banner with
    /// a Settings action, and no listening state ever starts.
    func testMicDeniedShowsHonestGateBanner() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_VOICE_DENIED"] = "1"
        app.launch()
        openConversation(app)

        let mic = firstMatch(in: app, identifier: "fleet.conversation.mic")
        tap(mic)

        // The honest gate: banner + Settings action.
        _ = firstMatch(in: app, identifier: "fleet.conversation.voice.denied")
        _ = firstMatch(in: app, identifier: "fleet.conversation.voice.denied.settings")

        // No listening state, no transcript chip.
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "fleet.conversation.voice.transcript").firstMatch.exists,
            "denied ⇒ no transcript chip")
    }

    /// TRANSCRIPT path: authorized mic tap → fixed final transcript lands in
    /// the review chip (review-first); Send submits it through the composer
    /// path and the scripted turn streams back.
    func testTranscriptLandsForReviewAndSendSubmits() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_VOICE_TRANSCRIPT"] = "1"
        app.launch()
        openConversation(app)

        let mic = firstMatch(in: app, identifier: "fleet.conversation.mic")
        tap(mic)

        // The review chip appears with the scripted final transcript.
        let chip = firstMatch(in: app, identifier: "fleet.conversation.voice.transcript")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "transcript chip should land after capture settles")

        // Send it — the scripted fleet streams a canned turn back (the user
        // row + assistant row land in the transcript).
        let send = firstMatch(in: app, identifier: "fleet.conversation.voice.transcript.send")
        tap(send)

        // The scripted reply arrives (Hello from the scripted fleet…).
        // First turn: user row-1, assistant row-2.
        let reply = app.descendants(matching: .any)
            .matching(identifier: "fleet.conversation.row.row-2").firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "scripted assistant reply should stream after send")
    }
}
