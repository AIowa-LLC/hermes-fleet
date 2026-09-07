import Foundation

/// t_3b321b7b — read-only Kanban board domain (FleetCore).
///
/// The live board is the Hermes dashboard's kanban plugin surface
/// (`GET /api/plugins/kanban/board` + the `/api/plugins/kanban/events`
/// WebSocket tail). This module holds the pure domain values the UI renders:
/// a board snapshot (columns of cards) plus the change-event vocabulary the
/// stream client surfaces so the view model can refetch.
///
/// Read-only by construction: there are no mutation commands here — no
/// create/edit/move/delete. The only state transitions are "a new snapshot
/// arrived" and "change events arrived".

// MARK: - Card

/// One task card on the board. Only the fields the read-only view needs are
/// modeled; unknown JSON fields are ignored (forward compatibility).
public struct KanbanCard: Sendable, Equatable, Identifiable {
    /// Stable task id (`t_<hex>` on the wire).
    public let id: String
    /// Card title.
    public let title: String
    /// Column status (`triage|todo|scheduled|ready|running|blocked|review|done`).
    public let status: String
    /// Assignee profile name, when set.
    public let assignee: String?
    /// Priority (higher = sooner; used for in-column ordering — the server
    /// already orders columns, this is retained for display only).
    public let priority: Int?
    /// Creation timestamp (epoch seconds) when the server provides one.
    public let createdAt: Double?
    /// Latest run-summary preview (server truncates to ~200 chars).
    public let latestSummary: String?

    public init(
        id: String,
        title: String,
        status: String,
        assignee: String? = nil,
        priority: Int? = nil,
        createdAt: Double? = nil,
        latestSummary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.assignee = assignee
        self.priority = priority
        self.createdAt = createdAt
        self.latestSummary = latestSummary
    }
}

// MARK: - Board snapshot

/// The columns of a board snapshot, in display order. The server's
/// `BOARD_COLUMNS` order is preserved; unknown statuses are bucketed into
/// `todo` by the server, so every card lands in a known column.
public struct KanbanBoardSnapshot: Sendable, Equatable {
    /// Ordered column names (the server's fixed vocabulary).
    public let columns: [String]
    /// Cards per column name (keyed by the same names as `columns`).
    public let cardsByColumn: [String: [KanbanCard]]
    /// The board's event cursor at snapshot time — pass to the event stream
    /// as `since` so events after the snapshot drive updates.
    public let latestEventID: Int
    /// Server clock at snapshot time (epoch seconds) — the UI can show
    /// relative ages without client clock assumptions.
    public let now: Double?

    public init(
        columns: [String],
        cardsByColumn: [String: [KanbanCard]],
        latestEventID: Int,
        now: Double? = nil
    ) {
        self.columns = columns
        self.cardsByColumn = cardsByColumn
        self.latestEventID = latestEventID
        self.now = now
    }

    /// Total card count across columns.
    public var totalCards: Int { cardsByColumn.values.reduce(0) { $0 + $1.count } }

    /// Cards in a column (empty when the column is unknown).
    public func cards(in column: String) -> [KanbanCard] { cardsByColumn[column] ?? [] }
}

// MARK: - Board list (t_624b81cd — B1 board selector)

/// One board from `GET /api/plugins/kanban/boards` (per-device picker data).
/// Wire shape verified against `plugins/kanban/dashboard/plugin_api.py`
/// (list_boards): slug/name/is_current/total, unknown fields ignored.
public struct KanbanBoardSummary: Sendable, Equatable, Identifiable, Decodable {
    /// Board slug — the wire identifier every other endpoint takes
    /// (`?board=<slug>`); also the identity of the summary.
    public let slug: String
    /// Human display name.
    public let name: String
    /// True when this is the gateway operator's ACTIVE board (the pointer
    /// the app must never move — client-side selection only).
    public let isCurrent: Bool
    /// Live (non-archived) card count, when the server sent one.
    public let total: Int?

    private enum CodingKeys: String, CodingKey {
        case slug, name
        case isCurrent = "is_current"
        case total
    }

    public init(slug: String, name: String, isCurrent: Bool, total: Int? = nil) {
        self.slug = slug
        self.name = name
        self.isCurrent = isCurrent
        self.total = total
    }

    public var id: String { slug }
}

