import XCTest
@testable import FleetCore

/// t_624b81cd (B1) — board-selector domain tests: `KanbanBoardSummary`
/// decode from a recorded `GET /boards` payload (wire shape verified against
/// `plugins/kanban/dashboard/plugin_api.py` 2026-09-05) and the
/// per-device selection store contract.
final class KanbanBoardSelectorDomainTests: XCTestCase {

    // Recorded /boards fixture (fields trimmed to the ones the app reads;
    // unknown fields like counts/default_workspace_kind must be ignored).
    private static let boardsFixture = """
    {
      "boards": [
        {"slug": "hermes-fleet-r10", "name": "Hermes Fleet R10", "is_current": true,
         "counts": {"todo": 4, "done": 9}, "total": 13,
         "default_workspace_kind": "worktree", "project_id": null, "project_name": null},
        {"slug": "default", "name": "Default", "is_current": false,
         "counts": {}, "total": 0,
         "default_workspace_kind": "scratch", "project_id": null, "project_name": null}
      ],
      "current": "hermes-fleet-r10"
    }
    """

    func testDecodeBoardsFixture() throws {
        let data = Data(Self.boardsFixture.utf8)
        let list = try JSONDecoder().decode(KanbanBoardList.self, from: data)
        XCTAssertEqual(list.current, "hermes-fleet-r10")
        XCTAssertEqual(list.boards.count, 2)

        let first = try XCTUnwrap(list.boards.first)
        XCTAssertEqual(first.slug, "hermes-fleet-r10")
        XCTAssertEqual(first.name, "Hermes Fleet R10")
        XCTAssertEqual(first.isCurrent, true)
        XCTAssertEqual(first.total, 13)

        let second = try XCTUnwrap(list.boards.last)
        XCTAssertEqual(second.slug, "default")
        XCTAssertEqual(second.isCurrent, false)
        XCTAssertEqual(second.total, 0)
    }

    func testSummaryIdentityIsSlug() {
        let summary = KanbanBoardSummary(slug: "s", name: "S", isCurrent: false)
        XCTAssertEqual(summary.id, "s")
        XCTAssertEqual(
            summary,
            KanbanBoardSummary(slug: "s", name: "S", isCurrent: false, total: nil))
    }

    func testDecodeToleratesMissingOptionalFields() throws {
        let minimal = #"{"boards":[{"slug":"only","name":"Only","is_current":true}],"current":"only"}"#
        let list = try JSONDecoder().decode(
            KanbanBoardList.self, from: Data(minimal.utf8))
        XCTAssertEqual(list.boards.count, 1)
        XCTAssertNil(list.boards[0].total)
        // `current` absent entirely is tolerated too.
        let noCurrent = #"{"boards":[]}"#
        let empty = try JSONDecoder().decode(
            KanbanBoardList.self, from: Data(noCurrent.utf8))
        XCTAssertNil(empty.current)
        XCTAssertTrue(empty.boards.isEmpty)
    }
}
