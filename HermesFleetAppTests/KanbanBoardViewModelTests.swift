import XCTest
import FleetCore
@testable import FleetUI

/// t_3b321b7b — KanbanBoardViewModel behavior over a scripted watcher:
/// snapshot load, live-event-driven refetch (the core "board updates live"
/// acceptance), recent-event maintenance, and stop semantics.
@MainActor
final class KanbanBoardViewModelTests: XCTestCase {

    func testStartLoadsSnapshotAndConsumesStream() async throws {
        let watcher = ScriptedKanbanWatcherDouble()
        let model = KanbanBoardViewModel(watcher: watcher)
        await model.start()
        defer { Task { await model.stop() } }

        let snapshot = try XCTUnwrap(model.snapshot, "snapshot should load on start")
        XCTAssertEqual(snapshot.totalCards, 1)
        XCTAssertEqual(model.errorMessage, nil)
    }

    func testLiveEventTriggersSnapshotRefetch() async throws {
        let watcher = ScriptedKanbanWatcherDouble()
        let model = KanbanBoardViewModel(watcher: watcher)
        await model.start()
        defer { Task { await model.stop() } }

        // Initial fetch count: 1 (start's snapshot).
        XCTAssertEqual(watcher.snapshotFetchCount, 1)

        // Fire a live event batch; the coalescing window (300ms) then
        // refetches. Poll backstop is 30s so it cannot fire in this window.
        await watcher.emit(
            KanbanChangeEvent(id: 2, taskID: "t_1", kind: "status_changed"))
        // Wait for the coalesced refetch (up to 3s for CI slack).
        for _ in 0..<30 {
            if watcher.snapshotFetchCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThanOrEqual(
            watcher.snapshotFetchCount, 2,
            "a live event must trigger a snapshot refetch")
        XCTAssertGreaterThanOrEqual(model.liveUpdateCount, 1)
        XCTAssertEqual(model.recentEvents.first?.kind, "status_changed")
    }

    func testRecentEventsCapped() async throws {
        let watcher = ScriptedKanbanWatcherDouble()
        let model = KanbanBoardViewModel(watcher: watcher)
        await model.start()
        defer { Task { await model.stop() } }

        for id in 2..<40 {
            await watcher.emit(
                KanbanChangeEvent(id: id, taskID: "t_1", kind: "heartbeat"))
        }
        // Let the coalescing window settle.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThanOrEqual(model.recentEvents.count, 20)
    }

    func testSnapshotErrorSurfacesMessageNotSecrets() async throws {
        let watcher = ScriptedKanbanWatcherDouble()
        watcher.snapshotError = KanbanBoardError.httpStatus(401)
        let model = KanbanBoardViewModel(watcher: watcher)
        await model.start()
        defer { Task { await model.stop() } }

        XCTAssertEqual(model.errorMessage, "kanban board: HTTP 401")
        XCTAssertNil(model.snapshot)
    }

    func testStopEndsStream() async throws {
        let watcher = ScriptedKanbanWatcherDouble()
        let model = KanbanBoardViewModel(watcher: watcher)
        await model.start()
        await model.stop()
        XCTAssertTrue(watcher.stopped, "stop() must reach the watcher")
    }
}

/// Scripted `KanbanBoardWatching` double with an emit handle. Uses a
/// synchronous scoped-lock helper (NSLock is unavailable inside async
/// contexts on this toolchain).
final class ScriptedKanbanWatcherDouble: KanbanBoardWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<KanbanEventBatch>.Continuation] = [:]
    private var _snapshotFetchCount = 0
    private var _snapshotError: Error?
    private var _stopped = false

    var snapshotFetchCount: Int {
        get { locked { _snapshotFetchCount } }
    }
    var snapshotError: Error? {
        get { locked { _snapshotError } }
        set { locked { _snapshotError = newValue } }
    }
    var stopped: Bool {
        get { locked { _stopped } }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func snapshot() async throws -> KanbanBoardSnapshot {
        let thrown = locked { () -> Error? in
            _snapshotFetchCount += 1
            return _snapshotError
        }
        if let thrown { throw thrown }
        return KanbanBoardSnapshot(
            columns: ["todo", "running"],
            cardsByColumn: [
                "todo": [KanbanCard(id: "t_1", title: "Card", status: "todo")],
                "running": [],
            ],
            latestEventID: 1
        )
    }

    func changeEvents() async -> AsyncStream<KanbanEventBatch> {
        let id = UUID()
        return locked {
            AsyncStream { continuation in
                self.continuations[id] = continuation
                continuation.onTermination = { _ in
                    self.locked { self.continuations[id] = nil }
                }
            }
        }
    }

    func emit(_ event: KanbanChangeEvent) async {
        let targets = locked { Array(continuations.values) }
        let batch = KanbanEventBatch(events: [event], cursor: event.id)
        for target in targets { target.yield(batch) }
    }

    func stop() async {
        let targets = locked {
            _stopped = true
            let targets = Array(continuations.values)
            continuations.removeAll()
            return targets
        }
        for target in targets { target.finish() }
    }

    // t_624b81cd: this double predates the selector — honest empties.
    func fetchBoards() async throws -> KanbanBoardList {
        KanbanBoardList(boards: [], current: nil)
    }

    func pinBoard(_ slug: String?) async {}
}
