import XCTest
import FleetCore
@testable import FleetUI

/// t_624b81cd (B1) — board-selector view model behavior: boards list load,
/// active-board fallback for unknown persisted slugs, re-targeting on
/// selectBoard (pin + snapshot refetch + stream reopen), and per-device
/// persistence via the UserDefaults-backed store.
@MainActor
final class KanbanBoardSelectorViewModelTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUpWithError() throws {
        suite = UserDefaults(suiteName: "kanban-selector-vm-tests")
        suite.removePersistentDomain(forName: "kanban-selector-vm-tests")
    }

    private func makeStore() -> KanbanBoardSelectionStore {
        KanbanBoardSelectionStore(defaults: suite)
    }

    // MARK: Boards list

    func testStartLoadsBoardsAndFallsBackToActiveForUnknownPersistedSlug() async throws {
        let watcher = SelectorWatcherDouble()
        watcher.boards = KanbanBoardList(
            boards: [
                KanbanBoardSummary(slug: "r10", name: "R10", isCurrent: true, total: 3),
                KanbanBoardSummary(slug: "side", name: "Side", isCurrent: false, total: 1),
            ],
            current: "r10")
        // A persisted slug the gateway no longer has → fall back to active.
        makeStore().saveSelectedBoard("ghost-board")
        let model = KanbanBoardViewModel(watcher: watcher, selectionStore: makeStore())
        await model.start()
        defer { Task { await model.stop() } }

        XCTAssertEqual(model.boards.map(\.slug), ["r10", "side"])
        XCTAssertNil(model.selectedBoard, "unknown persisted slug must fall back to the active board")
        XCTAssertEqual(model.displayBoardName, "R10")
    }

    func testStartRestoresKnownPersistedSelection() async throws {
        let watcher = SelectorWatcherDouble()
        watcher.boards = KanbanBoardList(
            boards: [
                KanbanBoardSummary(slug: "r10", name: "R10", isCurrent: true, total: 3),
                KanbanBoardSummary(slug: "side", name: "Side", isCurrent: false, total: 1),
            ],
            current: "r10")
        makeStore().saveSelectedBoard("side")
        let model = KanbanBoardViewModel(watcher: watcher, selectionStore: makeStore())
        await model.start()
        defer { Task { await model.stop() } }

        XCTAssertEqual(model.selectedBoard, "side")
        XCTAssertEqual(model.displayBoardName, "Side")
        XCTAssertEqual(watcher.pinnedSlugs.first, "side", "start must pin the persisted selection before the first snapshot")
    }

    // MARK: Switching

    func testSelectBoardPinsRefetchesAndReopensStream() async throws {
        let watcher = SelectorWatcherDouble()
        watcher.boards = KanbanBoardList(
            boards: [
                KanbanBoardSummary(slug: "r10", name: "R10", isCurrent: true, total: 3),
                KanbanBoardSummary(slug: "side", name: "Side", isCurrent: false, total: 1),
            ],
            current: "r10")
        let model = KanbanBoardViewModel(watcher: watcher, selectionStore: makeStore())
        await model.start()
        defer { Task { await model.stop() } }

        let fetchesBefore = watcher.snapshotFetchCount
        await model.selectBoard("side")

        XCTAssertEqual(model.selectedBoard, "side")
        XCTAssertEqual(watcher.pinnedSlugs.last, "side", "selectBoard must pin the watcher")
        XCTAssertGreaterThanOrEqual(
            watcher.snapshotFetchCount, fetchesBefore + 1,
            "selectBoard must refetch the snapshot for the new board")
        XCTAssertEqual(watcher.snapshotBoards.last, "side", "the refetch must target the new board")
        XCTAssertGreaterThanOrEqual(
            watcher.changeEventsCalls, 2,
            "selectBoard must re-open the event stream (new socket, board pinned at handshake)")
        XCTAssertEqual(model.streamPhase, .streaming, "the reopened stream must go live")
        XCTAssertEqual(watcher.stopped, false, "switching boards must NOT stop the watcher (stop is terminal)")
    }

    func testSelectBoardPersistsSelection() async throws {
        let watcher = SelectorWatcherDouble()
        let model = KanbanBoardViewModel(watcher: watcher, selectionStore: makeStore())
        await model.start()
        defer { Task { await model.stop() } }

        await model.selectBoard("side")
        XCTAssertEqual(suite.string(forKey: "fleet.kanban.selectedBoard"), "side")

        // Relaunch: a fresh model with the same store restores it.
        let watcher2 = SelectorWatcherDouble()
        watcher2.boards = KanbanBoardList(
            boards: [
                KanbanBoardSummary(slug: "r10", name: "R10", isCurrent: true, total: 3),
                KanbanBoardSummary(slug: "side", name: "Side", isCurrent: false, total: 1),
            ],
            current: "r10")
        let model2 = KanbanBoardViewModel(watcher: watcher2, selectionStore: makeStore())
        await model2.start()
        defer { Task { await model2.stop() } }
        XCTAssertEqual(model2.selectedBoard, "side", "selection must survive relaunch (per-device UserDefaults)")
    }

    func testSelectActiveBoardClearsPinAndPersist() async throws {
        let watcher = SelectorWatcherDouble()
        watcher.boards = KanbanBoardList(
            boards: [
                KanbanBoardSummary(slug: "r10", name: "R10", isCurrent: true, total: 3),
                KanbanBoardSummary(slug: "side", name: "Side", isCurrent: false, total: 1),
            ],
            current: "r10")
        makeStore().saveSelectedBoard("side")
        let model = KanbanBoardViewModel(watcher: watcher, selectionStore: makeStore())
        await model.start()
        defer { Task { await model.stop() } }

        await model.selectBoard(nil)
        XCTAssertNil(model.selectedBoard, "selecting the active board clears the pin")
        XCTAssertNil(suite.string(forKey: "fleet.kanban.selectedBoard"))
        XCTAssertEqual(watcher.pinnedSlugs.last ?? nil, nil)
    }

    // MARK: Store

    func testSelectionStoreRoundTrip() {
        let store = makeStore()
        XCTAssertNil(store.loadSelectedBoard())
        store.saveSelectedBoard("side")
        XCTAssertEqual(store.loadSelectedBoard(), "side")
        store.saveSelectedBoard(nil)
        XCTAssertNil(store.loadSelectedBoard())
    }
}

