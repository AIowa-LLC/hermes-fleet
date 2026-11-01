import XCTest
import FleetCore
@testable import FleetUI

/// Refinement Phase 2: timestamp rhythm, home composition presentation, presence labels.
final class RefinementPhase2Tests: XCTestCase {

    private let t0: Double = 1_790_000_000

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func row(
        _ id: String,
        _ kind: ConversationRow.Kind,
        at timestamp: Double?
    ) -> ConversationRow {
        ConversationRow(id: id, kind: kind, text: id, timestamp: timestamp)
    }

    // MARK: - Timestamp rhythm

    func testRunShowsOnlyItsLastTimestamp() {
        let rows = [
            row("user-1", .user, at: t0),
            row("user-2", .user, at: t0 + 60),
            row("assistant-1", .assistant, at: t0 + 120),
            row("assistant-2", .assistant, at: t0 + 150),
        ]
        let marks = ConversationRhythm.marks(for: rows, calendar: utcCalendar())
        XCTAssertEqual(marks.timestampRowIDs, ["user-2", "assistant-2"])
    }

    func testGapOverFiveMinutesSplitsARun() {
        let rows = [
            row("assistant-1", .assistant, at: t0),
            row("assistant-2", .assistant, at: t0 + 301),
        ]
        let marks = ConversationRhythm.marks(for: rows, calendar: utcCalendar())
        XCTAssertTrue(marks.timestampRowIDs.contains("assistant-1"))
        XCTAssertTrue(marks.timestampRowIDs.contains("assistant-2"))
    }

    func testSeparatorOpensTranscriptAndFollowsLongGaps() {
        let rows = [
            row("user-1", .user, at: t0),
            row("assistant-1", .assistant, at: t0 + 60),
            row("user-2", .user, at: t0 + 60 + ConversationRhythm.separatorGap),
        ]
        let marks = ConversationRhythm.marks(for: rows, calendar: utcCalendar())
        XCTAssertEqual(Set(marks.separators.keys), Set(["user-1", "user-2"]))
    }

    func testSeparatorOnDayChange() {
        let calendar = utcCalendar()
        let startOfDay = calendar.startOfDay(for: Date(timeIntervalSince1970: t0))
        let midnight = calendar.date(byAdding: .day, value: 1, to: startOfDay)!.timeIntervalSince1970
        let rows = [
            row("user-1", .user, at: midnight - 60),
            row("user-2", .user, at: midnight + 60),
        ]
        let marks = ConversationRhythm.marks(for: rows, calendar: calendar)
        XCTAssertNotNil(marks.separators["user-2"])
    }

    func testUnstampedRowsGetNoMarks() {
        let rows = [
            row("user-1", .user, at: nil),
            row("assistant-1", .assistant, at: nil),
        ]
        let marks = ConversationRhythm.marks(for: rows, calendar: utcCalendar())
        XCTAssertTrue(marks.timestampRowIDs.isEmpty)
        XCTAssertTrue(marks.separators.isEmpty)
    }

    func testRunEndsBeforeALiveUnstampedRow() {
        let rows = [
            row("assistant-1", .assistant, at: t0),
            row("assistant-live", .assistant, at: nil),
        ]
        let marks = ConversationRhythm.marks(for: rows, calendar: utcCalendar())
        XCTAssertTrue(marks.timestampRowIDs.contains("assistant-1"))
    }

    func testToolRowsDoNotBreakARun() {
        let rows = [
            row("assistant-1", .assistant, at: t0),
            row("tool-1", .tool, at: t0 + 10),
            row("assistant-2", .assistant, at: t0 + 20),
        ]
        let marks = ConversationRhythm.marks(for: rows, calendar: utcCalendar())
        XCTAssertEqual(marks.timestampRowIDs, ["assistant-2"])
    }

    func testSeparatorTextUsesTodayYesterdayAndDates() {
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: t0)

        let today = ConversationRhythm.separatorText(now, now: now, calendar: calendar)
        XCTAssertTrue(today.hasPrefix("Today · "), today)

        let yesterday = ConversationRhythm.separatorText(
            now.addingTimeInterval(-86_400), now: now, calendar: calendar)
        XCTAssertTrue(yesterday.hasPrefix("Yesterday · "), yesterday)

        let older = ConversationRhythm.separatorText(
            now.addingTimeInterval(-40 * 86_400), now: now, calendar: calendar)
        XCTAssertFalse(older.hasPrefix("Today"), older)
        XCTAssertFalse(older.hasPrefix("Yesterday"), older)
        XCTAssertTrue(older.contains(" · "), older)
    }

    // MARK: - Presence labels

    func testPresenceSpokenLabelsAreUnchanged() {
        XCTAssertEqual(ConversationPresenceIndicator.spokenLabel(thinking: true, elapsed: 1), "Thinking")
        XCTAssertEqual(ConversationPresenceIndicator.spokenLabel(thinking: true, elapsed: 5), "Thinking, 5 seconds")
        XCTAssertEqual(ConversationPresenceIndicator.spokenLabel(thinking: false, elapsed: 7), "Working for 7 seconds")
    }

    // MARK: - Home composition

    func testGroupsCountLabel() {
        XCTAssertEqual(FleetHubPresentation.groupsCountLabel(1), "1 group")
        XCTAssertEqual(FleetHubPresentation.groupsCountLabel(3), "3 groups")
    }

    func testLatestRoomLinePicksMostRecentRoomAndSpeaker() {
        let roomA = FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "gw-a"), key: "room-a"),
            name: "Room A",
            recentLog: [
                FleetRoomMessage(
                    id: "a-1",
                    from: FleetRoomMessage.Actor(kind: .member, name: "Researcher"),
                    text: "draft ready",
                    at: 100)
            ])
        let roomB = FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "gw-a"), key: "room-b"),
            name: "Room B",
            recentLog: [
                FleetRoomMessage(
                    id: "b-1",
                    from: FleetRoomMessage.Actor(kind: .member, name: "Default"),
                    text: "shipped",
                    at: 200)
            ])

        let picked = FleetHubPresentation.latestRoomLine([roomA, roomB])
        XCTAssertEqual(picked?.room.name, "Room B")
        XCTAssertEqual(picked?.line, "Default: shipped")

        let userRoom = FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "gw-a"), key: "room-c"),
            name: "Room C",
            recentLog: [
                FleetRoomMessage(
                    id: "c-1",
                    from: FleetRoomMessage.Actor(kind: .user, name: "Tony"),
                    text: "thanks",
                    at: 300)
            ])
        let userPicked = FleetHubPresentation.latestRoomLine([roomA, userRoom])
        XCTAssertEqual(userPicked?.room.name, "Room C")
        XCTAssertTrue(userPicked?.line?.hasPrefix("You: ") ?? false, userPicked?.line ?? "nil")

        XCTAssertNil(FleetHubPresentation.latestRoomLine([]))
    }

    func testMachineDetailNeverRendersUnknownAsZero() {
        let unknown = FleetMachineSummary(
            id: GatewayID(rawValue: "gw-unknown"),
            name: "Workstation",
            stateLabel: "Connected",
            tone: .neutral,
            bots: [],
            knownBotCount: nil,
            isLastKnown: false)
        XCTAssertEqual(unknown.detail, "Bots unknown")

        let empty = FleetMachineSummary(
            id: GatewayID(rawValue: "gw-empty"),
            name: "Workstation",
            stateLabel: "Connected",
            tone: .neutral,
            bots: [],
            knownBotCount: 0,
            isLastKnown: false)
        XCTAssertEqual(empty.detail, "No Bots reported")
    }
}
