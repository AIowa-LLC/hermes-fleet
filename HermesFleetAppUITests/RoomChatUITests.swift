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

    private func launch(
        extraEnv: [String: String] = [:],
        autoNav: String = "roster",
        resetNavigation: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        self.app = app
        app.launchEnvironment["HERMES_FLEET_AUTO_NAV"] = autoNav
        for (key, value) in extraEnv {
            app.launchEnvironment[key] = value
        }
        if resetNavigation {
            app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        }
        app.launch()
        return app
    }

    /// Scroll the roster until an element exists AND is hittable (rows can
    /// sit behind the bottom tab bar; small drags beat full swipes).
    ///
    /// A row can be present in the AX tree while its frame lies entirely
    /// outside the window (materialized just below the fold). Asking for
    /// `isHittable` on such an element does NOT return false: it fails the
    /// test outright with "Failed to determine hittability … Activation point
    /// invalid and no suggested hit points based on element frame"
    /// (merge-group run 34699513638, shard 5 — same roster geometry this
    /// suite drives). Only consult hittability once the frame actually
    /// overlaps the window; otherwise keep scrolling.
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
        let window = app.windows.firstMatch
        func hittable() -> Bool {
            guard found().exists else { return false }
            let windowFrame = window.frame
            // If the window itself cannot be measured, keep the old behaviour.
            if !windowFrame.isEmpty && !found().frame.intersects(windowFrame) { return false }
            return found().isHittable
        }
        if hittable() { return found() }
        for _ in 0..<attempts {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            if hittable() { return found() }
        }
        for _ in 0..<attempts {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            if hittable() { return found() }
        }
        if found().exists { return found() }
        XCTFail("element not found: identifier=\(identifier ?? "-") label=\(label ?? "-")")
        return found()
    }

    /// RC-84 P1: Group Info — the room toolbar's Info entry opens the
    /// compact known-state sheet (participants / gateways / capabilities)
    /// and it closes cleanly. Values come from the room's real fields; this
    /// pins the surface + honest structure.
    func testRoomInfoSheetShowsHonestGroupState() throws {
        let app = launch()

        let row = scrollToFind(app, identifier: "fleet.room.row.room-alpha")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fleet.room.chat"].waitForExistence(timeout: 10),
                      "room chat must open")

        let info = app.descendants(matching: .any)["fleet.room.info"]
        XCTAssertTrue(info.waitForExistence(timeout: 10),
                      "Group Info entry must render in the room toolbar")
        info.tap()

        let sheet = app.descendants(matching: .any)["fleet.room.info.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Group Info sheet must open")
        XCTAssertTrue(app.staticTexts["Home gateway"].firstMatch.waitForExistence(timeout: 5),
                      "Home gateway row must render")
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.info.capability.send"].waitForExistence(timeout: 5),
            "Send messages capability line must render")
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.info.capability.replay"].exists,
            "every capability line must render (replay may be honest 'Not supported')")

        app.buttons["Done"].firstMatch.tap()
        let gone = NSPredicate(format: "exists == 0")
        XCTAssertTrue(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: sheet)], timeout: 5) == .completed,
            "Group Info sheet must dismiss")
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

    func testHostedRoomShowsWorkingUntilScriptedReply() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_ROOM_REPLY_DELAY_MS": "6000"])
        scrollToFind(app, identifier: "fleet.room.row.room-alpha").tap()
        let composer = app.textFields["fleet.room.composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Investigate this")
        app.buttons["fleet.room.send"].tap()

        let indicator = app.descendants(matching: .any)["fleet.room.work.room"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 5),
                      "an accepted hosted send shows room work")
        XCTAssertTrue(indicator.label.contains("The room is working"))
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: indicator)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed,
                       "the indicator clears after the scripted reply")
        XCTAssertTrue(app.descendants(matching: .any)["fleet.room.entry.4"]
            .waitForExistence(timeout: 10), "the completed reply enters the transcript")
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
        let banner = app.descendants(matching: .any)["fleet.room.legacy.banner"]
        XCTAssertTrue(
            banner.waitForExistence(timeout: 10),
            "Managed by Hermes Desktop banner renders")
        // Build-41 honesty contract (SPEC: legacy read-only state): the
        // banner must state read-only + Desktop management + BOUNDED recent
        // history — never imply the full transcript is available. The notice
        // bar uses .contain (container label is empty — repo lesson), so the
        // copy is asserted on the static text it renders.
        func bannerCopy(_ phrase: String) -> XCUIElement {
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", phrase)
            ).firstMatch
        }
        XCTAssertTrue(
            bannerCopy("Read only").waitForExistence(timeout: 5),
            "banner states read-only")
        XCTAssertTrue(
            bannerCopy("Managed by Hermes Desktop").exists,
            "banner names Hermes Desktop as the managing authority")
        XCTAssertTrue(
            bannerCopy("Recent history only").exists,
            "banner is honest about the bounded history window")
        // The promotion affordance is prominent and fully named.
        XCTAssertEqual(
            app.buttons["fleet.room.legacy.continue"].label,
            "Continue as Interactive Group",
            "banner action is the full Continue-as-Interactive-Group label")
        // Composer disabled for legacy room (field itself is disabled).
        let composer = app.textFields["fleet.room.composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(composer.isEnabled, "composer disabled for legacy room")

        // No mutation affordances on the legacy room.
        XCTAssertFalse(app.buttons["fleet.room.rename"].exists, "no rename on legacy room")
        XCTAssertFalse(app.buttons["fleet.room.disband"].exists, "no disband on legacy room")
        XCTAssertFalse(app.buttons["fleet.room.stop"].exists, "no stop on legacy room")
    }

    // MARK: - Continue as Interactive Group (diagnostic 2026-09-15, fix B)

    func testLegacyRoomContinueActionExplainsWhenNoDurableBridge() throws {
        let app = launch()

        let legacy = scrollToFind(app, identifier: "fleet.room.row.name:Research Crew")
        XCTAssertTrue(legacy.exists, "legacy room row renders")
        legacy.tap()

        // The banner carries the Continue action (fix B affordance).
        let continueButton = app.buttons["fleet.room.legacy.continue"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 10),
            "Continue action renders on the legacy banner")

        // Confirmation copy is explicit about identity + history retention.
        // Scope to the sheet: the banner action now carries the same full
        // "Continue as Interactive Group" label, so an unscoped query
        // matches BOTH the banner button and the dialog confirm.
        continueButton.tap()
        // The dialog confirm may surface as a sheet (compact confirmation
        // dialog) or an alert-style action sheet; accept either surface but
        // REQUIRE it to present (never silently tap the banner button again).
        let confirm = app.sheets.buttons["Continue as Interactive Group"]
        let alertConfirm = app.alerts.buttons["Continue as Interactive Group"]
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 5) || alertConfirm.waitForExistence(timeout: 1),
            "confirmation dialog renders")
        (confirm.exists ? confirm : alertConfirm).tap()

        // The simulator's legacy room is NAME-KEYED (older projection
        // generation): the flow fails closed with the honest no-durable-
        // bridge explanation — never a silent success.
        let errorNotice = app.descendants(matching: .any)["fleet.room.legacy.continue.error"]
        XCTAssertTrue(
            errorNotice.waitForExistence(timeout: 10),
            "typed fail-closed explanation renders")
        XCTAssertTrue(
            errorNotice.label.localizedCaseInsensitiveContains("durable"),
            "explanation names the missing durable identity bridge")
    }

    // MARK: - D16 retryable failure

    func testFailureSurfaceWithRetry() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_ROOM_FAILURE": "1"])

        scrollToFind(app, identifier: "fleet.room.row.room-alpha").tap()

        // Slice 5 (D22): the typed failure card renders PER-TYPE actions for
        // the seeded provider_auth_or_access (attention class) —
        // re-authenticate + open settings, never a plain retry (the wire
        // marks this reason retry:none).
        XCTAssertTrue(
            app.buttons["fleet.room.failure.action.reauthenticate"].waitForExistence(timeout: 10),
            "typed recovery action renders on provider_auth_or_access failure")
        app.buttons["fleet.room.failure.action.reauthenticate"].tap()

        // The typed title and wire badge render (never generic-only).
        XCTAssertTrue(
            app.staticTexts["Needs attention — Provider sign-in needed"].exists,
            "typed attention title renders")
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.failure.wire-badge"].exists,
            "wire badge renders")
    }

    // MARK: - D16 approval

    func testApprovalSurfaceApproveOnce() throws {
        let app = launch(extraEnv: ["HERMES_FLEET_ROOM_APPROVAL": "1"])

        scrollToFind(app, identifier: "fleet.room.row.room-alpha").tap()

        let approve = app.buttons["fleet.room.approve.once"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "needs-you approval renders")
        let waiting = app.descendants(matching: .any)["fleet.room.work.approval"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 5))
        XCTAssertTrue(waiting.label.contains("Waiting for your answer"))
        approve.tap()

        // After approving, the approval card clears.
        XCTAssertFalse(
            app.buttons["fleet.room.approve.once"].waitForExistence(timeout: 5),
            "approval clears after approve-once")
        XCTAssertFalse(waiting.exists, "waiting copy clears with the approval")
    }

    // MARK: - D15 create room

    func testCreateRoomWithTwoMembers() throws {
        let app = launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.roster.row.workstation#researcher"]
                .waitForExistence(timeout: 10))

        // Manage menu → Create Group — Workstation (FOS-5 terminology).
        app.descendants(matching: .any)["fleet.roster.manage"].firstMatch.tap()
        let createRoom = app.buttons["Create Group — Workstation"]
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

        // The created room reveals in the roster rows. The room id is a
        // client-minted UUID (upstream groups.create requires a
        // client-supplied room_id), so the row is found by its name.
        let createdRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Fresh Crew"))
            .firstMatch
        XCTAssertTrue(
            createdRow.waitForExistence(timeout: 10),
            "created room appears in roster")
    }

    // Phone-bridged fallback: the opt-in simulator fixture disables hosted
    // Group/RoomLink seams, forcing AppEnvironment.createRoom to persist a
    // device-local room. The second launch deliberately omits NAV_RESET so
    // the persisted bridged record is the thing being reopened.
    func testPhoneBridgedGroupCreatesOpensSendsAndSurvivesRelaunch() throws {
        let fixture = [
            "HERMES_FLEET_BRIDGED_ROOM": "1",
            "HERMES_FLEET_BRIDGED_REPLY_DELAY_MS": "8000",
        ]
        let app = launch(extraEnv: fixture, autoNav: "groups")

        let newGroup = app.buttons["fleet.groups.new"]
        XCTAssertTrue(newGroup.waitForExistence(timeout: 10), "Groups create control renders")
        newGroup.tap()

        let name = app.textFields["fleet.room.create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "Group create sheet renders")
        name.tap()
        name.typeText("Phone Crew")
        app.buttons["fleet.room.create.candidate.workstation#researcher"].tap()
        app.buttons["fleet.room.create.candidate.workstation#default"].tap()
        app.buttons["fleet.room.create.submit"].tap()

        let composer = app.textFields["fleet.room.composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "bridged room opens after creation")
        XCTAssertFalse(
            app.staticTexts["Gateway unavailable"].exists,
            "device-local room must bypass the registered-gateway guard")
        composer.tap()
        composer.typeText("Bridge check-in")
        app.buttons["fleet.room.send"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["fleet.room.entry.2"]
                .waitForExistence(timeout: 10),
            "bridged user message is persisted in the local transcript")

        let thinking = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "is thinking…"))
        XCTAssertTrue(thinking.element(boundBy: 1).waitForExistence(timeout: 5))
        let thinkingLabels = thinking.allElementsBoundByIndex.map { $0.label }
        XCTAssertEqual(Set(thinkingLabels).count, 2, "each working bot has its own named line")
        XCTAssertTrue(thinkingLabels.contains { $0.contains("Researcher") })

        for seq in [3, 4] {
            let reply = app.descendants(matching: .any)["fleet.room.entry.\(seq)"]
            XCTAssertTrue(reply.waitForExistence(timeout: 15), "each selected bot replies")
            // Rich-text member replies carry the assistant-response AX
            // contract (RoomTranscriptAccessibilityModifier overrides the
            // label); failure notes and user rows COMBINE speaker + copy
            // instead. The contract label is the discriminator that this row
            // is a real member reply, not a timeout/failure note.
            XCTAssertTrue(reply.label.contains("Assistant response from"),
                          "a member reply must not be a timeout/failure note")
        }
        XCTAssertEqual(thinking.count, 0)

        app.terminate()
        self.app = nil
        let relaunched = launch(
            extraEnv: fixture, autoNav: "groups", resetNavigation: false)
        let row = relaunched.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Phone Crew"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "bridged room survives relaunch")
        row.tap()
        XCTAssertTrue(
            relaunched.textFields["fleet.room.composer.field"]
                .waitForExistence(timeout: 10),
            "persisted bridged room opens after relaunch")
        XCTAssertFalse(
            relaunched.staticTexts["Gateway unavailable"].exists,
            "reopened bridged room must not be treated as a missing gateway")
        let restoredReply = relaunched.descendants(matching: .any)["fleet.room.entry.4"]
        XCTAssertTrue(restoredReply.waitForExistence(timeout: 10))
        XCTAssertTrue(restoredReply.label.contains("Assistant response from"),
                      "member transcript survives relaunch")
    }
}
