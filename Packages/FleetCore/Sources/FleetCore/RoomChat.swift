import Foundation

/// True Bots Mode slice 4 (D15/D16/D18) — interactive room chat domain.
///
/// Pure FleetCore logic over the shapes landed in slice 1: the FleetUI room
/// view model renders ONLY what these types compute from real provider/client
/// output. Every mutation is gated on `RoomCapabilities` BEFORE any write is
/// attempted (binding addendum: capability-disabled mutations never issue
/// writes). Gateway orchestration stays authoritative — Fleet never
/// reimplements turn loops, retries, or approvals.

// MARK: - Wire seams (implemented app-side / FleetNetworking-side)

/// Interactive commands for one hosted room — the exact `groups.*` surface
/// (upstream methods_groups.py; all operations idempotent or fenced by the
/// gateway). `RoomChatViewModel` calls through this seam; the concrete
/// implementation wraps `GatewayGroupsClient`, and UI tests get a scripted
/// in-memory one. Methods throw `GroupsError`-shaped failures — the seam is
/// declared in FleetCore so FleetUI NEVER imports FleetNetworking.
public protocol RoomChatCommanding: Sendable {
    /// `groups.log` since_seq paging. `sinceSeq` 0 = full replay.
    func replay(roomID: String, sinceSeq: Int, limit: Int) async throws -> RoomLogPageSlice
    /// `groups.send` with a client-minted event id.
    func send(roomID: String, text: String, threadID: String?) async throws -> Int
    /// `groups.rename`.
    func rename(roomID: String, name: String) async throws
    /// `groups.disband` (tombstone — final).
    func disband(roomID: String) async throws
    /// `groups.stop` → cancelled count.
    func stop(roomID: String) async throws -> Int
    /// `groups.retry` for one retryable task.
    func retry(roomID: String, taskID: String) async throws
    /// `groups.approve` (choice "once" | "deny").
    func approve(roomID: String, action: RoomPendingApproval, choice: String) async throws
}

/// Client-facing copy of the `groups.log` page (FleetNetworking decodes the
/// wire row into these FleetCore values).
public struct RoomLogPageSlice: Sendable {
    public let events: [HostedRoomEventValue]
    public let cursor: Int
    public let latestSeq: Int
    public let hasMore: Bool
    public let authorityGatewayID: String
    public let authorityEpoch: Int

    public init(
        events: [HostedRoomEventValue],
        cursor: Int,
        latestSeq: Int,
        hasMore: Bool,
        authorityGatewayID: String,
        authorityEpoch: Int
    ) {
        self.events = events
        self.cursor = cursor
        self.latestSeq = latestSeq
        self.hasMore = hasMore
        self.authorityGatewayID = authorityGatewayID
        self.authorityEpoch = authorityEpoch
    }
}

/// One durable hosted-room event, normalized (kind vocabulary:
/// gateway/hosted_rooms.py:48-57).
public struct HostedRoomEventValue: Hashable, Sendable, Identifiable {
    public let roomID: String
    public let seq: Int
    public let eventID: String
    public let kind: String
    public let actorKind: String
    public let actorID: String
    public let actorDisplayName: String?
    public let actorProfile: String?
    public let actorConnectionID: String?
    public let payloadText: String?
    /// turn.failed optional `reason_code` (shared failure vocabulary,
    /// gateway/hosted_room_discussion.py:57,385-393).
    public let reasonCode: String?
    public let createdAt: Double

    public init(
        roomID: String,
        seq: Int,
        eventID: String,
        kind: String,
        actorKind: String,
        actorID: String,
        actorDisplayName: String? = nil,
        actorProfile: String? = nil,
        actorConnectionID: String? = nil,
        payloadText: String? = nil,
        reasonCode: String? = nil,
        createdAt: Double
    ) {
        self.roomID = roomID
        self.seq = seq
        self.eventID = eventID
        self.kind = kind
        self.actorKind = actorKind
        self.actorID = actorID
        self.actorDisplayName = actorDisplayName
        self.actorProfile = actorProfile
        self.actorConnectionID = actorConnectionID
        self.payloadText = payloadText
        self.reasonCode = reasonCode
        self.createdAt = createdAt
    }

    public var id: String { "\(roomID)#\(seq)" }
}

