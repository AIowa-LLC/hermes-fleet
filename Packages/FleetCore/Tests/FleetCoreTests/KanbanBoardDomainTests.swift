import XCTest
@testable import FleetCore

/// t_3b321b7b — kanban board domain tests.
final class KanbanBoardDomainTests: XCTestCase {

    // MARK: Snapshot

    func testTotalCardsSumsAcrossColumns() {
        let snapshot = KanbanBoardSnapshot(
            columns: ["todo", "done"],
            cardsByColumn: [
                "todo": [
                    KanbanCard(id: "t_1", title: "One", status: "todo"),
                    KanbanCard(id: "t_2", title: "Two", status: "todo"),
                ],
                "done": [
                    KanbanCard(id: "t_3", title: "Three", status: "done"),
                ],
            ],
            latestEventID: 7
        )
        XCTAssertEqual(snapshot.totalCards, 3)
        XCTAssertEqual(snapshot.cards(in: "todo").count, 2)
        XCTAssertEqual(snapshot.cards(in: "done").count, 1)
    }

    func testUnknownColumnIsEmptyNotCrash() {
        let snapshot = KanbanBoardSnapshot(
            columns: ["todo"], cardsByColumn: ["todo": []], latestEventID: 0)
        XCTAssertTrue(snapshot.cards(in: "nonexistent").isEmpty)
        XCTAssertEqual(snapshot.totalCards, 0)
    }

    // MARK: Errors are non-secret

    func testErrorDescriptionsCarryNoSecrets() {
        XCTAssertEqual(KanbanBoardError.httpStatus(401).errorDescription, "kanban board: HTTP 401")
        XCTAssertEqual(
            KanbanBoardError.malformedResponse("board decode failed").errorDescription,
            "kanban board: malformed response (board decode failed)")
        XCTAssertEqual(
            KanbanBoardError.streamDropped("socket receive failed").errorDescription,
            "kanban event stream dropped: socket receive failed")
    }
}
