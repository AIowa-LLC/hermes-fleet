import Foundation

// MARK: - Live Ops v1 domain
//
// Fleet-wide, READ-ONLY observation of which Hermes sessions are live on each
// gateway and which delegated subagents they own, plus detailed child
// controls ONLY for sessions the Fleet transport is currently attached to.
//
// Wire ground truth (hermes-agent origin/main 6636b08):
// - `session.active_list` (tui_gateway/methods_session.py:908) — every live
//   TUI/gateway session in the process, keyed by RUNTIME session id (`id`).
//   Row shape (`_session_live_item`, tui_gateway/server.py:2708):
//   `{current, id, last_active, message_count, model, preview, session_key,
//   started_at, status, title}`. `status` comes from `_session_live_status`
//   (server.py:2691), whose FULL vocabulary is exactly four strings —
//   `waiting` (server-side prompt pending, `_session_pending_kind`),
//   `starting` (agent build in flight, `agent_ready` unset), `working`
//   (`session["running"]`), `idle` (none of the above). There is no fifth
//   value in the current source, but the client must still decode tolerantly
//   (`LiveOperationStatus.unknown`) — a future gateway build is free to add
//   one and this client must never crash or silently reinterpret it as
//   `.working`.
// - `delegation.status` (tui_gateway/methods_session.py:2133) →
//   `{active, paused, max_spawn_depth, max_concurrent_children}`; `active` is
//   `list_active_subagents()` (tools/delegate_tool_registry.py:173), each row
//   the public projection of a registry record with `_PRIVATE_RECORD_KEYS`
//   stripped (agent handle, owner transport/session objects, steer
//   eligibility flag are never serialized).
//
// JOIN-KEY FINDING (owner id ↔ active_list row), evidence below:
// `tools/delegate_tool_child_run.py:328-331` stamps
// `"owner_agent_session_id": str(getattr(child, "_parent_session_id", "")
// or "") or str(getattr(parent_agent, "session_id", "") or "") or None` with
// the comment "Owning conversation's DURABLE session id (same lineage
// completion delivery routes by), sourced from the child's stamp so it
// survives a parent_agent rebuild between dispatch and run." `AIAgent
// .session_id` (cli.py:2833: `self.session_id = resume or
// new_session_id(...)`) is the STORED/resumable session identifier — exactly
// what `_session_lookup_key` (server.py:2731: `getattr(session.get("agent"),
// "session_id", None) or session.get("session_key")`) reports back as
// `active_list`'s `session_key` field, NOT its `id` (runtime sid) field.
// The registry's OTHER, private `owner_session_id` key (never exposed —
// `_PRIVATE_RECORD_KEYS`) is the live gateway/TUI transport-scoped id used
// only for in-process steer-authority capture
// (`_capture_gateway_steer_authority`) — it happens to often equal the
// runtime sid, but the PUBLIC field this client can read is
// `owner_agent_session_id`, and it is durable. Therefore:
//
//     LiveOpsSubagent.parentID  (from delegation.status "parent_id")
//     LiveOperation.sessionKey  (from active_list "session_key")
//
// are the join key — NEVER `LiveOperation.id` (the runtime sid), which can be
// reused/rotated across reconnects and is a coincidence, not a contract.
//
// - `subagent.list` / `subagent.tail` / `subagent.interrupt`
//   (tui_gateway/methods_subagents.py) and `subagent.steer`
//   (methods_session.py:2147) all resolve `_current_session_steer_authority
//   (session_id)` (server.py:847) and fail with JSON-RPC error 4001 ("session
//   not found" / "session not found or not owned by this transport") unless
//   the CALLER's transport is the one currently attached to that live
//   session (`_sess_nowait` / `_sessions.get(sid)` — server.py:1133). This is
//   never a permission check on identity; it is purely "is this transport
//   the one holding the live runtime slot right now." `subagent.steer`
//   answers `{"status": "queued"|"rejected", ...}` on success — "queued" is
//   NOT "delivered" (a child past its last tool batch can still miss it).
//   `subagent.interrupt` answers `{"found": Bool, "subagent_id": ...}`.
//   `subagent.tail` answers `{"available", "text", "truncated"}`, capped at
//   16 KiB server-side.
// - Any UNKNOWN method name answers JSON-RPC -32601 (server.py:758) — this
//   must decode to `.unsupported`, a coverage state, never a hard failure.
// - `session.activate` (methods_session.py, "attach the frontend to a live
//   TUI session") is a MUTATING call — the fleet-wide monitoring path in
//   this file/client must never call it; attaching is a separate, deliberate
//   user action outside Live Ops v1 scope.

