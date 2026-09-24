import XCTest

/// Card D — the Artifacts destination in the real shell, against the
/// deterministic scripted fleet (`HERMES_FLEET_ARTIFACT_FIXTURE=1` seeds two
/// observed artifacts with their source conversation).
///
/// Proves:
///   1. the drawer carries Artifacts while pins / recents /
///      Search / New Chat / Settings stay intact;
///   2. the destination lists observed media with provenance, and a row opens
///      the preview with the live image + sharing;
///   3. the pushed destination participates in navigation restore (relaunch
///      returns to it), and Command Center can reach it on every width.
final class ArtifactsDestinationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchFixtures(resetNavigation: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        if resetNavigation {
            app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        }
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launchEnvironment["HERMES_FLEET_ARTIFACT_FIXTURE"] = "1"
        app.launch()
        UITabNavigation.shellReady(app, timeout: 20)
        return app
    }

    private func firstMatch(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Opens Artifacts through the compact drawer, or the Command Center when
    /// the width has no drawer (iPad sidebar).
    private func openArtifacts(_ app: XCUIApplication) {
        if app.buttons["fleet.drawer.open"].waitForExistence(timeout: 5) {
            _ = UITabNavigation.openDrawer(app)
            let row = firstMatch(app, "fleet.drawer.destination.artifacts")
            XCTAssertTrue(row.waitForExistence(timeout: 10), "the drawer must offer Artifacts")
            // iOS 26 drops taps synthesized while the drawer is still
            // presenting; re-tap until the destination surface lands.
            for _ in 0..<4 {
                row.tap()
                usleep(700_000)
                if firstMatch(app, "fleet.artifacts").waitForExistence(timeout: 3) { return }
                if !app.buttons["fleet.drawer.open"].exists { break }
                _ = UITabNavigation.openDrawer(app)
                if !row.waitForExistence(timeout: 3) { break }
            }
            XCTAssertTrue(firstMatch(app, "fleet.artifacts").waitForExistence(timeout: 10),
                          "the Artifacts destination must open from the drawer")
        } else {
            // Dogfood r4: the drawer's search circle is the entry.
            UITabNavigation.openCommandCenter(app)
            let goto = firstMatch(app, "fleet.command-center.goto.artifacts")
            XCTAssertTrue(goto.waitForExistence(timeout: 10), "Command Center must offer Artifacts")
            goto.tap()
            XCTAssertTrue(firstMatch(app, "fleet.artifacts").waitForExistence(timeout: 10),
                          "the Artifacts destination must open from the Command Center")
        }
    }

    // MARK: 1. Drawer integration (preserve pins/recents/Settings/Search)

    func testDrawerCarriesArtifactsAndKeepsItsOtherRows() {
        let app = launchFixtures()
        guard app.buttons["fleet.drawer.open"].waitForExistence(timeout: 5) else {
            // Regular width (iPad sidebar): the drawer does not exist; the
            // Command Center path is covered by the destination test below.
            return
        }
        _ = UITabNavigation.openDrawer(app)

        XCTAssertTrue(firstMatch(app, "fleet.drawer.destination.artifacts").waitForExistence(timeout: 10),
                      "Artifacts must be a drawer destination")
        for identifier in [
            "fleet.drawer.search",
            "fleet.drawer.new-chat",
            "fleet.drawer.destination.settings",
        ] {
            XCTAssertTrue(firstMatch(app, identifier).exists, "\(identifier) must survive the drawer change")
        }
        XCTAssertTrue(
            firstMatch(app, "fleet.drawer.pinned.empty").exists
            || app.staticTexts["Pinned"].exists
            || app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fleet.drawer.pin.'")).count > 0,
            "the Pinned section must survive the drawer change")
        XCTAssertTrue(
            firstMatch(app, "fleet.drawer.recent.empty").exists
            || app.staticTexts["Recents"].exists,
            "the Recent chats section must survive the drawer change")
        XCTAssertFalse(app.staticTexts["NAVIGATE"].exists,
                       "the Navigate header is gone by design (ChatGPT-parity drawer)")
        XCTAssertTrue(firstMatch(app, "fleet.drawer.destination.bots").exists,
                      "primary destinations render directly under the header")
        UITabNavigation.closeDrawer(app)
    }

    // MARK: 2. Destination content + preview + share

    func testArtifactsDestinationListsObservedMediaWithProvenanceAndShare() {
        let app = launchFixtures()
        openArtifacts(app)

        XCTAssertTrue(app.navigationBars["Artifacts"].waitForExistence(timeout: 10),
                      "the destination renders its own screen")
        let firstRow = firstMatch(app, "fleet.artifacts.row.0")
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "the fixture artifact must list")
        XCTAssertTrue(firstRow.label.contains("briefing") || firstRow.label.contains("From"),
                      "the row carries its source conversation: \(firstRow.label)")

        firstRow.tap()
        XCTAssertTrue(firstMatch(app, "fleet.artifact.preview").waitForExistence(timeout: 10),
                      "a row opens the artifact preview")
        XCTAssertTrue(firstMatch(app, "fleet.artifact.preview.gateway").waitForExistence(timeout: 10),
                      "the preview names the hosting gateway")
        XCTAssertTrue(firstMatch(app, "fleet.artifact.share").waitForExistence(timeout: 15),
                      "a retrieved artifact is shareable")
        app.buttons["Done"].tap()
    }

    // MARK: 3. Navigation restore + Command Center reachability

    func testArtifactsDestinationRestoresAcrossRelaunch() {
        let app = launchFixtures()
        openArtifacts(app)
        XCTAssertTrue(firstMatch(app, "fleet.artifacts").waitForExistence(timeout: 10))

        app.terminate()
        // Relaunch WITHOUT the navigation reset: the persisted Fleet-stack
        // path must restore the Artifacts destination.
        let relaunched = launchFixtures(resetNavigation: false)
        XCTAssertTrue(firstMatch(relaunched, "fleet.artifacts").waitForExistence(timeout: 20),
                      "the pushed Artifacts destination must survive a relaunch")
    }

    // MARK: 4. Inline chat media (generation result → citing tool row)

    /// The scripted turn runs `image_generate` whose result names a gateway
    /// media path (`HERMES_FLEET_IMAGE_DEMO=1`); the retrieved image must land
    /// INSIDE the citing tool row's bubble, and tapping it opens the preview.
    func testGeneratedImageRendersInlineInTheCitingToolRow() {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launchEnvironment["HERMES_FLEET_APP_LOCK"] = "disabled"
        app.launchEnvironment["HERMES_FLEET_IMAGE_DEMO"] = "1"
        app.launch()
        UITabNavigation.shellReady(app, timeout: 20)
        openConversation(app)

        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("draw a cat")
        tap(app.descendants(matching: .any)["fleet.conversation.send"])

        // Resolve the image by its exact button role and ID. The ID carries
        // the citing tool row (`row-2`); querying that row's full descendant
        // tree while SwiftUI inserts the image stalled XCTest snapshots on
        // hosted simulators even though the image was visibly rendered.
        let inlineImage = app.buttons["fleet.artifact.image.row-2.scripted_generation.png"].firstMatch
        XCTAssertTrue(inlineImage.waitForExistence(timeout: 40),
                      "the generated image must render inline in the transcript")

        // The scripted turn layout is user, tool, assistant; row-2 in the
        // exact image identifier proves the artifact is attached to the tool.

        inlineImage.tap()
        XCTAssertTrue(firstMatch(app, "fleet.artifact.preview").waitForExistence(timeout: 15),
                      "tapping the inline image opens its preview")
        XCTAssertTrue(firstMatch(app, "fleet.artifact.share").waitForExistence(timeout: 15),
                      "the inline artifact is shareable")
        app.buttons["Done"].tap()
    }

    /// Open the scripted workstation/default conversation through the real
    /// navigation (Fleet → Manage Gateways → workstation → Bots → session).
    private func openConversation(_ app: XCUIApplication) {
        _ = UITabNavigation.openGatewaysTab(app)
        tap(app.descendants(matching: .any)["fleet.gateways.row.workstation"])
        UITabNavigation.openGatewayBots(app, gateway: "workstation")
        tap(app.descendants(matching: .any)["fleet.roster.row.workstation#default"])
        tap(app.descendants(matching: .any)["fleet.bot-detail.sessions.row.workstation.default.s1"])

        let composer = app.textFields["fleet.conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(20)
        while !composer.isEnabled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(composer.isEnabled, "composer should enable after session open")
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "required UI element should appear")
        element.tap()
    }
}
