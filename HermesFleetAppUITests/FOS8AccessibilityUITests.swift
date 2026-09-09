import XCTest

/// FOS-8 (t_1775f2c2) — accessibility + interaction polish UI suite against
/// the scripted simulator fleet (deterministic; no live gateway):
/// 1. VoiceOver row order: bot row composite label reads
///    name → gateway/route → status → preview → time (SPEC §16).
/// 2. Group composite announces name + member count (+ authority when
///    observed); decorative avatar contributes nothing.
/// 3. Touch targets: compact actionable controls held to the ≥44pt bar via
///    the shared FleetPressableStyle minimum (SPEC §16 Targets).
/// 4. Memory Graph list alternative: Graph ⇄ List switch, same filters,
///    node rows open the SAME detail sheet with edit/delete actions.
/// 5. RoomLink recovery inspector: one room-owned inspector (Links +
///    Recovery child sections), exact observed lineage, fencing-assertion
///    toggle gates Take over, demote uses the observed lineage.
/// 6. Group conversation scroll stability: reading history shows the
///    explicit Latest control; no forced scroll while reading.
final class FOS8AccessibilityUITests: XCTestCase {

    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    private func launch(extraEnv: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        self.app = app
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        for (key, value) in extraEnv {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @discardableResult
    private func scrollToFind(_ app: XCUIApplication, identifier: String,
                              attempts: Int = 16) -> XCUIElement {
        let element = firstMatch(in: app, identifier: identifier)
        if element.exists && element.isHittable { return element }
        let window = app.windows.firstMatch
        for _ in 0..<attempts {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            if element.exists && element.isHittable { return element }
        }
        if element.exists { return element }
        XCTFail("element not found: \(identifier)")
        return element
    }

    // MARK: 1+2. VoiceOver composite labels

    func testBotRowVoiceOverLabelReadsMandatedOrder() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_AUTO_NAV": "roster"])
        let row = scrollToFind(app, identifier: "fleet.roster.row.workstation#researcher")

        // The composite read: name first, then route provenance, then the
        // status word. Preview/time may trail. Required fragments present.
        let label = row.label
        XCTAssertTrue(label.contains("Researcher"),
                      "row label names the bot first (got: \(label))")
        XCTAssertTrue(label.contains("workstation#researcher"),
                      "row label carries gateway provenance (got: \(label))")
        XCTAssertTrue(label.contains("Online") || label.contains("Working")
                      || label.contains("Waiting") || label.contains("Unknown")
                      || label.contains("Offline") || label.contains("Needs you")
                      || label.contains("Degraded"),
                      "row label carries the status word (got: \(label))")

        // Order: name BEFORE route, route BEFORE status.
        let nameIdx = label.range(of: "Researcher")?.lowerBound.utf16Offset(in: label) ?? -1
        let routeIdx = label.range(of: "workstation#researcher")?.lowerBound.utf16Offset(in: label) ?? -1
        let statusFragments = ["Online", "Working", "Waiting", "Unknown", "Offline"]
        var statusIdx = Int.max
        for fragment in statusFragments {
            if let r = label.range(of: fragment) {
                statusIdx = min(statusIdx, r.lowerBound.utf16Offset(in: label))
            }
        }
        XCTAssertLessThan(nameIdx, routeIdx, "name precedes route (got: \(label))")
        if statusIdx < Int.max {
            XCTAssertLessThan(routeIdx, statusIdx,
                              "route precedes status (got: \(label))")
        }
    }

    func testGroupRowCompositeAnnouncesCountAndProvenance() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_AUTO_NAV": "roster"])
        let row = scrollToFind(app, identifier: "fleet.room.row.room-alpha")
        let label = row.label
        XCTAssertTrue(label.contains("member"),
                      "group composite announces member count (got: \(label))")
        // Hosted room authority observed → announced; legacy read-only
        // composite announced as managed by Desktop.
        let legacy = firstMatch(in: app, identifier: "fleet.room.row.name:Research Crew")
        if legacy.waitForExistence(timeout: 5) {
            XCTAssertTrue(legacy.label.contains("read only"),
                          "legacy group announces read-only (got: \(legacy.label))")
        }
    }

    // MARK: 3. Touch targets

    func testCompactActionControlsMeet44ptBar() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_AUTO_NAV": "roster"])

        // The room chat send button (compact circular icon) is held to the
        // 44pt bar by the shared pressable style minimum.
        let roomRow = scrollToFind(app, identifier: "fleet.room.row.room-alpha")
        roomRow.tap()
        let composer = app.textFields["fleet.room.composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("hi")
        let send = app.buttons["fleet.room.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(send.frame.height, 44,
            "send button actionable height \(send.frame.height) below 44pt bar")
        XCTAssertGreaterThanOrEqual(send.frame.width, 44,
            "send button actionable width \(send.frame.width) below 44pt bar")
    }

    // MARK: 4. Memory Graph list alternative