// MARK: - Identity

/// Source-qualified identity of one live operation (Hermes session). NEVER
/// keyed by a display name or a bare runtime sid alone: the runtime sid is
/// only unique WITHIN one gateway process, so two different gateways can
/// legitimately report the same `id` for two unrelated sessions. Mirrors the
/// `Route` pattern (`GatewayID` + local component) used across FleetCore.
public struct LiveOperationID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let gatewayID: GatewayID
    /// The gateway's RUNTIME session id (`active_list.id` — process-local,
    /// may be reused across reconnects/restarts; use `sessionKey` for
    /// anything that must survive that).
    public let runtimeSessionID: String

    public init(gatewayID: GatewayID, runtimeSessionID: String) {
        self.gatewayID = gatewayID
        self.runtimeSessionID = runtimeSessionID
    }

    public var description: String { "\(gatewayID.rawValue)/\(runtimeSessionID)" }
}

// MARK: - Status

/// The `active_list.status` vocabulary (`_session_live_status`,
/// server.py:2691). Exactly four known values today; anything else decodes
/// to `.unknown(String)` — never crashes, never silently becomes `.working`.
public enum LiveOperationStatus: Hashable, Sendable {
    case idle
    case starting
    case waiting
    case working
    case unknown(String)

    /// Tolerant decode from the wire string.
    public init(wireValue: String) {
        switch wireValue {
        case "idle": self = .idle
        case "starting": self = .starting
        case "waiting": self = .waiting
        case "working": self = .working
        default: self = .unknown(wireValue)
        }
    }

    /// The wire string this status decoded from (round-trips known cases;
    /// `.unknown` returns the original string verbatim).
    public var wireValue: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .waiting: return "waiting"
        case .working: return "working"
        case .unknown(let raw): return raw
        }
    }

    /// "Active" = the session is doing something or about to (`working`,
    /// `starting`, or `waiting` on the user) — `idle` is excluded, and an
    /// `.unknown` future status is conservatively excluded too (never
    /// fabricate an activity signal from a status this client cannot yet
    /// interpret).
    public var isActive: Bool {
        switch self {
        case .working, .starting, .waiting: return true
        case .idle, .unknown: return false
        }
    }

    public var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }
}

// MARK: - Subagents

/// One row of `delegation.status.active` (`list_active_subagents()`,
/// tools/delegate_tool_registry.py:173) — the public projection with
/// `_PRIVATE_RECORD_KEYS` already stripped server-side (agent handle, owner
/// transport/session objects, steer-eligibility flag never cross the wire).
public struct LiveOpsSubagent: Identifiable, Hashable, Sendable {
    /// `subagent_id` — stable for the life of the child.
    public let subagentID: String
    /// `parent_id` — the parent SUBAGENT's id when nested, `nil` at the root
    /// of a spawn tree (parented directly on the owning operation).
    public let parentID: String?
    /// Nesting depth reported by the registry (0 = directly spawned by the
    /// owning session).
    public let depth: Int
    public let goal: String
    public let model: String?
    public let startedAt: Date
    public let status: String
    public let toolCount: Int
    /// `last_tool` — best-effort label of the most recent tool call, when the
    /// gateway reports one.
    public let lastTool: String?
    /// `accepting_steer` — whether `subagent.steer` currently has anywhere to
    /// deliver text (best-effort UI hint only; the RPC result is always the
    /// authoritative answer).
    public let acceptingSteer: Bool?