/// `driver_status.pending_actions` approval entry (hosted_room_service.py
/// status(): {kind:"approval", task_id, execution_generation, run_id,
/// session_id, request_id, approval:{…,choices:["once","deny"]}}).
public struct RoomPendingApproval: Hashable, Sendable, Identifiable {
    public let memberID: String
    public let taskID: String
    public let executionGeneration: Int
    public let runID: String?
    public let sessionID: String?
    public let requestID: String?
    /// Wire approval object (prompt/summary etc.) — displayed verbatim,
    /// never re-derived.
    public let approval: [String: MetadataValue]

    public var id: String { "\(memberID)#\(taskID)#\(executionGeneration)" }

    public init(
        memberID: String,
        taskID: String,
        executionGeneration: Int,
        runID: String? = nil,
        sessionID: String? = nil,
        requestID: String? = nil,
        approval: [String: MetadataValue] = [:]
    ) {
        self.memberID = memberID
        self.taskID = taskID
        self.executionGeneration = executionGeneration
        self.runID = runID
        self.sessionID = sessionID
        self.requestID = requestID
        self.approval = approval
    }
}

/// `driver_status.pending_actions` retry entry ({kind:"retry", task_id}).
public struct RoomPendingRetry: Hashable, Sendable, Identifiable {
    public let taskID: String
    public var id: String { taskID }

    public init(taskID: String) {
        self.taskID = taskID
    }
}

/// `driver_status` normalized (hosted_room_service.py status() shape).
public struct RoomDriverStatus: Sendable {
    public let working: Bool
    public let blocked: Bool
    public let counts: [String: Int]
    public let pendingRetries: [RoomPendingRetry]
    public let pendingApprovals: [RoomPendingApproval]

    public init(
        working: Bool,
        blocked: Bool,
        counts: [String: Int],
        pendingRetries: [RoomPendingRetry],
        pendingApprovals: [RoomPendingApproval]
    ) {
        self.working = working
        self.blocked = blocked
        self.counts = counts
        self.pendingRetries = pendingRetries
        self.pendingApprovals = pendingApprovals
    }
}

/// Seam for the driver-status half of D16 (implemented over `groups.state`).
public protocol RoomDriverStatusProviding: Sendable {
    func driverStatus(roomID: String) async throws -> RoomDriverStatus?
}

// MARK: - Typed room-command failures

/// Typed failures for room commands. Mirrors the `GroupsError` cases the
/// FleetNetworking client produces so FleetUI can branch on typed truth
/// without importing the transport module.
public enum RoomCommandFailure: Error, Equatable, Sendable {
    /// Gateway lacks the method (old gateway) — update-gateway copy.
    case unsupportedMethod(String)
    /// Room is owned by another gateway (authority moved).
    case foreignAuthority(String)
    /// Promotion/confirm-required class (4118).
    case confirmRequired(String)
    /// RPC failed (message + code).
    case rpcFailed(String, Int)
    /// Transport not connected.
    case notConnected

    /// Plain-language explanation shown to the user (non-secret).
    public var explanation: String {
        switch self {
        case .unsupportedMethod:
            return "This gateway doesn't support that yet — update the gateway to use it."
        case .foreignAuthority:
            return "Another gateway now owns this room. Reload to see its new authority."
        case .confirmRequired:
            return "This action needs an explicit confirmation. Reload the room and try again."
        case .rpcFailed(let message, _):
            return message
        case .notConnected:
            return "Gateway connection is down. Reconnect and try again."
        }
    }

    /// Whether the honest recovery is reload-the-room (authority drift).
    public var requiresReload: Bool {
        switch self {
        case .foreignAuthority, .confirmRequired: return true
        default: return false
        }
    }
}

// MARK: - Transcript projection

/// A transcript entry projected from durable room events. Only kinds with
/// user-facing rendering become rows; control events surface through
/// attention/failure state instead of fake chat bubbles.
public struct RoomTranscriptEntry: Hashable, Sendable, Identifiable {
    public enum Flavor: Hashable, Sendable {
        /// message.user / message.member
        case message(isUser: Bool)
        /// turn.failed terminal event.
        case failure
    }

    public let id: String
    public let seq: Int
    public let flavor: Flavor
    public let speaker: String
    /// Non-nil for message flavors (rendered text).
    public let text: String?
    /// Typed failure reason for the .failure flavor.
    public let failure: TypedBotFailure?
    public let createdAt: Double

    init(
        id: String,
        seq: Int,
        flavor: Flavor,
        speaker: String,
        text: String?,
        failure: TypedBotFailure?,
        createdAt: Double
    ) {
        self.id = id
        self.seq = seq
        self.flavor = flavor
        self.speaker = speaker
        self.text = text
        self.failure = failure
        self.createdAt = createdAt
    }
}

