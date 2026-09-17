import XCTest
import FleetCore
@testable import FleetUI

/// Build 41 — mutation view-model behavior over a scripted board operator:
/// create/move/assign/priority/comment flows, fail-closed without an
/// operator, running-refusal surfacing, and live-update integrity after
/// mutations.
@MainActor
final class KanbanMutationsViewModelTests: XCTestCase {

    // MARK: Test double

    /// A full board operator with in-memory state + call recording.
    final class RecordingBoardOperator: KanbanBoardOperating, @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [UUID: AsyncStream<KanbanEventBatch>.Continuation] = [:]
        private var _tasks: [String: (title: String, status: String, assignee: String?, priority: Int)] = [
            "t_1": ("First card", "todo", "apple-dev", 1),
            "t_2": ("Second card", "running", "apple-qa", 2),
        ]
        private var _comments: [String: [KanbanComment]] = [:]
        private var _links: [String: KanbanTaskLinks] = [:]
        private var _snapshotFetchCount = 0
        private var _createdDrafts: [KanbanTaskDraft] = []
        private var _patches: [(id: String, patch: KanbanTaskPatch)] = []
        private var _commentBodies: [String] = []
        private var _reclaimed: [String] = []
        private var _reassigned: [(id: String, profile: String?)] = []
        private var _specifyCalls: [String] = []
        private var _decomposeCalls: [String] = []
        private var _bulkPatches: [KanbanBulkPatch] = []
        private var _orchestrationPatches: [KanbanOrchestrationPatch] = []
        private var _dispatchCalls = 0
        private var _nextEvent = 10

        // Observability
        var snapshotFetchCount: Int { lock.withLock { _snapshotFetchCount } }
        var createdDrafts: [KanbanTaskDraft] { lock.withLock { _createdDrafts } }
        var patches: [(id: String, patch: KanbanTaskPatch)] { lock.withLock { _patches } }
        var commentBodies: [String] { lock.withLock { _commentBodies } }
        var reclaimed: [String] { lock.withLock { _reclaimed } }
        var reassigned: [(id: String, profile: String?)] { lock.withLock { _reassigned } }
        var specifyCalls: [String] { lock.withLock { _specifyCalls } }
        var decomposeCalls: [String] { lock.withLock { _decomposeCalls } }
        var bulkPatches: [KanbanBulkPatch] { lock.withLock { _bulkPatches } }
        var orchestrationPatches: [KanbanOrchestrationPatch] { lock.withLock { _orchestrationPatches } }
        var dispatchCalls: Int { lock.withLock { _dispatchCalls } }
        var taskStatuses: [String: String] {
            lock.withLock { _tasks.mapValues { $0.status } }
        }

        // MARK: KanbanBoardWatching

        func fetchBoards() async throws -> KanbanBoardList {
            KanbanBoardList(
                boards: [KanbanBoardSummary(slug: "b", name: "Board", isCurrent: true, total: 2)],
                current: "b")
        }

        func pinBoard(_ slug: String?) async {}

        private func snapshotFromState() -> KanbanBoardSnapshot {
            lock.withLock {
                var byColumn: [String: [KanbanCard]] = [
                    "triage": [], "todo": [], "ready": [], "running": [],
                    "blocked": [], "review": [], "done": [],
                ]
                for (id, task) in _tasks.sorted(by: { $0.value.priority > $1.value.priority }) {
                    byColumn[task.status]?.append(KanbanCard(
                        id: id, title: task.title, status: task.status,
                        assignee: task.assignee, priority: task.priority,
                        createdAt: 1_780_000_000, latestSummary: nil))
                }
                return KanbanBoardSnapshot(
                    columns: ["triage", "todo", "ready", "running", "blocked", "review", "done"],
                    cardsByColumn: byColumn, latestEventID: _nextEvent, now: nil)
            }
        }

        func snapshot() async throws -> KanbanBoardSnapshot {
            lock.withLock { _snapshotFetchCount += 1 }
            return snapshotFromState()
        }

        func snapshot(includeArchived: Bool) async throws -> KanbanBoardSnapshot {
            try await snapshot()
        }