    public var id: String { subagentID }

    public init(
        subagentID: String,
        parentID: String?,
        depth: Int,
        goal: String,
        model: String?,
        startedAt: Date,
        status: String,
        toolCount: Int,
        lastTool: String? = nil,
        acceptingSteer: Bool? = nil
    ) {
        self.subagentID = subagentID
        self.parentID = parentID
        self.depth = depth
        self.goal = goal
        self.model = model
        self.startedAt = startedAt
        self.status = status
        self.toolCount = toolCount
        self.lastTool = lastTool
        self.acceptingSteer = acceptingSteer
    }
}

/// One node of the reconstructed parent → child swarm tree
/// (`LiveOpsSnapshotReducer.swarmTree`).
public struct LiveOpsSwarmNode: Identifiable, Hashable, Sendable {
    public let subagent: LiveOpsSubagent
    public let children: [LiveOpsSwarmNode]

    public var id: String { subagent.id }

    public init(subagent: LiveOpsSubagent, children: [LiveOpsSwarmNode]) {
        self.subagent = subagent
        self.children = children
    }
}

// MARK: - Operations (sessions)

/// One row of `session.active_list.sessions` joined (best-effort) with any
/// `delegation.status` children whose `owner_agent_session_id` matches this
/// operation's `sessionKey` (see the join-key finding at file top — NEVER
/// `id`).
public struct LiveOperation: Identifiable, Hashable, Sendable {
    public let id: LiveOperationID
    /// `session_key` — the durable/stored session id. This, not `id`, is the
    /// join key against subagent ownership.
    public let sessionKey: String
    public let title: String
    public let preview: String
    public let model: String
    public let startedAt: Date
    public let lastActive: Date
    public let messageCount: Int
    public let status: LiveOperationStatus
    /// `nil` when this snapshot could not reach `delegation.status` for this
    /// gateway (e.g. unsupported) — distinct from "known to have zero
    /// subagents" (`[]`).
    public let subagents: [LiveOpsSubagent]?
    /// Cross-process observers have no transport authority over the source session.
    public let observationOnly: Bool

    /// `true` when `subagents` reflects an actual `delegation.status` read;
    /// `false` when the gateway does not support delegation status (the
    /// caller must render "subagents unknown", never "0 subagents").
    public var subagentsKnown: Bool { subagents != nil }

    /// Async delegation can outlive the parent's turn. A registry-reported
    /// running child keeps the operation active even when the parent is idle.
    /// Unknown child statuses and unavailable delegation data are not activity.
    public var isActive: Bool {
        status.isActive || subagents?.contains { $0.status == "running" } == true
    }

    public var isDelegating: Bool { !status.isActive && isActive }

    public init(
        id: LiveOperationID,
        sessionKey: String,
        title: String,
        preview: String,
        model: String,
        startedAt: Date,
        lastActive: Date,
        messageCount: Int,
        status: LiveOperationStatus,
        subagents: [LiveOpsSubagent]? = nil,
        observationOnly: Bool = false
    ) {
        self.id = id
        self.sessionKey = sessionKey
        self.title = title
        self.preview = preview
        self.model = model
        self.startedAt = startedAt
        self.lastActive = lastActive
        self.messageCount = messageCount
        self.status = status
        self.subagents = subagents
        self.observationOnly = observationOnly
    }

    /// Reconstructed swarm tree for this operation's known subagents (`nil`
    /// when `subagents` itself is `nil` — unknown, not empty). Orphans (a
    /// `parentID` that names no live sibling subagent) attach directly at the
    /// operation root rather than being dropped — the child is still real
    /// work happening under this session even if its stated parent already
    /// completed/vanished from the snapshot.
    public var swarmTree: [LiveOpsSwarmNode]? {
        guard let subagents else { return nil }
        return LiveOpsSnapshotReducer.swarmTree(from: subagents)
    }
}

// MARK: - Gateway coverage