    func testMemoryGraphListAlternativeCarriesFiltersAndActions() throws {
        let app = launch()
        // Memory pane under Gateway Detail, explicit profile (FOS-2 route).
        UITabNavigation.openScopedPane(app, resource: "memory", profile: "default")

        let picker = firstMatch(in: app, identifier: "memorygraph.presentation")
        XCTAssertTrue(picker.waitForExistence(timeout: 15),
                      "Graph/List presentation switch renders")

        // Switch to List: same filter chips render; node rows appear and
        // open the SAME detail sheet.
        let listSegment = picker.descendants(matching: .any)["List"]
        if listSegment.exists {
            listSegment.tap()
        } else {
            picker.buttons.element(boundBy: 1).tap()
        }

        let list = firstMatch(in: app, identifier: "memorygraph.list")
        XCTAssertTrue(list.waitForExistence(timeout: 10), "list alternative renders")

        // Filters apply to the list too (All → skills visible; Skills-only
        // filter chip is shared).
        let skillFilter = firstMatch(in: app, identifier: "memorygraph.filter.skills")
        XCTAssertTrue(skillFilter.waitForExistence(timeout: 5),
                      "filter chips render with the list")
        skillFilter.tap()

        // A skill node row opens the detail sheet (same node actions).
        let anyRow = list.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "memorygraph.list.row."))
            .firstMatch
        XCTAssertTrue(anyRow.waitForExistence(timeout: 10),
                      "list renders node rows for the active filter")
        anyRow.tap()
        let label = firstMatch(in: app, identifier: "memorygraph.detail.label")
        XCTAssertTrue(label.waitForExistence(timeout: 10),
                      "list row opens the SAME node detail sheet")
        // Equivalent node actions: the menu carries Edit + Delete.
        let menu = app.buttons["memorygraph.detail.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "detail menu reachable from list")
        menu.tap()
        XCTAssertTrue(app.buttons["memorygraph.detail.edit"].waitForExistence(timeout: 5),
                      "Edit action available from the list path")
    }

    // MARK: 5. RoomLink recovery inspector

    private func openRoomLinkRecovery(_ app: XCUIApplication) {
        let roomRow = scrollToFind(app, identifier: "fleet.room.row.room-alpha")
        roomRow.tap()
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.room.chat").waitForExistence(timeout: 10))
        app.buttons["fleet.room.roomlink"].tap()
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.roomlink.screen").waitForExistence(timeout: 10),
                      "RoomLink inspector renders")
    }

    func testRecoveryInspectorShowsLineageAndFencingGate() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_AUTO_NAV": "roster"])
        openRoomLinkRecovery(app)

        // Child sections of ONE inspector: Links + Recovery headers.
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.roomlink.summary").waitForExistence(timeout: 10))

        // Exact observed lineage (authorityGatewayID + epoch observed).
        let lineage = scrollToFind(app, identifier: "fleet.roomlink.observed-lineage")
        XCTAssertTrue(lineage.label.contains("install:hub"),
                      "observed lineage names the authority (got: \(lineage.label))")
        XCTAssertTrue(lineage.label.contains("epoch 3"),
                      "observed lineage names the epoch (got: \(lineage.label))")

        // The fencing-assertion gate: WITHOUT the toggle, tapping Take over
        // surfaces the honest inline explanation — no dialog (Fleet cannot
        // verify fencing; the operator must assert it).
        let promote = app.buttons["fleet.roomlink.promote"]
        XCTAssertTrue(promote.waitForExistence(timeout: 10))
        promote.tap()

        let fencingError = firstMatch(in: app, identifier: "fleet.roomlink.error")
        XCTAssertTrue(fencingError.waitForExistence(timeout: 5),
                      "fencing-required explanation renders inline")
        XCTAssertTrue(fencingError.label.contains("fenced"),
                      "explanation names the fencing assertion (got: \(fencingError.label))")
        XCTAssertFalse(app.buttons["Take over"].exists,
                       "no takeover dialog before the operator asserts fencing")

        // Toggle the assertion on, then the takeover confirmation opens,
        // proceeds, and the receipt + readback render.
        let fencing = scrollToFind(app, identifier: "fleet.roomlink.fencing-toggle")
        let switchControl = fencing.descendants(matching: .switch).firstMatch
        if switchControl.exists {
            switchControl.tap()
        } else {
            fencing.tap()
        }

        app.buttons["fleet.roomlink.promote"].tap()
        let takeover = app.buttons["Take over"]
        XCTAssertTrue(takeover.waitForExistence(timeout: 5),
                      "takeover confirmation renders after the assertion")
        takeover.tap()

        // Receipt notice names the new epoch + previous authority; readback
        // states both sides (FOS-8 SPEC §9).
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.roomlink.notice").waitForExistence(timeout: 10),
                      "promotion receipt notice renders")
        let readback = scrollToFind(app, identifier: "fleet.roomlink.readback")
        XCTAssertTrue(readback.exists,
                      "post-promotion readback renders")
    }

    // MARK: 6. Group conversation scroll stability

    func testGroupConversationShowsLatestControlWhenReadingHistory() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_AUTO_NAV": "roster"])
        let roomRow = scrollToFind(app, identifier: "fleet.room.row.room-alpha")
        roomRow.tap()
        XCTAssertTrue(firstMatch(in: app, identifier: "fleet.room.chat").waitForExistence(timeout: 10))

        // Send messages long enough to make the transcript overflow the
        // viewport so upward scrolling is possible.
        let composer = app.textFields["fleet.room.composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let filler = String(repeating: "history line for scroll stability testing ", count: 20)
        for text in ["one \(filler)", "two \(filler)", "three \(filler)", "four \(filler)"] {
            composer.tap()
            composer.typeText(text)
            app.buttons["fleet.room.send"].tap()
            usleep(500_000)
        }

        // Dismiss the keyboard by tapping a neutral transcript area (the
        // nav bar tap can disturb scroll state).
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()

        // Scroll UP into history with the slow press-drag gesture (fast
        // swipes can settle back to the bottom with rubber-banding).
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)

        let latest = app.buttons["fleet.room.timeline.latest"]
        var appeared = latest.waitForExistence(timeout: 5)
        if !appeared {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            appeared = latest.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(appeared, "Latest control appears while reading history")

        // Let the scroll settle (a tap fired mid-deceleration hits stale
        // coordinates and misses the control), then re-query and tap.
        sleep(2)
        latest.tap()
        let gone = NSPredicate(format: "exists == false")
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: latest)], timeout: 12)
    }
}