/// Pure projection: durable events → transcript rows + attention state.
/// Deterministic, order-preserving (durable log order), tolerant of unknown
/// kinds (skipped — never invented).
public struct RoomTranscriptProjection: Sendable {
    public let entries: [RoomTranscriptEntry]
    /// Latest typed failure across the log (retryable-failure surface).
    public let latestFailure: TypedBotFailure?
    /// Latest task still in an indeterminate state (turn.deferred / no
    /// terminal event after a started) — honest "outcome unknown" surface.
    public let indeterminateTaskID: String?
    /// Any room.stop_requested event present in the window.
    public let stopRequested: Bool

    public init(
        entries: [RoomTranscriptEntry],
        latestFailure: TypedBotFailure?,
        indeterminateTaskID: String?,
        stopRequested: Bool
    ) {
        self.entries = entries
        self.latestFailure = latestFailure
        self.indeterminateTaskID = indeterminateTaskID
        self.stopRequested = stopRequested
    }

    /// Kinds that render as chat bubbles.
    static let messageKinds: Set<String> = ["message.user", "message.member"]
    /// Gateway control kinds surfaced structurally (not as bubbles).
    static let controlKinds: Set<String> = [
        "turn.failed", "turn.deferred", "turn.cancelled", "turn.settled",
        "turn.started", "turn.reassigned", "member.unavailable", "room.activity",
        "room.stop_requested", "authority.claimed", "authority.lost",
        "room.created", "room.disbanded", "room.members_changed", "room.renamed",
    ]

    public static func project(_ events: [HostedRoomEventValue]) -> RoomTranscriptProjection {
        var entries: [RoomTranscriptEntry] = []
        var latestFailure: TypedBotFailure?
        var indeterminate: String?
        var stopRequested = false

        for event in events {
            if messageKinds.contains(event.kind) {
                entries.append(RoomTranscriptEntry(
                    id: event.id,
                    seq: event.seq,
                    flavor: .message(isUser: event.kind == "message.user"),
                    speaker: event.actorDisplayName ?? event.actorProfile ?? event.actorID,
                    text: event.payloadText,
                    failure: nil,
                    createdAt: event.createdAt
                ))
            } else if event.kind == "turn.failed" {
                let failure = TypedBotFailure(
                    wireReason: event.reasonCode ?? "unknown",
                    message: event.payloadText)
                latestFailure = failure
                entries.append(RoomTranscriptEntry(
                    id: event.id,
                    seq: event.seq,
                    flavor: .failure,
                    speaker: event.actorProfile ?? event.actorID,
                    text: event.payloadText,
                    failure: failure,
                    createdAt: event.createdAt
                ))
            } else if event.kind == "turn.deferred" {
                indeterminate = event.payloadText ?? indeterminate
            } else if event.kind == "room.stop_requested" {
                stopRequested = true
            }
            // Unknown / other control kinds: skipped (no invented rendering).
        }

        return RoomTranscriptProjection(
            entries: entries,
            latestFailure: latestFailure,
            indeterminateTaskID: indeterminate,
            stopRequested: stopRequested
        )
    }
}

// MARK: - Durable replay cache

/// In-memory durable-log cache per room: merges pages by seq, de-duplicates
/// event ids (idempotent replays), and keeps a cursor so re-entry issues
/// `groups.log` since_seq — the transcript survives navigation/reconnect
/// through provider replay (D17 support; gateway remains authoritative).
public struct RoomTranscriptCache: Sendable {
    public private(set) var eventsBySeq: [Int: HostedRoomEventValue] = [:]
    public private(set) var cursor = 0
    public private(set) var latestSeq = 0

    public init() {}

    /// Merge one page. Returns true when new events were added.
    @discardableResult
    public mutating func merge(_ page: RoomLogPageSlice) -> Bool {
        var added = false
        for event in page.events where eventsBySeq[event.seq] == nil {
            eventsBySeq[event.seq] = event
            added = true
        }
        cursor = max(cursor, page.cursor)
        latestSeq = max(latestSeq, page.latestSeq)
        return added
    }

    /// Events in durable order.
    public var orderedEvents: [HostedRoomEventValue] {
        eventsBySeq.values.sorted { $0.seq < $1.seq }
    }

    /// The since_seq for the next incremental fetch.
    public var nextSinceSeq: Int { cursor }
}

// MARK: - Create-room draft (D15)