/// Why one gateway's Live Ops snapshot may not (or no longer) reflect live
/// truth. Never silently degrades to "0 active" — a non-`.reporting` state
/// must be surfaced as reduced coverage, not as a fact about the fleet.
public enum LiveOpsGatewayCoverage: Hashable, Sendable {
    /// The gateway answered `session.active_list` (and, when available,
    /// `delegation.status`) this refresh.
    case reporting
    /// The gateway answered but does not implement the Live Ops methods
    /// (JSON-RPC -32601 on `session.active_list` itself — distinct from
    /// `delegation.status` merely being unsupported, which keeps
    /// `.reporting` with `subagentsKnown == false` per operation).
    case unsupported
    /// No transport to this gateway right now.
    case disconnected
    /// The gateway rejected the credentials/session used to reach it.
    case authFailed
    /// Any other classified failure. `reason` is a redacted, display-safe
    /// string (`Redaction.safeText`) — never raw transport/error internals,
    /// never a credential.
    case failed(reason: String)

    public var isReporting: Bool {
        if case .reporting = self { return true }
        return false
    }
}

/// Companion-plugin detection, independent of process-local RPC coverage.
/// Only a successful fresh dashboard snapshot establishes reporting.
public enum LiveOpsReportingSetup: Hashable, Sendable {
    case unknown
    case required
    case reporting(backends: Int)
    case unavailable
}

/// One gateway's Live Ops snapshot at a point in time.
public struct LiveOpsGatewaySnapshot: Identifiable, Hashable, Sendable {
    public let gatewayID: GatewayID
    public let coverage: LiveOpsGatewayCoverage
    public let operations: [LiveOperation]
    public let observedAt: Date
    /// Monotonic per-gateway sequence number for the reducer's
    /// stale-cannot-overwrite-newer rule. Two snapshots for the same gateway
    /// are ordered by `generation` first, `observedAt` as a tiebreak only
    /// when generations are equal (e.g. both default to 0 in simple
    /// call sites) — a caller that never sets `generation` still gets
    /// correct ordering from `observedAt` alone.
    public let generation: Int
    /// `true` once this gateway has answered `.reporting` at least once,
    /// EVER — including snapshots now superseded by a later failure. The
    /// reducer carries this forward through `merge` so a currently-`.failed`
    /// gateway that has genuine held-over operations still contributes to
    /// the fleet counts (never collapsing to "partial"/"0" purely because
    /// the MOST RECENT refresh failed). Defaults to `coverage.isReporting`
    /// for direct construction, so ordinary call sites that never touch this
    /// flag get the obviously-correct answer for a single snapshot.
    public let hasEverReported: Bool

    /// Limits of the observer's process/profile scope, independent of transport health.
    public let observationNote: String?
    public let reportingSetup: LiveOpsReportingSetup

    public var id: GatewayID { gatewayID }

    public init(
        gatewayID: GatewayID,
        coverage: LiveOpsGatewayCoverage,
        operations: [LiveOperation],
        observedAt: Date,
        generation: Int = 0,
        hasEverReported: Bool? = nil,
        observationNote: String? = nil,
        reportingSetup: LiveOpsReportingSetup = .unknown
    ) {
        self.gatewayID = gatewayID
        self.observationNote = observationNote
        self.reportingSetup = reportingSetup
        self.coverage = coverage
        self.operations = operations
        self.observedAt = observedAt
        self.generation = generation
        self.hasEverReported = hasEverReported ?? coverage.isReporting
    }

    /// Ordering used by the reducer: strictly newer generation wins; on a
    /// tie, strictly newer `observedAt` wins. Equal on both is NOT newer
    /// (a retry/duplicate must not count as an update).
    func isNewer(than other: LiveOpsGatewaySnapshot) -> Bool {
        if generation != other.generation { return generation > other.generation }
        return observedAt > other.observedAt
    }
}

// MARK: - Fleet aggregate

/// Marker for a count that cannot be honestly reported because at least one
/// gateway has never reported (as opposed to a real, observed zero).
public enum LiveOpsCount: Hashable, Sendable {
    case known(Int)
    case partial

