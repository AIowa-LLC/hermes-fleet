import XCTest

/// TRUE BOTS MODE slice 4 UI tests (D15/D16/D18) against the scripted
/// simulator fleet (deterministic; no live gateway):
/// - D15: open hosted room, transcript render, send, rename, disband tombstone
/// - D16: typed-failure retry surface, needs-you approval, stop
/// - D18: source-qualified member chips; same-name hosted vs legacy rooms
///   stay DISTINCT rows; legacy room is observational only (no composer,
///   "Managed by Hermes Desktop" label, no rename/disband)
/// - D15 create: 2-6 member picker from the gateway roster, frozen-roster wire
///   shape verified in unit tests
final class RoomChatUITests: XCTestCase {

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
        app.launchEnvironment["HERMES_FLEET_AUTO_NAV"] = "roster"
        for (key, value) in extraEnv {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    /// Scroll the roster until an element exists AND is hittable (rows can
    /// sit behind the bottom tab bar; small drags beat full swipes).
    private func scrollToFind(
        _ app: XCUIApplication, identifier: String? = nil, label: String? = nil,
        attempts: Int = 20
    ) -> XCUIElement {
        func found() -> XCUIElement {
            if let identifier {
                return app.descendants(matching: .any)[identifier]
            }
            return app.staticTexts[label ?? ""]
        }
        if found().exists && found().isHittable { return found() }
        let window = app.windows.firstMatch
        for _ in 0..<attempts {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            if found().exists && found().isHittable { return found() }
        }
        for _ in 0..<attempts {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            if found().exists && found().isHittable { return found() }
        }
        if found().exists { return found() }
        XCTFail("element not found: identifier=\(identifier ?? "-") label=\(label ?? "-")")
        return found()
    }

    // MARK: - D15 open + transcript + send

    func testHostedRoomOpenSendAndTranscriptRender() throws {
        let app = launch()

        let row = scrollToFind(app, identifier: "fleet.room.row.room-alpha")
        row.tap()

        // Transcript renders from the durable log (seeded member message).
        let entry = app.descendants(matching: .any)["fleet.room.entry.2"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "seeded transcript entry renders")

        // Source-qualified member chips render (D18): gateway label rides along.
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.member.Researcher"]
                .waitForExistence(timeout: 5),
            "member chip renders")

        // Send a message through the composer.
        let composer = app.textFields["fleet.room.composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "composer renders for capable room")
        composer.tap()
        composer.typeText("Slice four checking in")
        app.buttons["fleet.room.send"].tap()

        // The sent message lands in the transcript (seq advances).
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.entry.3"]
                .waitForExistence(timeout: 10),
            "sent message appears in transcript")
    }

    // MARK: - D15 rename