        func changeEvents() async -> AsyncStream<KanbanEventBatch> {
            let id = UUID()
            return AsyncStream { continuation in
                lock.lock()
                continuations[id] = continuation
                lock.unlock()
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.lock.lock()
                    self.continuations[id] = nil
                    self.lock.unlock()
                }
            }
        }

        func stop() async {
            let targets = lock.withLock { () -> [AsyncStream<KanbanEventBatch>.Continuation] in
                let targets = Array(continuations.values)
                continuations.removeAll()
                return targets
            }
            for target in targets { target.finish() }
        }

        private func notify(_ taskID: String, _ kind: String) {
            lock.lock()
            _nextEvent += 1
            let event = KanbanChangeEvent(id: _nextEvent, taskID: taskID, kind: kind, createdAt: nil)
            let targets = Array(continuations.values)
            lock.unlock()
            for target in targets {
                target.yield(KanbanEventBatch(events: [event], cursor: _nextEvent))
            }
        }

        // MARK: KanbanBoardOperating

        func createTask(_ draft: KanbanTaskDraft) async throws -> KanbanCard {
            let card: KanbanCard = lock.withLock {
                _createdDrafts.append(draft)
                let id = "t_new_\(_createdDrafts.count)"
                _tasks[id] = (draft.title, draft.triage ? "triage" : "todo", draft.assignee, draft.priority)
                return KanbanCard(id: id, title: draft.title, status: draft.triage ? "triage" : "todo",
                                  assignee: draft.assignee, priority: draft.priority,
                                  createdAt: 1_780_000_000, latestSummary: nil)
            }
            return card
        }

        func updateTask(id: String, patch: KanbanTaskPatch) async throws -> KanbanCard {
            try lock.withLock {
                _patches.append((id, patch))
                guard var task = _tasks[id] else {
                    throw KanbanMutationError.rejected("task \(id) not found")
                }
                if let status = patch.status {
                    if status == "running" {
                        throw KanbanMutationError.rejected(
                            "Cannot set status to 'running' directly; use the dispatcher/claim path")
                    }
                    task.status = status
                }
                if let assignee = patch.assignee {
                    task.assignee = assignee.isEmpty ? nil : assignee
                }
                if let priority = patch.priority { task.priority = priority }
                if let title = patch.title { task.title = title }
                _tasks[id] = task
                return KanbanCard(id: id, title: task.title, status: task.status,
                                  assignee: task.assignee, priority: task.priority,
                                  createdAt: 1_780_000_000, latestSummary: nil)
            }
        }

        func deleteTask(id: String) async throws {
            lock.withLock { _tasks.removeValue(forKey: id) }
        }

        func fetchTaskDetail(id: String) async throws -> KanbanTaskDetail {
            let task = try lock.withLock { () -> (String, String, String?, Int) in
                guard let t = _tasks[id] else { throw KanbanMutationError.rejected("not found") }
                return (t.title, t.status, t.assignee, t.priority)
            }
            return KanbanTaskDetail(
                task: KanbanTaskRecord(
                    id: id, title: task.0, body: "Body", assignee: task.2,
                    status: task.1, priority: task.3, createdAt: 1_780_000_000),
                comments: lock.withLock { _comments[id] ?? [] },
                events: [],
                links: lock.withLock { _links[id] ?? KanbanTaskLinks() },
                childResults: [],
                runs: [])
        }

        func addComment(taskID: String, body: String, author: String?) async throws {
            try lock.withLock {
                guard _tasks[taskID] != nil else {
                    throw KanbanMutationError.rejected("task \(taskID) not found")
                }
                _commentBodies.append(body)
                var list = _comments[taskID] ?? []
                list.append(KanbanComment(id: list.count + 1, taskID: taskID,
                                          author: author ?? "dashboard", body: body,
                                          createdAt: 1_780_000_100))
                _comments[taskID] = list
            }
            notify(taskID, "commented")
        }

        func linkTasks(parentID: String, childID: String) async throws -> Bool {
            lock.withLock {
                var parentLinks = _links[parentID] ?? KanbanTaskLinks()
                _links[parentID] = KanbanTaskLinks(
                    parents: parentLinks.parents, children: parentLinks.children + [childID])
                return true
            }
        }

        func unlinkTasks(parentID: String, childID: String) async throws {
            lock.withLock {
                var parentLinks = _links[parentID] ?? KanbanTaskLinks()
                _links[parentID] = KanbanTaskLinks(
                    parents: parentLinks.parents,
                    children: parentLinks.children.filter { $0 != childID })
            }
        }

        func bulkUpdate(_ patch: KanbanBulkPatch) async throws -> [KanbanBulkOutcome] {
            lock.withLock { _bulkPatches.append(patch) }
            var outcomes: [KanbanBulkOutcome] = []
            for id in patch.ids {
                do {
                    _ = try await updateTask(id: id, patch: KanbanTaskPatch(
                        status: patch.status, assignee: patch.assignee, priority: patch.priority))
                    outcomes.append(KanbanBulkOutcome(id: id, ok: true))
                } catch {
                    outcomes.append(KanbanBulkOutcome(id: id, ok: false, error: String(describing: error)))
                }
            }
            return outcomes
        }

        func reclaimTask(id: String, reason: String?) async throws {
            let exists = lock.withLock { () -> Bool in
                _reclaimed.append(id)
                guard _tasks[id] != nil else { return false }
                _tasks[id]?.status = "ready"
                return true
            }
            if !exists { throw KanbanMutationError.rejected("cannot reclaim \(id)") }
        }

        func specifyTask(id: String, author: String?) async throws -> KanbanSpecifyOutcome {
            lock.withLock { _specifyCalls.append(id) }
            return KanbanSpecifyOutcome(ok: true, taskID: id, reason: nil, newTitle: "Specified title")
        }

        func decomposeTask(id: String, author: String?) async throws -> KanbanDecomposeOutcome {
            lock.withLock { _decomposeCalls.append(id) }
            return KanbanDecomposeOutcome(
                ok: true, taskID: id, reason: nil, fanout: true,
                childIDs: ["t_c1", "t_c2"], newTitle: nil)
        }

        func reassignTask(id: String, profile: String?, reclaimFirst: Bool, reason: String?) async throws {
            lock.withLock {
                _reassigned.append((id, profile))
                _tasks[id]?.assignee = profile
            }
        }

        func fetchAssignees() async throws -> [String] {
            ["apple-dev", "apple-qa", "default"]
        }

        func orchestrationSettings() async throws -> KanbanOrchestrationSettings {
            KanbanOrchestrationSettings(
                orchestratorProfile: "apple-dev", defaultAssignee: nil,
                autoDecompose: true, autoPromoteChildren: true,
                resolvedOrchestratorProfile: "apple-dev", resolvedDefaultAssignee: "apple-dev",
                activeProfile: "apple-dev")
        }

        func updateOrchestrationSettings(_ patch: KanbanOrchestrationPatch) async throws -> KanbanOrchestrationSettings {
            lock.withLock { _orchestrationPatches.append(patch) }
            return try await orchestrationSettings()
        }

        func dispatchNudge(dryRun: Bool, max: Int) async throws -> KanbanDispatchResult {
            lock.withLock { _dispatchCalls += 1 }
            return KanbanDispatchResult(
                reclaimed: 0, promoted: 1,
                spawned: [KanbanDispatchResult.Spawned(
                    taskID: "t_1", assignee: "apple-dev", workspacePath: "/tmp/w")],
                skippedUnassigned: [], skippedPerProfileCapped: [],
                crashed: [], autoBlocked: [], timedOut: [], stale: [],
                rateLimited: [], skippedLocked: false, memoryPressure: nil)
        }
    }

    // MARK: Tests

    func testCreateTaskSendsDraftAndRefetchesSnapshot() async throws {
        let op = RecordingBoardOperator()
        let model = KanbanBoardViewModel(watcher: op, boardOperator: op)
        await model.start()
        defer { Task { await model.stop() } }

        let before = op.snapshotFetchCount
        let created = try await model.createTask(
            KanbanTaskDraft(title: "New work", assignee: "apple-dev", priority: 2))
        XCTAssertEqual(created?.title, "New work")
        XCTAssertEqual(op.createdDrafts.count, 1)
        XCTAssertEqual(op.createdDrafts.first?.assignee, "apple-dev")
        // The mutation triggers an immediate refetch (not just the tail).
        XCTAssertGreaterThan(op.snapshotFetchCount, before)
        // And the new card is on the board.
        XCTAssertTrue(model.snapshot?.totalCards ?? 0 >= 3)
    }

    func testMoveTaskRejectsRunningWithServerMessage() async throws {
        let op = RecordingBoardOperator()
        let model = KanbanBoardViewModel(watcher: op, boardOperator: op)
        await model.start()
        defer { Task { await model.stop() } }

        await model.moveTask(id: "t_1", to: "running")
        XCTAssertNotNil(
            model.mutationErrorMessage,
            "a running move must surface the server's refusal")
        XCTAssertTrue(
            model.mutationErrorMessage?.contains("running") ?? false,
            "the refusal must carry the server's user-facing copy (got: \(model.mutationErrorMessage ?? ""))")
        XCTAssertEqual(op.taskStatuses["t_1"], "todo", "the refused move must not change status")
    }

    func testAssignAndPriorityRideOnePatch() async throws {
        let op = RecordingBoardOperator()
        let model = KanbanBoardViewModel(watcher: op, boardOperator: op)
        await model.start()
        defer { Task { await model.stop() } }

        await model.updateTask(
            id: "t_1",
            patch: KanbanTaskPatch(assignee: "apple-qa", priority: 5))
        XCTAssertEqual(op.patches.count, 1)
        XCTAssertEqual(op.patches.first?.patch.assignee, "apple-qa")
        XCTAssertEqual(op.patches.first?.patch.priority, 5)
        XCTAssertNil(model.mutationErrorMessage)
    }

    func testEmptyAssigneeUnassigns() async throws {
        let op = RecordingBoardOperator()
        let model = KanbanBoardViewModel(watcher: op, boardOperator: op)
        await model.start()
        defer { Task { await model.stop() } }

        await model.updateTask(id: "t_1", patch: KanbanTaskPatch(assignee: ""))
        XCTAssertEqual(op.patches.first?.patch.assignee, "")
    }

    func testCommentPersistsAndRefetches() async throws {
        let op = RecordingBoardOperator()
        let model = KanbanBoardViewModel(watcher: op, boardOperator: op)
        await model.start()
        defer { Task { await model.stop() } }

        let posted = await model.addComment(taskID: "t_1", body: "Looks good")
        XCTAssertTrue(posted, "a confirmed write must report success")
        XCTAssertEqual(op.commentBodies, ["Looks good"])
        XCTAssertNil(model.mutationErrorMessage)
        // The scripted notify drove a live refetch too.
        try await waitFor { op.snapshotFetchCount >= 3 }
    }

    /// A refused comment write reports failure and surfaces the reason — the
    /// detail composer gates its local echo (clear + reveal) on this Bool, so
    /// a failed comment can never look posted.
    func testRefusedCommentReportsFailureAndKeepsError() async throws {
        let op = RecordingBoardOperator()
        let model = KanbanBoardViewModel(watcher: op, boardOperator: op)
        await model.start()
        defer { Task { await model.stop() } }

        let posted = await model.addComment(taskID: "t_missing", body: "nope")
        XCTAssertFalse(posted, "a refused write must report failure")
        XCTAssertNotNil(model.mutationErrorMessage,
                        "the refusal reason must be surfaced for the retry")
        XCTAssertTrue(op.commentBodies.isEmpty,
                      "a refused write must not record a comment body")

        let retried = await model.addComment(taskID: "t_1", body: "nope")
        XCTAssertTrue(retried, "a retry against a real card must succeed")
        XCTAssertNil(model.mutationErrorMessage, "success clears the refusal")
    }

    func testReclaimReassignSpecifyDecomposeDispatchAllReachTheOperator() async throws {
        let op = RecordingBoardOperator()
        let model = KanbanBoardViewModel(watcher: op, boardOperator: op)
        await model.start()
        defer { Task { await model.stop() } }

        await model.reclaimTask(id: "t_2", reason: "stale")
        await model.reassignTask(id: "t_2", profile: "default", reclaimFirst: false, reason: nil)
        await model.specifyTask(id: "t_1")
        await model.decomposeTask(id: "t_1")
        await model.dispatchNudge()

        XCTAssertEqual(op.reclaimed, ["t_2"])
        XCTAssertEqual(op.reassigned.map(\.profile), ["default"])
        XCTAssertEqual(op.specifyCalls, ["t_1"])
        XCTAssertEqual(op.decomposeCalls, ["t_1"])
        XCTAssertEqual(op.dispatchCalls, 1)
        XCTAssertNil(model.mutationErrorMessage)
    }

    func testBulkUpdateReportsPerIdOutcomes() async throws {
        let op = RecordingBoardOperator()
        let model = KanbanBoardViewModel(watcher: op, boardOperator: op)
        await model.start()
        defer { Task { await model.stop() } }

        let outcomes = await model.bulkUpdate(
            KanbanBulkPatch(ids: ["t_1", "t_404"], status: "done"))
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.first { $0.id == "t_1" }?.ok ?? false)
        XCTAssertFalse(outcomes.first { $0.id == "t_404" }?.ok ?? true)
    }

    func testOrchestrationRoundTrip() async throws {
        let op = RecordingBoardOperator()
        let model = KanbanBoardViewModel(watcher: op, boardOperator: op)
        await model.start()
        defer { Task { await model.stop() } }

        let loaded = try await model.orchestrationSettings()
        XCTAssertEqual(loaded?.orchestratorProfile, "apple-dev")
        await model.updateOrchestrationSettings(
            KanbanOrchestrationPatch(orchestratorProfile: "default"))
        XCTAssertEqual(op.orchestrationPatches.count, 1)
        XCTAssertEqual(op.orchestrationPatches.first?.orchestratorProfile, "default")
    }

    func testFiltersNarrowColumns() async throws {
        let op = RecordingBoardOperator()
        let model = KanbanBoardViewModel(watcher: op, boardOperator: op)
        await model.start()
        defer { Task { await model.stop() } }

        XCTAssertEqual(model.filteredSnapshot?.totalCards ?? 0, 2)
        model.filterText = "first"
        XCTAssertEqual(model.filteredSnapshot?.totalCards ?? 0, 1)
        model.filterText = ""
        model.filterAssignee = "apple-qa"
        XCTAssertEqual(model.filteredSnapshot?.totalCards ?? 0, 1)
        model.filterAssignee = nil
        XCTAssertEqual(model.filteredSnapshot?.totalCards ?? 0, 2)
    }

    func testNoOperatorMeansFailClosedMutations() async throws {
        let op = RecordingBoardOperator()
        let model = KanbanBoardViewModel(watcher: op, boardOperator: nil)
        await model.start()
        defer { Task { await model.stop() } }

        XCTAssertFalse(model.canMutate)
        let created = try await model.createTask(KanbanTaskDraft(title: "x"))
        XCTAssertNil(created)
        XCTAssertEqual(op.createdDrafts.count, 0, "no operator → no wire call")
        await model.moveTask(id: "t_1", to: "done")
        XCTAssertEqual(op.patches.count, 0)
        XCTAssertEqual(
            model.mutationErrorMessage, "This gateway's board is read-only.")
    }

    func testLiveEventsAfterMutationStillUpdateBoard() async throws {
        let op = RecordingBoardOperator()
        let model = KanbanBoardViewModel(watcher: op, boardOperator: op)
        await model.start()
        defer { Task { await model.stop() } }

        let liveBefore = model.liveUpdateCount
        try await op.addComment(taskID: "t_1", body: "live", author: nil)  // notifies via stream
        try await waitFor { model.liveUpdateCount > liveBefore }
        XCTAssertGreaterThan(model.liveUpdateCount, liveBefore,
                             "a live event after a mutation must still drive a refetch")
    }

    // MARK: Helpers

    private func waitFor(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 3,
        label: String = "condition"
    ) async throws {
        for _ in 0..<Int(timeout * 10) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for \(label)")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