    /// The known value, or `nil` when partial (never fabricates a number).
    public var value: Int? {
        if case .known(let n) = self { return n }
        return nil
    }

    public var isPartial: Bool {
        if case .partial = self { return true }
        return false
    }
}

/// Aggregate Live Ops view across every registered gateway.
public struct LiveOpsSnapshot: Sendable {
    public let gateways: [LiveOpsGatewaySnapshot]

    public init(gateways: [LiveOpsGatewaySnapshot]) {
        self.gateways = gateways
    }

    /// Every operation across every gateway that has EVER reported
    /// (`hasEverReported`) — a currently-failed gateway's held-over
    /// operations (kept by the reducer's failure rule) are still listed;
    /// only gateways with NO trustworthy data at all contribute nothing.
    public var allOperations: [LiveOperation] {
        gateways.filter(\.hasEverReported).flatMap(\.operations)
    }

    /// `true` when every gateway in this snapshot is CURRENTLY `.reporting`
    /// — i.e. the counts below reflect a live read of the whole fleet, not a
    /// subset or stale data. This is stricter than `hasEverReported`: a
    /// gateway with good held-over data from a past success but a failed
    /// CURRENT refresh makes coverage incomplete even though counts still
    /// include its last-good operations.
    public var isCoverageComplete: Bool {
        !gateways.isEmpty && gateways.allSatisfy { $0.coverage.isReporting }
    }

    public var reportingGatewayCount: Int {
        gateways.filter { $0.coverage.isReporting }.count
    }

    /// Gateways whose `operations` are currently trustworthy enough to fold
    /// into the fleet counts below: either reporting right now, or carrying
    /// held-over data from a past successful report (`hasEverReported`).
    private var gatewaysWithData: [LiveOpsGatewaySnapshot] {
        gateways.filter(\.hasEverReported)
    }

    /// Active parents or parents with running delegated children (see
    /// `LiveOperation.isActive`). `.partial` when NO gateway has ever
    /// reported (an empty snapshot, or every gateway with zero trustworthy
    /// history) — NEVER `.known(0)` in that case, since "the fleet reported
    /// zero active operations" and "the fleet has never been heard from"
    /// must render differently. A gateway whose most recent refresh failed
    /// but still holds last-good operations keeps contributing here (the
    /// reducer's rule 2) — a failure alone must never zero out this count.
    public var activeCount: LiveOpsCount {
        guard !gatewaysWithData.isEmpty else { return .partial }
        return .known(allOperations.filter(\.isActive).count)
    }

    public var waitingCount: LiveOpsCount {
        guard !gatewaysWithData.isEmpty else { return .partial }
        return .known(allOperations.filter { $0.status.isWaiting }.count)
    }

    /// Total known subagents across every operation that HAS a known
    /// subagent count. `.partial` when no gateway has trustworthy data at
    /// all, OR when every such gateway's operations all have
    /// `subagentsKnown == false` (delegation status unavailable everywhere).
    public var subagentCount: LiveOpsCount {
        guard !gatewaysWithData.isEmpty else { return .partial }
        let known = allOperations.compactMap(\.subagents)
        guard !known.isEmpty else { return .partial }
        return .known(known.reduce(0) { $0 + $1.count })
    }
}

// MARK: - Attention (Needs You integration)

/// One live operation currently in `.waiting` status, plus the pending
/// dangerous-command approval that explains it when one exists (approvals
/// are read via the existing `ApprovalsProviding.pendingApprovals` seam —
/// this type never duplicates that fetch, only carries the joined result).
public struct LiveOpsAttentionItem: Identifiable, Hashable, Sendable {
    public let operation: LiveOperation
    public let pendingApproval: ApprovalRequest?

    public var id: LiveOperationID { operation.id }

    public init(operation: LiveOperation, pendingApproval: ApprovalRequest? = nil) {
        self.operation = operation
        self.pendingApproval = pendingApproval
    }
}

// MARK: - Providing seams

