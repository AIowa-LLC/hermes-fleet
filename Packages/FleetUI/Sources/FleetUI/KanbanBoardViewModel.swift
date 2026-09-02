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

    // MARK: Dependencies

    private let watcher: any KanbanBoardWatching
    private var streamTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// Coalescing: a refetch requested but not yet started.
    private var refetchPending = false
    private static let recentEventsCap = 20
    private static let pollBackstopInterval: Duration = .seconds(30)
    /// Coalescing window for event bursts (one refetch per burst).
    private static let coalesceWindow: Duration = .milliseconds(300)

    public init(watcher: any KanbanBoardWatching) {
        self.watcher = watcher
    }

    // MARK: Lifecycle

    /// Fetch the initial snapshot and consume the live stream.
    public func start() async {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            await self?.consumeStream()
        }
        await loadSnapshot(initial: true)
        startPollBackstop()
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

    // MARK: Internals

    private func consumeStream() async {
        let batches = await watcher.changeEvents()
        streamPhase = .streaming
        for await batch in batches {
            if Task.isCancelled { break }
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
        streamPhase = .idle
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
