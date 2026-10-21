import Foundation
import Observation
import FleetCore

/// Build 41 — observable state for the INTERACTIVE Kanban board.
///
/// Owns the `KanbanBoardWatching` seam lifecycle:
/// - `start()` fetches the initial snapshot, then consumes the change-event
///   stream forever. ANY event batch triggers a coalesced board refetch
///   (the dashboard's own client pattern — the HTTP board is the single
///   source of truth, so the view can never drift from the DB).
/// - Stream drops are handled INSIDE the client (auto-reconnect + cursor
///   resume); the view model additionally runs a slow poll backstop while
///   visible so a long-idle board still catches up.
///
/// Build 41 adds MUTATION (via `KanbanBoardOperating`) plus board filters:
/// when `boardOperator` is nil the board renders read-only (fail closed —
/// unconfigured gateways never expose half-wired mutation controls).
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
    /// Set when the gateway DEFINITIVELY refused the board (401/403/404).
    /// While set, the model issues no automatic requests (no poll, no stream
    /// reconnects); only an explicit `refresh()` ("Check again") re-asks.
    public private(set) var accessIssue: KanbanBoardAccessIssue?
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

    // MARK: Filters (Build 41)

    /// Free-text filter over title/assignee/id (case/diacritic-insensitive).
    public var filterText = ""
    /// Optional assignee filter (nil = all assignees).
    public var filterAssignee: String?
    /// Show the archived column (requires a board operator).
    public var showArchived = false

    /// The snapshot with filters applied (columns with zero visible cards
    /// stay rendered with their count chip showing the filtered count).
    public var filteredSnapshot: KanbanBoardSnapshot? {
        guard let snapshot else { return nil }
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || filterAssignee != nil else { return snapshot }
        var byColumn: [String: [KanbanCard]] = [:]
        for column in snapshot.columns {
            byColumn[column] = snapshot.cards(in: column).filter { card in
                if let filterAssignee, card.assignee != filterAssignee { return false }
                if !query.isEmpty {
                    let haystack = "\(card.title) \(card.assignee ?? "") \(card.id)"
                    if haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                        return false
                    }
                }
                return true
            }
        }
        return KanbanBoardSnapshot(
            columns: snapshot.columns,
            cardsByColumn: byColumn,
            latestEventID: snapshot.latestEventID,
            now: snapshot.now)
    }

    /// Show or hide the archived column. The snapshot is refetched on BOTH
    /// transitions — turning the toggle OFF must drop the archived-inclusive
    /// snapshot immediately, otherwise the archived column lingers (out of
    /// step with the toggle) until some unrelated event refreshes the board.
    /// An unchanged value is a no-op; read-only boards just flip the flag.
    public func setShowArchived(_ value: Bool) async {
        guard value != showArchived else { return }
        showArchived = value
        guard boardOperator != nil else { return }
        await loadSnapshot(initial: false)
    }

    /// The card for a task id anywhere in the loaded snapshot (nil when the
    /// task is not on this board). Detail rows that reference a RELATED card
    /// — e.g. a task's PARENTS, which the detail bundle only carries as ids —
    /// resolve their title/status from here.
    public func card(id: String) -> KanbanCard? {
        guard let snapshot else { return nil }
        for cards in snapshot.cardsByColumn.values {
            if let match = cards.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

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

    // MARK: Mutation state (Build 41)

    /// Assignees known to the gateway (profiles ∪ board assignees) for the
    /// pickers. Empty until first load; reloaded on start.
    public private(set) var assignees: [String] = []
    /// True while a mutation is in flight (drives row-level progress + the
    /// global "working" indicator).
    public private(set) var isMutating = false
    /// Last mutation failure (non-secret server detail; shown as a banner).
    public var mutationErrorMessage: String?
    /// Last auxiliary (specify/decompose/dispatch) outcome for inline notes.
    public var auxOutcomeMessage: String?
    /// Server warning from the most recent create — the dispatcher-presence
    /// banner on a ready+assigned card that would otherwise sit idle. Cleared
    /// by the next create attempt; nil when the server sent none.
    public private(set) var createWarning: String?

    /// The mutation seam. Nil = this gateway's board is read-only (fail
    /// closed — the UI hides every mutation affordance).
    public let boardOperator: (any KanbanBoardOperating)?
    /// Whether this board can mutate: an operator exists AND a board
    /// snapshot has actually loaded (a refused/unavailable board must not
    /// offer Add/Move controls that can only fail).
    public var canMutate: Bool {
        boardOperator != nil && snapshot != nil && accessIssue == nil
    }

    // MARK: Dependencies

    private let watcher: any KanbanBoardWatching
    private let selectionStore: KanbanBoardSelectionStore?
    private var streamTask: Task<Void, Never>?
    /// Monotonic stream-generation counter (t_624b81cd): a cancelled
    /// selectBoard predecessor can never write state for its successor.
    private var streamGeneration = 0
    private var pollTask: Task<Void, Never>?
    /// The single in-flight snapshot load (concurrent callers join it).
    private var inFlightLoad: Task<Void, Never>?
    private var inFlightIncludesArchived = false
    private let diagnostics: DiagnosticsRecorder?
    /// Coalescing: a refetch requested but not yet started.
    private var refetchPending = false
    private static let recentEventsCap = 20
    private static let pollBackstopInterval: Duration = .seconds(30)
    /// Coalescing window for event bursts (one refetch per burst).
    private static let coalesceWindow: Duration = .milliseconds(300)

    public init(
        watcher: any KanbanBoardWatching,
        boardOperator: (any KanbanBoardOperating)? = nil,
        selectionStore: KanbanBoardSelectionStore = KanbanBoardSelectionStore(),
        diagnostics: DiagnosticsRecorder? = nil
    ) {
        self.diagnostics = diagnostics
        self.watcher = watcher
        self.boardOperator = boardOperator
        self.selectionStore = selectionStore
    }

    // MARK: Lifecycle

    /// Fetch the boards list + initial snapshot and consume the live stream.
    public func start(board: String? = nil) async {
        guard streamTask == nil else { return }
        if let board {
            await fetchBoardList()
            selectedBoard = board
            await watcher.pinBoard(board)
        } else {
            await loadBoards()
        }
        // The snapshot is the arbiter: a definitive refusal means no
        // assignee fetch, no event stream and no poll (nothing to hammer).
        await loadSnapshot(initial: true)
        guard accessIssue == nil else { return }
        await beginLiveUpdates()
    }

    /// Assignees + event stream + poll backstop (idempotent).
    private func beginLiveUpdates() async {
        await loadAssignees()
        if streamTask == nil { await openStream() }
        startPollBackstop()
    }

    /// `GET /boards`, recording a refusal in diagnostics instead of
    /// swallowing it.
    private func fetchBoardList() async {
        do {
            boards = try await watcher.fetchBoards().boards
        } catch {
            boards = []
            record(error)
        }
    }

    private func record(_ error: any Error) {
        guard !Redaction.isCancellation(error) else { return }
        let detail = (error as? KanbanBoardError)?.diagnosticDetail
            ?? Redaction.userFacingErrorDescription(error)
        diagnostics?.record(category: "Kanban", detail: detail)
    }

    /// Load the boards list; restore the persisted selection when the
    /// gateway still has that board (unknown slug → active board, no crash).
    private func loadBoards() async {
        await fetchBoardList()
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
    ///
    /// Exactly one request while the board is refused (the "Check again"
    /// path); concurrent calls join the in-flight load. If a previously
    /// refused board now loads, live updates start.
    public func refresh() async {
        let wasRefused = accessIssue != nil
        await loadSnapshot(initial: false)
        guard accessIssue == nil else { return }
        if wasRefused {
            await fetchBoardList()
            await beginLiveUpdates()
        } else {
            await loadAssignees()
        }
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
        accessIssue = nil

        // A load still in flight belongs to the OLD board: cancel it so the
        // new board's load cannot join (and adopt) its result.
        if let running = inFlightLoad {
            running.cancel()
            await running.value
        }
        streamTask?.cancel()
        streamTask = nil
        await watcher.pinBoard(slug)
        await loadSnapshot(initial: true)
        guard accessIssue == nil else { return }
        await openStream()
        startPollBackstop()
        await loadAssignees()
    }

    // MARK: Mutations (Build 41 — all require boardOperator, fail closed)

    /// Runs a board mutation. Returns whether the write succeeded — callers
    /// gate local echo on this (a failed write must never look applied).
    @discardableResult
    private func runMutation(_ label: String, _ body: () async throws -> Void) async -> Bool {
        guard let boardOperator else {
            mutationErrorMessage = "This gateway's board is read-only."
            return false
        }
        isMutating = true
        defer { isMutating = false }
        do {
            try await body()
            mutationErrorMessage = nil
            // The mutation changes board state — refetch immediately (do not
            // wait for the event tail; local echo must not drift from truth).
            await loadSnapshot(initial: false)
            return true
        } catch {
            mutationErrorMessage = Redaction.userFacingErrorDescription(error)
            return false
        }
    }

    /// `POST /tasks` — create a card from the draft; returns the created card.
    ///
    /// NOT throwing by contract: the write routes through `runMutation`, which
    /// captures every failure into `mutationErrorMessage` for the caller's
    /// banner, and `nil` means "nothing was created" (read-only board or a
    /// refusal). `createWarning` carries the server's optional warning banner.
    @discardableResult
    public func createTask(_ draft: KanbanTaskDraft) async -> KanbanCard? {
        createWarning = nil
        guard let boardOperator else {
            mutationErrorMessage = "This gateway's board is read-only."
            return nil
        }
        var created: KanbanCard?
        var warning: String?
        await runMutation("create") {
            let result = try await boardOperator.createTaskWithWarning(draft)
            created = result.card
            warning = result.warning
        }
        createWarning = warning
        return created
    }

    /// `PATCH /tasks/{id}` — partial update (nil fields are not sent).
    public func updateTask(id: String, patch: KanbanTaskPatch) async {
        await runMutation("update") {
            _ = try await boardOperator?.updateTask(id: id, patch: patch)
        }
    }

    /// Move a card to a new status (context menu / detail action). `running`
    /// is NOT in the settable set — the server rejects it; the UI surfaces
    /// the server's message.
    public func moveTask(id: String, to status: String) async {
        await updateTask(id: id, patch: KanbanTaskPatch(status: status))
    }

    /// Complete a task (optionally with result/summary handoff fields).
    public func completeTask(id: String, result: String?, summary: String?) async {
        await runMutation("complete") {
            _ = try await boardOperator?.updateTask(
                id: id,
                patch: KanbanTaskPatch(status: "done", result: result, summary: summary))
        }
    }

    /// Block with a reason (blocks show the reason in diagnostics).
    public func blockTask(id: String, reason: String?) async {
        await updateTask(id: id, patch: KanbanTaskPatch(status: "blocked", blockReason: reason))
    }

    /// Unblock → ready (server re-opens via unblock_task).
    public func unblockTask(id: String) async {
        await moveTask(id: id, to: "ready")
    }

    /// Archive a task (soft; reversible by moving out on the archived view).
    public func archiveTask(id: String) async {
        await updateTask(id: id, patch: KanbanTaskPatch(status: "archived"))
    }

    /// Restore an archived task to todo.
    public func restoreTask(id: String) async {
        await moveTask(id: id, to: "todo")
    }

    /// `DELETE /tasks/{id}` — hard delete, destructive.
    public func deleteTask(id: String) async {
        await runMutation("delete") {
            try await boardOperator?.deleteTask(id: id)
        }
    }

    /// `POST /tasks/{id}/reclaim` — release an active worker claim.
    public func reclaimTask(id: String, reason: String?) async {
        await runMutation("reclaim") {
            try await boardOperator?.reclaimTask(id: id, reason: reason)
        }
    }

    /// `POST /tasks/{id}/reassign`.
    public func reassignTask(id: String, profile: String?, reclaimFirst: Bool, reason: String?) async {
        await runMutation("reassign") {
            try await boardOperator?.reassignTask(
                id: id, profile: profile, reclaimFirst: reclaimFirst, reason: reason)
        }
    }

    /// `POST /tasks/{id}/comments`. Returns false when the write failed —
    /// the detail composer keeps its text for a retry (a failed comment must
    /// never look posted).
    @discardableResult
    public func addComment(taskID: String, body: String) async -> Bool {
        await runMutation("comment") {
            try await boardOperator?.addComment(taskID: taskID, body: body, author: nil)
        }
    }

    /// `POST /links`.
    public func linkTasks(parentID: String, childID: String) async {
        await runMutation("link") {
            _ = try await boardOperator?.linkTasks(parentID: parentID, childID: childID)
        }
    }

    /// `DELETE /links`.
    public func unlinkTasks(parentID: String, childID: String) async {
        await runMutation("unlink") {
            try await boardOperator?.unlinkTasks(parentID: parentID, childID: childID)
        }
    }

    /// `POST /tasks/{id}/specify` — auxiliary LLM; non-OK is a VALUE (inline
    /// note, not an error banner).
    public func specifyTask(id: String) async {
        guard let boardOperator else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let outcome = try await boardOperator.specifyTask(id: id, author: nil)
            auxOutcomeMessage = outcome.ok
                ? "Specified — new title: \(outcome.newTitle ?? id)"
                : (outcome.reason ?? "Specifier declined")
            await loadSnapshot(initial: false)
        } catch {
            mutationErrorMessage = Redaction.userFacingErrorDescription(error)
        }
    }

    /// `POST /tasks/{id}/decompose` — auxiliary LLM fan-out.
    public func decomposeTask(id: String) async {
        guard let boardOperator else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let outcome = try await boardOperator.decomposeTask(id: id, author: nil)
            if outcome.ok {
                auxOutcomeMessage = outcome.fanout
                    ? "Decomposed into \(outcome.childIDs.count) children"
                    : (outcome.reason ?? "No fan-out needed")
            } else {
                auxOutcomeMessage = outcome.reason ?? "Decomposer declined"
            }
            await loadSnapshot(initial: false)
        } catch {
            mutationErrorMessage = Redaction.userFacingErrorDescription(error)
        }
    }

    /// `POST /tasks/bulk` — returns per-id outcomes for partial reporting.
    @discardableResult
    public func bulkUpdate(_ patch: KanbanBulkPatch) async -> [KanbanBulkOutcome] {
        guard let boardOperator else { return [] }
        var results: [KanbanBulkOutcome] = []
        await runMutation("bulk") {
            results = try await boardOperator.bulkUpdate(patch)
        }
        if let failures = results.first(where: { !$0.ok })?.error {
            auxOutcomeMessage = "Bulk: \(failures)"
        }
        return results
    }

    /// `POST /dispatch` — nudge the dispatcher now.
    public func dispatchNudge(dryRun: Bool = false) async {
        guard let boardOperator else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let result = try await boardOperator.dispatchNudge(dryRun: dryRun, max: 8)
            let spawned = result.spawned?.count ?? 0
            auxOutcomeMessage = dryRun
                ? "Dry run: \(result.promoted ?? 0) promoted, \(spawned) would spawn"
                : "Dispatched: \(result.promoted ?? 0) promoted, \(spawned) spawned"
            await loadSnapshot(initial: false)
        } catch {
            mutationErrorMessage = Redaction.userFacingErrorDescription(error)
        }
    }

    /// `GET /orchestration`.
    public func orchestrationSettings() async throws -> KanbanOrchestrationSettings? {
        try await boardOperator?.orchestrationSettings()
    }

    /// `PUT /orchestration`.
    public func updateOrchestrationSettings(_ patch: KanbanOrchestrationPatch) async {
        await runMutation("orchestration") {
            _ = try await boardOperator?.updateOrchestrationSettings(patch)
        }
    }

    private func loadAssignees() async {
        guard let boardOperator else { return }
        if let list = try? await boardOperator.fetchAssignees() {
            assignees = list
        }
    }

    // MARK: Internals

    /// Register the stream before returning so a board switch cannot cancel
    /// an unstarted consumer and silently skip the old subscription.
    private func openStream() async {
        streamGeneration += 1
        let generation = streamGeneration
        let batches = await watcher.changeEvents()
        guard generation == streamGeneration else { return }
        streamPhase = .streaming
        streamTask = Task { [weak self] in
            await self?.consumeStream(batches, generation: generation)
        }
    }

    private func consumeStream(
        _ batches: AsyncStream<KanbanEventBatch>, generation: Int
    ) async {
        // A superseded generation must not return the successor's phase to idle.
        guard generation == streamGeneration, !Task.isCancelled else { return }
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
        // Join an in-flight load rather than issuing a duplicate request —
        // unless it was for a different archived mode (then wait, re-ask).
        if let running = inFlightLoad {
            let sameMode = inFlightIncludesArchived == (boardOperator != nil && showArchived)
            await running.value
            if sameMode { return }
            await loadSnapshot(initial: initial)
            return
        }
        inFlightIncludesArchived = boardOperator != nil && showArchived
        let task = Task { [weak self] in
            await self?.performSnapshotLoad(initial: initial)
            self?.inFlightLoad = nil
        }
        inFlightLoad = task
        await task.value
    }

    private func performSnapshotLoad(initial: Bool) async {
        if initial { isLoading = true }
        defer { if initial { isLoading = false } }
        do {
            let next: KanbanBoardSnapshot
            if let boardOperator, showArchived {
                next = try await boardOperator.snapshot(includeArchived: true)
            } else {
                next = try await watcher.snapshot()
            }
            snapshot = next
            errorMessage = nil
            accessIssue = nil
        } catch {
            if Redaction.isCancellation(error) { return }
            errorMessage = Redaction.userFacingErrorDescription(error)
            record(error)
            if let issue = (error as? KanbanBoardError)?.accessIssue {
                // Definitive: stop everything automatic. A stale snapshot
                // from before the refusal is not trustworthy either.
                accessIssue = issue
                snapshot = nil
                await haltAutomaticUpdates()
            } else if initial {
                streamPhase = .reconnecting
            }
        }
    }

    /// Stop the WS stream (and its reconnect loop) and the poll backstop.
    private func haltAutomaticUpdates() async {
        streamGeneration += 1
        streamTask?.cancel()
        streamTask = nil
        pollTask?.cancel()
        pollTask = nil
        streamPhase = .idle
        await watcher.stop()
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
                guard let self, self.accessIssue == nil else { break }
                await self.refresh()
            }
        }
    }
}