/// Fleet-wide, per-gateway READ-ONLY observation. Implementations MUST NOT
/// call `session.activate` or any other mutating/attaching RPC — this seam
/// only ever reads `session.active_list` (+ `delegation.status` when
/// available). FleetUI depends only on this protocol; the concrete
/// WebSocket-backed client lives in FleetNetworking.
public protocol LiveOpsProviding: Sendable {
    /// One gateway's current Live Ops snapshot. Implementations classify
    /// every failure into `LiveOpsGatewayCoverage` — this method itself
    /// should not throw for ordinary unreachability/unsupported-method
    /// cases; those are coverage states, not thrown errors.
    func snapshot(gateway: GatewayID) async -> LiveOpsGatewaySnapshot
}

/// Detailed child controls for ONE session the caller's transport is
/// currently ATTACHED to. Every method fails closed with
/// `LiveOpsControlError.notAttached` when the gateway reports 4001 (transport
/// not the one holding the live session slot) — this is never surfaced as a
/// generic RPC failure, since callers use it to decide whether to prompt the
/// user to attach first.
public protocol LiveOpsSubagentControlling: Sendable {
    /// `subagent.list` for the attached session.
    func listSubagents(sessionID: String) async throws -> [LiveOpsSubagent]

    /// `subagent.tail` — bounded (≤16 KiB) recent transcript text for one
    /// child.
    func tail(subagentID: String, sessionID: String) async throws -> LiveOpsSubagentTail

    /// `subagent.steer` — queue text into a live child. "queued" is not
    /// "delivered" (see file-top wire note).
    func steer(subagentID: String, sessionID: String, text: String) async throws -> LiveOpsSteerResult

    /// `subagent.interrupt` — hard-interrupt one child.
    /// - Returns: whether the gateway found (and attempted to interrupt) a
    ///   live child with this id.
    func interrupt(subagentID: String, sessionID: String) async throws -> Bool
}

/// `subagent.tail` result (`{available, text, truncated}`).
public struct LiveOpsSubagentTail: Hashable, Sendable {
    public let available: Bool
    public let text: String
    public let truncated: Bool

    public init(available: Bool, text: String, truncated: Bool) {
        self.available = available
        self.text = text
        self.truncated = truncated
    }
}

/// `subagent.steer` result (`{"status": "queued"|"rejected"}`).
public enum LiveOpsSteerResult: String, Hashable, Sendable {
    case queued
    case rejected
}

/// Errors from the subagent-control seam (distinct from `ConversationError`:
/// this seam's defining failure mode — "your transport is not attached to
/// this session" — has no equivalent there).
public enum LiveOpsControlError: Error, Sendable, Equatable, LocalizedError {
    /// The gateway does not implement this method (JSON-RPC -32601).
    case unsupported
    /// No transport to the gateway.
    case notConnected
    /// JSON-RPC 4001: the caller's transport is not the one attached to the
    /// live session — list/tail/interrupt/steer all fail closed this way
    /// rather than guessing at partial authority.
    case notAttached
    /// The gateway rejected authentication for this transport.
    case authFailed(String)
    /// Any other classified RPC failure (redacted, display-safe).
    case rpcFailed(String)
    /// The gateway's response could not be decoded into the expected shape.
    case malformedPayload(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "gateway does not support this operation"
        case .notConnected: return "gateway not connected"
        case .notAttached: return "not attached to this session"
        case .authFailed(let s): return "authentication failed: \(s)"
        case .rpcFailed(let s): return "request failed: \(s)"
        case .malformedPayload(let s): return "malformed response: \(s)"
        }
    }
}

// MARK: - Pure reducer

/// Pure merge/aggregation logic for Live Ops snapshots — no I/O, fully unit
/// testable. Owns the two truth rules a live client must never violate:
/// 1. A snapshot with an older generation/observedAt for a gateway can never
///    overwrite a newer one already held for that gateway (protects against
///    out-of-order delivery on retry/reconnect).
/// 2. A failed refresh for a gateway keeps that gateway's last-good
///    operations (never resets to `[]`/"0 active") while marking coverage as
///    the failure — the UI can then show "stale as of <time>" instead of a
///    fabricated empty fleet.
public enum LiveOpsSnapshotReducer {