/// Member picker candidate: a bot already source-qualified by its owning
/// `Route` (gateway + profile) — two same-name profiles on two gateways are
/// distinct candidates and stay distinct through creation (D18).
public struct RoomMemberCandidate: Hashable, Sendable, Identifiable {
    public let route: Route
    public let displayName: String
    public var id: String { route.id }

    public init(route: Route, displayName: String) {
        self.route = route
        self.displayName = displayName
    }
}

/// Pure create-room form state: name bounds and the 2-6 frozen-roster rule
/// (gateway/hosted_room_discussion.py validate_roster).
public struct RoomCreateDraft: Sendable {
    public static let minMembers = 2
    public static let maxMembers = 6
    /// MAX_ROOM_NAME_CHARS (hosted_rooms.py:26).
    public static let maxNameLength = 200

    public var name: String
    /// Selected candidates in pick order (deterministic member list).
    public var members: [RoomMemberCandidate]

    public init(name: String = "", members: [RoomMemberCandidate] = []) {
        self.name = name
        self.members = members
    }

    /// Honest validation state; nil = submittable.
    public var validationMessage: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name the room." }
        if trimmed.count > Self.maxNameLength {
            return "Room name is too long (max \(Self.maxNameLength) characters)."
        }
        if members.count < Self.minMembers {
            return "Pick at least \(Self.minMembers) members."
        }
        if members.count > Self.maxMembers {
            return "Rooms hold at most \(Self.maxMembers) members."
        }
        return nil
    }

    public var canSubmit: Bool { validationMessage == nil }

    /// Toggle membership (pick order preserved; first tap = first member).
    public mutating func toggle(_ candidate: RoomMemberCandidate) {
        if let index = members.firstIndex(where: { $0.id == candidate.id }) {
            members.remove(at: index)
        } else if members.count < Self.maxMembers {
            members.append(candidate)
        }
    }
}

/// Member wire encoding for `groups.create` — the FROZEN-ROSTER shape from
/// gateway/hosted_room_discussion.py `_validate_member` / hosted_room_service
/// `create_room` (exact fields member_id/profile/handle, optional
/// display_name; local targets are implicit).
public enum HostedRoomMemberCodec {
    static let identifierPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._:-]*$")

    /// Wire members for a set of same-gateway bot candidates.
    /// member_id: "fleet-<gateway>-<slug>" (unique per candidate by Route
    /// identity; matches IDENTIFIER_RE). handle: the profile slug (unique
    /// per roster — duplicates would fail closed server-side).
    public static func wireMembers(
        _ candidates: [RoomMemberCandidate], gatewayID: GatewayID
    ) -> [[String: String]] {
        candidates.map { candidate in
            var member: [String: String] = [
                "member_id": "fleet-\(gatewayID.rawValue)-\(candidate.route.profileSlug.rawValue)",
                "profile": candidate.route.profileSlug.rawValue,
                "handle": candidate.route.profileSlug.rawValue,
            ]
            if !candidate.displayName.isEmpty {
                member["display_name"] = candidate.displayName
            }
            return member
        }
    }

    /// Local validation against the upstream IDENTIFIER_RE
    /// (hosted_rooms_common.py:19) — catches invalid slugs before the wire.
    public static func isValidIdentifier(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return identifierPattern.firstMatch(in: value, range: range) != nil
    }
}

// MARK: - Member display (D18)

/// Source-qualified member display: gateway + profile identity never
/// collapses. Two "Researcher" members on two gateways render as distinct
/// labeled rows; same-name hosted and legacy rooms stay separate rooms
/// (FleetRoomID already makes that structural).
public enum RoomMemberDisplay {
    /// Display label for a member row. Source-qualified by construction:
    /// the gateway label rides alongside (cross-machine identity visible).
    public static func label(
        for member: FleetRoomMember, gatewayLabel: String
    ) -> String {
        member.name
    }

    /// Sub-label carrying the source qualifier (gateway label — the
    /// machine identity the profile lives on).
    public static func sourceQualifier(
        for member: FleetRoomMember, gatewayLabel: String
    ) -> String {
        if member.connectionLabel != nil {
            return "\(gatewayLabel) · linked"
        }
        return gatewayLabel
    }

    /// Distinctness check used by tests/UI: same display name on two
    /// gateways must never collapse to one row.
    public static func areDistinct(
        _ a: FleetRoomMember, gatewayA: String, _ b: FleetRoomMember, gatewayB: String
    ) -> Bool {
        if a.name != b.name { return true }
        return gatewayA != gatewayB
    }
}