/// Selector-capable double: records pins, per-board snapshot fetches, and
/// stream (re)opens. `storedSelection` seeds the persistence seam.
final class SelectorWatcherDouble: KanbanBoardWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<KanbanEventBatch>.Continuation] = [:]
    private var _snapshotFetchCount = 0
    private var _stopped = false
    private var _pinned: String?

    var boards = KanbanBoardList(boards: [], current: nil)
    private(set) var pinnedSlugs: [String?] = []
    private(set) var snapshotBoards: [String?] = []
    private(set) var changeEventsCalls = 0
    var snapshotFetchCount: Int {
        locked { _snapshotFetchCount }
    }

    var stopped: Bool {
        get { locked { _stopped } }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func fetchBoards() async throws -> KanbanBoardList {
        locked { boards }
    }

    func pinBoard(_ slug: String?) async {
        locked {
            _pinned = slug
            pinnedSlugs.append(slug)
        }
    }

    func snapshot() async throws -> KanbanBoardSnapshot {
        let board: String? = locked {
            _snapshotFetchCount += 1
            snapshotBoards.append(_pinned)
            return _pinned
        }
        return KanbanBoardSnapshot(
            columns: ["todo"],
            cardsByColumn: [
                "todo": [
                    KanbanCard(
                        id: "t_\(board ?? "active")", title: "Card \(board ?? "active")",
                        status: "todo"),
                ],
            ],
            latestEventID: 1
        )
    }

    func changeEvents() async -> AsyncStream<KanbanEventBatch> {
        let id = UUID()
        return locked {
            changeEventsCalls += 1
            return AsyncStream { continuation in
                self.continuations[id] = continuation
                continuation.onTermination = { _ in
                    self.locked { self.continuations[id] = nil }
                }
            }
        }
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
}