    /// Merge one freshly observed gateway snapshot into an existing fleet
    /// snapshot, applying both truth rules above.
    ///
    /// - Parameters:
    ///   - incoming: the just-fetched snapshot for one gateway.
    ///   - previous: the fleet snapshot held before this refresh (may be
    ///     `nil` on first load).
    public static func merge(
        incoming: LiveOpsGatewaySnapshot,
        into previous: LiveOpsSnapshot?
    ) -> LiveOpsSnapshot {
        var gateways = previous?.gateways ?? []
        guard let index = gateways.firstIndex(where: { $0.gatewayID == incoming.gatewayID }) else {
            gateways.append(incoming)
            return LiveOpsSnapshot(gateways: gateways)
        }

        let existing = gateways[index]
        // Rule 1: staleness — an incoming snapshot that is not strictly newer
        // than what is already held is dropped outright (the existing entry
        // wins unchanged).
        guard incoming.isNewer(than: existing) else {
            return LiveOpsSnapshot(gateways: gateways)
        }

        // Rule 2: a failed/non-reporting refresh keeps the last-good
        // operations list rather than replacing it with whatever (possibly
        // empty) list came back with the failure.
        let resolvedOperations = incoming.coverage.isReporting ? incoming.operations : existing.operations
        // A gateway that was EVER reporting keeps contributing to fleet
        // counts through a subsequent failure (rule 2) — the flag only ever
        // turns on, never off, within one reducer chain.
        let hasEverReported = incoming.coverage.isReporting || existing.hasEverReported
        gateways[index] = LiveOpsGatewaySnapshot(
            gatewayID: incoming.gatewayID,
            coverage: incoming.coverage,
            operations: resolvedOperations,
            observedAt: incoming.observedAt,
            generation: incoming.generation,
            hasEverReported: hasEverReported,
            observationNote: incoming.coverage.isReporting ? incoming.observationNote
                : incoming.observationNote ?? existing.observationNote,
            reportingSetup: incoming.reportingSetup == .unknown && !incoming.coverage.isReporting
                ? existing.reportingSetup : incoming.reportingSetup
        )
        return LiveOpsSnapshot(gateways: gateways)
    }

    /// Build a parent → child swarm tree from a flat subagent list. Ordering
    /// is deterministic (stable sort by `subagentID`) so two callers building
    /// from the same input always get the same tree shape — no dependency on
    /// dictionary/set iteration order.
    ///
    /// Orphan handling: a subagent whose `parentID` names no OTHER subagent
    /// in this same list (its declared parent already completed, or it is a
    /// root child directly under the owning operation) is attached as a ROOT
    /// node of the returned forest — never dropped, never silently
    /// reparented onto an unrelated sibling.
    public static func swarmTree(from subagents: [LiveOpsSubagent]) -> [LiveOpsSwarmNode] {
        let byID = Dictionary(uniqueKeysWithValues: subagents.map { ($0.subagentID, $0) })
        var childrenOf: [String: [LiveOpsSubagent]] = [:]
        var roots: [LiveOpsSubagent] = []

        for subagent in subagents {
            if let parentID = subagent.parentID, byID[parentID] != nil {
                childrenOf[parentID, default: []].append(subagent)
            } else {
                // No parent, or a parent id not present in this snapshot
                // (orphan) — both cases become roots.
                roots.append(subagent)
            }
        }

        func buildNode(_ subagent: LiveOpsSubagent) -> LiveOpsSwarmNode {
            let children = (childrenOf[subagent.subagentID] ?? [])
                .sorted { $0.subagentID < $1.subagentID }
                .map(buildNode)
            return LiveOpsSwarmNode(subagent: subagent, children: children)
        }

        return roots.sorted { $0.subagentID < $1.subagentID }.map(buildNode)
    }
}