/// The `GET /boards` response: every board plus the active slug.
public struct KanbanBoardList: Sendable, Equatable, Decodable {
    public let boards: [KanbanBoardSummary]
    /// The gateway operator's active board slug (display-only for the app).
    public let current: String?

    private enum CodingKeys: String, CodingKey { case boards, current }

    public init(boards: [KanbanBoardSummary], current: String?) {
        self.boards = boards
        self.current = current
    }
}

// MARK: - Change events

/// One board change event from the kanban event stream (the append-only
/// `task_events` tail). The dashboard's own web client treats ANY event as a
/// "something changed for this task" signal and refetches the board; this
/// client does the same, but keeps the kind + task id so the view model can
/// surface activity and coalesce refetches.
public struct KanbanChangeEvent: Sendable, Equatable, Identifiable {
    /// Monotonic event id (the tail cursor).
    public let id: Int
    /// The task the event belongs to.
    public let taskID: String
    /// Event kind (`created`, `status_changed`, `claimed`, `completed`,
    /// `commented`, ... — open vocabulary; never exhaustively matched).
    public let kind: String
    /// When the event was recorded (epoch seconds).
    public let createdAt: Double?

    public init(id: Int, taskID: String, kind: String, createdAt: Double? = nil) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.createdAt = createdAt
    }
}

/// A batch of events delivered by one stream frame, with the new cursor.
public struct KanbanEventBatch: Sendable, Equatable {
    public let events: [KanbanChangeEvent]
    public let cursor: Int

    public init(events: [KanbanChangeEvent], cursor: Int) {
        self.events = events
        self.cursor = cursor
    }
}

// MARK: - Seam

/// Errors surfaced by a board watcher. Non-secret (spec §29 discipline).
public enum KanbanBoardError: Error, Sendable, Equatable, LocalizedError {
    /// The board fetch returned a non-2xx status (detail is the bare status).
    case httpStatus(Int)
    /// The response body was not the expected shape.
    case malformedResponse(String)
    /// The event stream dropped and could not be re-established.
    case streamDropped(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "kanban board: HTTP \(code)"
        case .malformedResponse(let detail): return "kanban board: malformed response (\(detail))"
        case .streamDropped(let detail): return "kanban event stream dropped: \(detail)"
        }
    }
}

/// t_3b321b7b seam: a live, read-only view of a gateway's kanban board.
///
/// Mirrors the `GatewayConnectivityProviding` / `ConversationSessionProviding`
/// pattern: FleetUI depends only on this FleetCore protocol — never on the
/// networking module (M0 hard guard). The concrete `KanbanEventStreamClient`
/// (FleetNetworking) implements it against the dashboard plugin surface.
///
/// Semantics (the Hermex `KanbanEventStreamClient` pattern):
/// - `snapshot()` fetches the full board (HTTP GET) including the event
///   cursor to resume from.
/// - `changeEvents()` yields event batches as they arrive on the stream,
///   forever (the async stream only ends on stop()/teardown). Reconnects are
///   internal: a dropped stream is re-opened with `since=<cursor>` so no
///   events are lost across the gap.
/// - `stop()` tears the stream down (idempotent).
public protocol KanbanBoardWatching: Sendable {
    /// Fetch the full board snapshot (includes the event cursor).
    func snapshot() async throws -> KanbanBoardSnapshot
    /// Stream change-event batches; ends only on stop() or teardown.
    func changeEvents() async -> AsyncStream<KanbanEventBatch>
    /// Tear the stream down. Idempotent. Async so actors can conform
    /// without nonisolated escape hatches.
    func stop() async
    // t_624b81cd (B1) — board-selection REQUIREMENTS. `fetchBoards` =
    // GET /boards; `pinBoard` is CLIENT-SIDE selection only —
    // `POST /boards/{slug}/switch` is FORBIDDEN (it repoints the
    // orchestrator Mac's active board).
    // NOTE: deliberately NO protocol-extension defaults — a default
    // `pinBoard(_:) async` collides with conformers' own actor-isolated
    // overloads and Swift resolution can pick the no-op default on
    // concrete types (found the hard way, t_624b81cd). Every conformer
    // implements these explicitly.
    func fetchBoards() async throws -> KanbanBoardList
    func pinBoard(_ slug: String?) async
}
