import Foundation
import Observation
import FleetCore

/// t_3b321b7b — observable state for the read-only Kanban board.
///
/// Owns the `KanbanBoardWatching` seam lifecycle:
/// - `start()` fetches the initial snapshot, then consumes the change-event
///   stream forever. ANY event batch triggers a coalesced board refetch
///   (the dashboard's own client pattern — the HTTP board is the single
///   source of truth, so the view can never drift from the DB).
/// - Stream drops are handled INSIDE the client (auto-reconnect + cursor
///   resume); the view model additionally runs a slow poll backstop while
///   visible so a long-idle board still catches up.
/// - Strictly read-only: the only mutations are snapshot swaps.
@MainActor
@Observable
public final class KanbanBoardViewModel {
    // MARK: Observable state

    /// Latest board snapshot (nil until the first fetch resolves).
    public private(set) var snapshot: KanbanBoardSnapshot?
    /// True while the initial snapshot fetch is in flight.
    public private(set) var isLoading = false
    /// Last error (snapshot fetch or fatal stream failure). Non-secret.
    public private(set) var errorMessage: String?
    /// Live connection phase of the event stream.
    public enum StreamPhase: Equatable, Sendable {
        case idle
        case streaming
        /// Dropped; the client is reconnecting (board may be stale).
        case reconnecting
    }
    public private(set) var streamPhase: StreamPhase = .idle
    /// Recent change events (newest first, capped) for the activity strip.
    public private(set) var recentEvents: [KanbanChangeEvent] = []

    /// Count of snapshot refetches triggered by live events — proves the
    /// stream path (vs. the poll backstop) drove the update.
    public private(set) var liveUpdateCount = 0

    // MARK: Board selection (t_624b81cd — B1)

    /// Boards the gateway offers (empty until the first list fetch).
    public private(set) var boards: [KanbanBoardSummary] = []
    /// The pinned board slug, or nil when following the gateway's ACTIVE
    /// board. Selection is CLIENT-SIDE only (never /boards/{slug}/switch).
    public private(set) var selectedBoard: String?
    /// The board name shown in the picker button (active board's name when
    /// unpinned; the slug itself as an honest fallback).
    public var displayBoardName: String {
        if let selectedBoard {
            return boards.first { $0.slug == selectedBoard }?.name ?? selectedBoard
        }
        return boards.first { $0.isCurrent }?.name
            ?? "Board"
    }

    // MARK: Dependencies

    private let watcher: any KanbanBoardWatching
    private let selectionStore: KanbanBoardSelectionStore?
    private var streamTask: Task<Void, Never>?
    /// Monotonic stream-generation counter (t_624b81cd): a cancelled
    /// selectBoard predecessor can never write state for its successor.
    private var streamGeneration = 0
    private var pollTask: Task<Void, Never>?
    /// Coalescing: a refetch requested but not yet started.
    private var refetchPending = false
    private static let recentEventsCap = 20
    private static let pollBackstopInterval: Duration = .seconds(30)
    /// Coalescing window for event bursts (one refetch per burst).
    private static let coalesceWindow: Duration = .milliseconds(300)

    public init(
        watcher: any KanbanBoardWatching,
        selectionStore: KanbanBoardSelectionStore = KanbanBoardSelectionStore()
    ) {
        self.watcher = watcher
        self.selectionStore = selectionStore
    }

    // MARK: Lifecycle

    /// Fetch the boards list + initial snapshot and consume the live stream.
    public func start(board: String? = nil) async {
        guard streamTask == nil else { return }
        if let board {
            boards = (try? await watcher.fetchBoards())?.boards ?? []
            selectedBoard = board
            await watcher.pinBoard(board)
        } else {
            await loadBoards()
        }
        await openStream()
        await loadSnapshot(initial: true)
        startPollBackstop()
    }

    /// Load the boards list; restore the persisted selection when the
    /// gateway still has that board (unknown slug → active board, no crash).
    private func loadBoards() async {
        if let list = try? await watcher.fetchBoards() {
            boards = list.boards
        }
        guard let stored = selectionStore?.loadSelectedBoard() else { return }
        // A missing saved board must fail at its exact target, never silently
        // show a different board from the same gateway.
        selectedBoard = stored
        await watcher.pinBoard(stored)
    }

    /// Tear everything down (view disappeared / gateway removed).
    public func stop() async {
        streamTask?.cancel()
        streamTask = nil
        pollTask?.cancel()
        pollTask = nil
        streamPhase = .idle
        await watcher.stop()
    }

    /// Manual refresh (pull-to-refresh; also the recovery path).
    public func refresh() async {
        await loadSnapshot(initial: false)
    }

    // MARK: Board switching (t_624b81cd — client-side selection only)

    /// Switch the displayed board: pin the watcher (snapshot + WS URLs take
    /// `?board=`), cancel the old event stream, refetch the snapshot, and
    /// re-open the stream pinned to the new slug at handshake. Persisted
    /// per-device. Passing nil returns to the gateway's ACTIVE board.
    /// NEVER calls `/boards/{slug}/switch` (orchestrator pointer untouched).
    public func selectBoard(_ slug: String?) async {
        guard slug != selectedBoard else { return }
        selectedBoard = slug
        selectionStore?.saveSelectedBoard(slug)

        // Snapshot of the OLD board is stale the moment we switch — drop it
        // rather than showing another board's cards under the new name.
        snapshot = nil
        recentEvents.removeAll()

        streamTask?.cancel()
        streamTask = nil
        await watcher.pinBoard(slug)
        await openStream()
        await loadSnapshot(initial: true)
    }

    // MARK: Internals

    /// Start the stream task and yield once so the watcher records the new
    /// subscription before callers continue with snapshot work.
    private func openStream() async {
        streamGeneration += 1
        let generation = streamGeneration
        streamTask = Task { [weak self] in
            await self?.consumeStream(generation: generation)
        }
        await Task.yield()
    }

    private func consumeStream(generation: Int) async {
        let batches = await watcher.changeEvents()
        // t_624b81cd: only the CURRENT stream generation may set phase — a
        // task superseded by selectBoard must not clobber its successor.
        guard generation == streamGeneration else { return }
        streamPhase = .streaming
        for await batch in batches {
            if Task.isCancelled || generation != streamGeneration { break }
            var events = batch.events
            events.reverse()
            recentEvents.insert(
                contentsOf: events, at: 0)
            if recentEvents.count > Self.recentEventsCap {
                recentEvents.removeLast(recentEvents.count - Self.recentEventsCap)
            }
            // Coalesce: one refetch per run-loop-ish window per burst.
            scheduleLiveRefetch()
        }
        if generation == streamGeneration {
            streamPhase = .idle
        }
    }

    private func scheduleLiveRefetch() {
        guard !refetchPending else { return }
        refetchPending = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceWindow)
            self?.refetchPending = false
            self?.liveUpdateCount += 1
            await self?.loadSnapshot(initial: false)
        }
    }

    private func loadSnapshot(initial: Bool) async {
        if initial { isLoading = true }
        defer { if initial { isLoading = false } }
        do {
            let next = try await watcher.snapshot()
            snapshot = next
            errorMessage = nil
        } catch {
            errorMessage = (error as? KanbanBoardError)?.errorDescription
                ?? String(describing: error)
            if initial {
                streamPhase = .reconnecting
            }
        }
    }

    /// Slow poll backstop: the client's WS reconnect covers drops, but a
    /// long-idle visible board still refetches periodically (matching the
    /// dashboard's own paranoia about silent tails).
    private func startPollBackstop() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollBackstopInterval)
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }
}
