import XCTest
@testable import FleetCore

/// OCR kanban findings — tolerant wire decoding for the mutation/aux VALUE
/// paths: the specify/decompose outcomes and the task-detail bundle carry
/// server sections the client must render as DATA (a refusal reason) or as
/// EMPTY (an absent section), never as a hard decode failure.
final class KanbanMutationDecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: Specify outcome — wire key

    /// `task_id` is the wire key: the plugin's specify endpoint returns it
    /// (`plugin_api.py`) and the sibling `KanbanDecomposeOutcome` maps it the
    /// same way. The old `task_task` mapping silently decoded `taskID == nil`
    /// for every response.
    func testSpecifyOutcomeReadsWireTaskID() throws {
        let outcome = try decode(
            KanbanSpecifyOutcome.self,
            #"{"ok":false,"task_id":"t_1","reason":"specifier unavailable","new_title":null}"#)
        XCTAssertEqual(outcome.taskID, "t_1")
        XCTAssertEqual(outcome.reason, "specifier unavailable")
    }

    // MARK: Decompose outcome — the value path survives a partial payload

    func testDecomposeNonOkWithoutFanoutKeysKeepsReason() throws {
        let outcome = try decode(
            KanbanDecomposeOutcome.self,
            #"{"ok":false,"task_id":"t_1","reason":"decomposer unavailable"}"#)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.taskID, "t_1")
        XCTAssertEqual(outcome.reason, "decomposer unavailable")
        XCTAssertFalse(outcome.fanout, "an absent fanout reads as false")
        XCTAssertTrue(outcome.childIDs.isEmpty)
    }

    func testDecomposeNullFanoutAndChildrenDecodeAsEmpty() throws {
        let outcome = try decode(
            KanbanDecomposeOutcome.self,
            #"{"ok":true,"task_id":"t_1","reason":null,"fanout":null,"child_ids":null,"new_title":null}"#)
        XCTAssertTrue(outcome.ok)
        XCTAssertFalse(outcome.fanout)
        XCTAssertTrue(outcome.childIDs.isEmpty)
    }

    func testDecomposeFullPayloadStillDecodes() throws {
        let outcome = try decode(
            KanbanDecomposeOutcome.self,
            #"{"ok":true,"task_id":"t_1","reason":null,"fanout":true,"child_ids":["t_2","t_3"],"new_title":"Split"}"#)
        XCTAssertTrue(outcome.fanout)
        XCTAssertEqual(outcome.childIDs, ["t_2", "t_3"])
        XCTAssertEqual(outcome.newTitle, "Split")
    }

    func testDecomposeWithoutOkStillThrows() {
        // `ok` is the value/error discriminator — it stays required.
        XCTAssertThrowsError(try decode(KanbanDecomposeOutcome.self, #"{"reason":"x"}"#))
    }

    // MARK: Task detail — every section is optional, `task` is not

    func testDetailWithoutSectionsDecodesAsEmpty() throws {
        let detail = try decode(KanbanTaskDetail.self, #"{"task":{"id":"t_1","title":"Bare"}}"#)
        XCTAssertEqual(detail.task.id, "t_1")
        XCTAssertTrue(detail.comments.isEmpty)
        XCTAssertTrue(detail.events.isEmpty)
        XCTAssertTrue(detail.links.parents.isEmpty)
        XCTAssertTrue(detail.links.children.isEmpty)
        XCTAssertTrue(detail.childResults.isEmpty)
        XCTAssertTrue(detail.runs.isEmpty)
    }

    func testDetailWithNullSectionsDecodesAsEmpty() throws {
        let detail = try decode(
            KanbanTaskDetail.self,
            #"{"task":{"id":"t_1"},"comments":null,"events":null,"links":null,"child_results":null,"runs":null}"#)
        XCTAssertEqual(detail.task.id, "t_1")
        XCTAssertTrue(detail.comments.isEmpty)
        XCTAssertTrue(detail.events.isEmpty)
        XCTAssertTrue(detail.links.children.isEmpty)
        XCTAssertTrue(detail.childResults.isEmpty)
        XCTAssertTrue(detail.runs.isEmpty)
    }

    func testDetailWithSectionsStillDecodes() throws {
        let detail = try decode(
            KanbanTaskDetail.self,
            #"{"task":{"id":"t_1","title":"Full","status":"running"},"comments":[{"id":1,"task_id":"t_1","author":"dashboard","body":"hi","created_at":1788366100}],"events":[{"id":9,"task_id":"t_1","run_id":null,"kind":"status","created_at":1788366200}],"links":{"parents":["t_0"],"children":["t_2"]},"child_results":[{"id":"t_2","title":"Child","status":"done","latest_summary":"ok","result":null}],"runs":[{"id":4,"task_id":"t_1","profile":"apple-dev","status":"running","started_at":1788366000,"ended_at":null,"outcome":null,"summary":"working","error":null,"worker_pid":123}]}"#)
        XCTAssertEqual(detail.task.status, "running")
        XCTAssertEqual(detail.comments.first?.body, "hi")
        XCTAssertEqual(detail.events.first?.kind, "status")
        XCTAssertEqual(detail.links.parents, ["t_0"])
        XCTAssertEqual(detail.links.children, ["t_2"])
        XCTAssertEqual(detail.childResults.first?.id, "t_2")
        XCTAssertEqual(detail.runs.first?.workerPID, 123)
    }

    func testDetailWithoutTaskStillThrows() {
        // The bundle's subject is required — a payload with no task is
        // genuinely malformed and must still surface as such.
        XCTAssertThrowsError(try decode(KanbanTaskDetail.self, #"{"comments":[]}"#))
    }
}