    func testHostedRoomRename() throws {
        let app = launch()

        scrollToFind(app, identifier: "fleet.room.row.room-alpha").tap()

        let renameButton = app.buttons["fleet.room.rename"]
        XCTAssertTrue(renameButton.waitForExistence(timeout: 10), "rename affordance for capable room")
        renameButton.tap()

        let field = app.textFields["fleet.room.rename.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // Clear the prefilled current name (delete key), then type the new one.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        field.typeText("Renamed Crew")
        app.buttons["fleet.room.rename.submit"].tap()

        // The bold header reflects the rename.
        let renamed = app.staticTexts["Renamed Crew"]
        XCTAssertTrue(
            renamed.waitForExistence(timeout: 10),
            "room header shows the renamed title")
    }

    // MARK: - D15 disband

    func testHostedRoomDisbandShowsTombstone() throws {
        let app = launch()

        scrollToFind(app, identifier: "fleet.room.row.room-alpha").tap()

        let disbandButton = app.buttons["fleet.room.disband"]
        XCTAssertTrue(disbandButton.waitForExistence(timeout: 10), "disband affordance for capable room")
        disbandButton.tap()

        // Destructive confirmation (scope to the alert; the toolbar item
        // shares the "Disband" label).
        let confirm = app.alerts.buttons["Disband"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.disbanded.banner"]
                .waitForExistence(timeout: 10),
            "disbanded tombstone banner renders")
        // Composer disappears once disbanded.
        XCTAssertFalse(
            app.descendants(matching: .any)["fleet.room.composer"]
                .waitForExistence(timeout: 3),
            "composer removed after disband")
    }

    // MARK: - D18 distinctness + legacy observational

    func testLegacyRoomObservationalAndDistinctFromHosted() throws {
        let app = launch()

        // Same-name hosted vs legacy rooms render as DISTINCT rows (D18).
        let hosted = scrollToFind(app, identifier: "fleet.room.row.room-alpha")
        let legacy = scrollToFind(app, identifier: "fleet.room.row.name:Research Crew")
        XCTAssertTrue(hosted.exists && legacy.exists, "both room rows render")

        legacy.tap()

        // Observational banner + read-only composer placeholder.
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.legacy.banner"]
                .waitForExistence(timeout: 10),
            "Managed by Hermes Desktop banner renders")
        // Composer disabled for legacy room (field itself is disabled).
        let composer = app.textFields["fleet.room.composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(composer.isEnabled, "composer disabled for legacy room")

        // No mutation affordances on the legacy room.
        XCTAssertFalse(app.buttons["fleet.room.rename"].exists, "no rename on legacy room")
        XCTAssertFalse(app.buttons["fleet.room.disband"].exists, "no disband on legacy room")
        XCTAssertFalse(app.buttons["fleet.room.stop"].exists, "no stop on legacy room")
    }

    // MARK: - D16 retryable failure

    func testFailureSurfaceWithRetry() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_ROOM_FAILURE": "1"])

        scrollToFind(app, identifier: "fleet.room.row.room-alpha").tap()

        // Typed failure renders with a Retry affordance (capable room).
        let retry = app.buttons["fleet.room.retry-failure"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "retry affordance renders on typed failure")
        retry.tap()

        // The retry is issued (pending action clears; notice renders).
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.notice"]
                .waitForExistence(timeout: 10),
            "notice renders after retry")
    }

    // MARK: - D16 approval

    func testApprovalSurfaceApproveOnce() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_ROOM_APPROVAL": "1"])

        scrollToFind(app, identifier: "fleet.room.row.room-alpha").tap()

        let approve = app.buttons["fleet.room.approve.once"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "needs-you approval renders")
        approve.tap()

        // After approving, the approval card clears.
        XCTAssertFalse(
            app.buttons["fleet.room.approve.once"].waitForExistence(timeout: 5),
            "approval clears after approve-once")
    }

    // MARK: - D15 create room

    func testCreateRoomWithTwoMembers() throws {
        let app = launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.roster.row.workstation#researcher"]
                .waitForExistence(timeout: 10))

        // Manage menu → Create Room — Workstation.
        app.descendants(matching: .any)["fleet.roster.manage"].firstMatch.tap()
        let createRoom = app.buttons["Create Room — Workstation"]
        XCTAssertTrue(createRoom.waitForExistence(timeout: 5), "create-room menu entry renders")
        XCTAssertTrue(createRoom.isEnabled, "create-room enabled on capable gateway")
        createRoom.tap()

        let name = app.textFields["fleet.room.create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "create sheet name field renders")
        name.tap()
        name.typeText("Fresh Crew")

        // Pick two members from the roster candidates (2-6 rule).
        let first = app.buttons["fleet.room.create.candidate.researcher"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), "researcher candidate renders")
        first.tap()
        let second = app.buttons["fleet.room.create.candidate.default"]
        XCTAssertTrue(second.waitForExistence(timeout: 5), "default candidate renders")
        second.tap()

        // Member count reads 2/6.
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.create.member-count"].label
                .contains("2"),
            "member count reflects 2 picks")

        let submit = app.buttons["fleet.room.create.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.tap()

        // The created room reveals in the roster rows.
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.row.room-1"]
                .waitForExistence(timeout: 10),
            "created room appears in roster")
    }
}
