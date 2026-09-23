import Foundation
import FleetCore

/// Phone-bridged room relay: implements the existing `RoomChatCommanding`
/// seam for bridged rooms so `RoomChatViewModel` renders and drives them with
/// ZERO view changes.
///
/// One relay instance serves the bridged scope; every method is driven by the
/// `roomID` parameter (the room's storage key) — the relay itself holds no
/// per-room identity. Sequence numbers are allocated on the main actor
/// (serialized) and lazily synced from the store's latest event.
///
/// - `replay` serves pages from the local store (hosted event vocabulary).
/// - `send` persists the user message and returns IMMEDIATELY (the composer
///   never blocks on member turns); the fan-out runs as detached per-member
///   tails that land replies and failure notes in the store as they close.
/// - `send` HONORS the caller's idempotency key (at-most-once): the key is
///   the local event id, so a retry of one logical message neither appends a
///   second user event nor re-runs the member fan-out.
/// - Reply collection is an INACTIVITY window, not a turn cap: any streamed
///   event on the member's session extends the deadline (real agentic turns
///   run 3-4 minutes while streaming). A timed-out member stays watched for
///   a late `message.complete` within `lateCollectionWindow` — the failure
///   note lands first (honest interim state), the late reply appends after.
/// - `rename` / `disband` are local record updates (disband = final
///   tombstone, matching the hosted contract).
/// - `stop` cancels the room's live tails; `retry` repeats the failed
///   member's turn using the existing user message without a duplicate row.
@MainActor
public final class BridgedRoomRelay: RoomChatCommanding {
    /// Resolves the conversation session for a gateway (the environment's
    /// cached per-gateway bundle).
    public typealias SessionResolver = @Sendable (GatewayID) async -> (any ConversationSessionProviding)?

    private let store: BridgedRooms.Store
    private let resolver: SessionResolver
    /// Per-member INACTIVITY window: the member must produce a streamed
    /// event at least this often to keep its collection window open.
    private let memberTimeout: TimeInterval
    /// Whole-turn budget (from submit) for which a member stays watched,
    /// including the late-collection phase after a timeout note.
    private let lateCollectionWindow: TimeInterval
    /// Live fan-out tails: room storage key -> route id -> tail. A new send
    /// for the same member cancels its previous tail (the newest turn
    /// supersedes); `stop` cancels every tail for the room. A tail REMOVES its
    /// own slot when it finishes (token-guarded, so a superseded tail can
    /// never prune the newer one that replaced it) — a completed turn must not
    /// be retained for the relay's lifetime.
    private struct MemberTail {
        let task: Task<Void, Never>
        let token: UUID
    }

    private var memberTails: [String: [String: MemberTail]] = [:]
    private var nextSeq = 1

    public init(
        store: BridgedRooms.Store,
        resolver: @escaping SessionResolver,
        memberTimeout: TimeInterval = 120,
        lateCollectionWindow: TimeInterval = 900
    ) {
        self.store = store
        self.resolver = resolver
        self.memberTimeout = memberTimeout
        self.lateCollectionWindow = lateCollectionWindow
    }

    /// Sync the seq counter past the store's latest event for a room.
    private func syncSeq(roomID: String, latest: Int?) {
        if let latest {
            nextSeq = max(nextSeq, latest + 1)
        }
    }

    // MARK: - RoomChatCommanding

    public func replay(roomID: String, sinceSeq: Int, limit: Int) async throws -> RoomLogPageSlice {
        guard let record = await store.record(roomKey: roomID) else {
            throw RoomCommandFailure.notConnected
        }
        syncSeq(roomID: roomID, latest: record.events.last?.seq)
        let page = record.events
            .filter { $0.seq > sinceSeq }
            .prefix(limit)
            .map { $0.hostedEvent(roomKey: roomID) }
        return RoomLogPageSlice(
            events: Array(page),
            cursor: page.last?.seq ?? sinceSeq,
            latestSeq: record.events.last?.seq ?? 0,
            hasMore: record.events.contains { $0.seq > (page.last?.seq ?? sinceSeq) },
            authorityGatewayID: BridgedRooms.gatewayScope.rawValue,
            authorityEpoch: 1)
    }

    /// Live transcript feed for one bridged room: the store's change
    /// notification, filtered to this room. `RoomChatViewModel` subscribes
    /// so member replies render without re-entering the screen.
    ///
    /// `store.changes()` is nonisolated and registers its subscriber
    /// SYNCHRONOUSLY, so it is taken HERE — on the caller's turn — not inside
    /// the iteration task: the caller (`RoomChatView.start()`) subscribes and
    /// then immediately reads the store, and an append landing between that
    /// read and a deferred registration would be missed outright (the feed
    /// has no replay).
    public func transcriptChanges(roomID: String) -> AsyncStream<Void>? {
        let changes = store.changes()
        return AsyncStream<Void> { continuation in
            let task = Task {
                for await key in changes {
                    guard !Task.isCancelled else { break }
                    if key == roomID {
                        continuation.yield()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `send` without a caller-supplied key: the relay mints its own local
    /// event id (the pre-key behavior, unchanged).
    public func send(roomID: String, text: String, threadID: String?) async throws -> Int {
        try await send(roomID: roomID, text: text, threadID: threadID, idempotencyKey: nil)
    }

    /// Key-bearing send — the `RoomChatCommanding` at-most-once overload. The
    /// caller's `idempotencyKey` IS this message's local event id, so a retry
    /// of ONE logical message finds its event already durable and returns it
    /// WITHOUT a second `message.user` append and WITHOUT re-running the
    /// member fan-out (the obligation the protocol's compatibility default
    /// cannot meet).
    ///
    /// The lookup reads the STORE, not relay memory, so the guarantee holds
    /// across relay reconstruction (gateway reconnect / app relaunch) — the
    /// retry that matters most is the one after an indeterminate transport
    /// failure, which is exactly when the relay may be a new instance.
    /// Same-key sends are the caller's SEQUENTIAL retries (`RoomChatView`
    /// reuses one pending id per logical message and never overlaps them);
    /// the key alone identifies the message, so the text is not re-matched.
    public func send(
        roomID: String, text: String, threadID: String?, idempotencyKey: String?
    ) async throws -> Int {
        guard let record = await store.record(roomKey: roomID) else {
            throw RoomCommandFailure.notConnected
        }
        // Disband is a FINAL tombstone (the hosted contract). The record stays
        // projected (`isDeleted: false`) so the room remains readable, so the
        // seam — not the projection — has to refuse the write: without this a
        // send into a tombstone persists a user message and spawns tails that
        // can never answer. The refusal guards run BEFORE the dedupe: a
        // tombstoned room accepts no write, keyed or not.
        guard record.disbandedAt == nil else {
            throw RoomCommandFailure.rpcFailed(
                "This Group was disbanded — it no longer accepts messages.", 0)
        }
        syncSeq(roomID: roomID, latest: record.events.last?.seq)

        // At-most-once: a keyed retry whose event is already in the log is a
        // no-op that reports the original seq — no append, no fan-out, no
        // new member turn.
        if let idempotencyKey,
           let landed = record.events.last(where: {
               $0.kind == "message.user" && $0.eventID == idempotencyKey
           }) {
            return landed.seq
        }

        let userSeq = nextSeq
        nextSeq += 1
        try await store.append(events: [BridgedRooms.EventRecord(
            seq: userSeq,
            eventID: idempotencyKey ?? "fleet-bridged-\(userSeq)-user",
            kind: "message.user",
            actorKind: "user",
            actorID: "local-user",
            payloadText: text,
            createdAt: Date().timeIntervalSince1970)], to: roomID)

        // Fan out — every member receives the text in parallel; replies and
        // failure notes land as they close. The fan-out is DETACHED from
        // this call: `send` returns once the user message is durable, so
        // the composer never blocks on member turns (a real agentic member
        // can run for minutes).
        for member in record.members {
            let sessionID = record.bridgeSessionIDs[member.routeID]
            memberTails[roomID]?[member.routeID]?.task.cancel()
            let token = UUID()
            let tail = Task<Void, Never> {
                // The task inherits this @MainActor context; the relay is
                // environment-owned for the app's lifetime.
                try? await self.relay(member: member, roomID: roomID, sessionID: sessionID, rosterAtSend: record.members)
                self.pruneTail(roomID: roomID, routeID: member.routeID, token: token)
            }
            memberTails[roomID, default: [:]][member.routeID] = MemberTail(task: tail, token: token)
        }
        return userSeq
    }

    /// Drop a FINISHED tail's slot. Token-guarded: a tail that a newer send
    /// already replaced (cancel + replace) must not prune its successor.
    private func pruneTail(roomID: String, routeID: String, token: UUID) {
        guard memberTails[roomID]?[routeID]?.token == token else { return }
        memberTails[roomID]?[routeID] = nil
        if memberTails[roomID]?.isEmpty == true {
            memberTails[roomID] = nil
        }
    }

    private func relay(
        member: BridgedRooms.MemberRef, roomID: String,
        sessionID: String?, rosterAtSend: [BridgedRooms.MemberRef],
        retryFromSeq: Int? = nil
    ) async throws {
        guard let route = member.route else {
            try await appendFailure(member: member, reason: "invalid_route", roomID: roomID)
            return
        }
        let gatewayID = GatewayID(rawValue: member.gatewayID)
        guard let session = await resolver(gatewayID) else {
            try await appendFailure(member: member, reason: "gateway_unavailable", roomID: roomID)
            return
        }
        do {
            if session.status == .offline {
                try await session.connect()
            }
            let conversation = session.conversation
            // Acquire the member's bridge session. An expired session (the
            // gateway restarted / rotated its store) is REBUILT, not bricked:
            // the room log + watermarks on this device can re-establish the
            // member's group context, so the room survives gateway churn
            // (Build 76 round 2 — replaces the Create-a-new-Group contract).
            var rebuilt = false
            let created: ConversationSession
            if let sessionID {
                do {
                    created = try await conversation.resumeSession(
                        sessionID: sessionID, lastEventID: nil,
                        profile: route.profileSlug.rawValue)
                } catch ConversationError.sessionNotFound {
                    created = try await conversation.createSession(
                        title: "Group: \(roomID)", profile: route.profileSlug.rawValue,
                        model: nil, provider: nil, cols: nil)
                    rebuilt = true
                    try await store.setBridgeSessionID(
                        roomKey: roomID, routeID: member.routeID,
                        sessionID: created.sessionID)
                }
            } else {
                // One durable bridge session per source-qualified member
                // keeps turns contextual while remaining separate from the
                // member's canonical 1:1 chat history.
                created = try await conversation.createSession(
                    title: "Group: \(roomID)", profile: route.profileSlug.rawValue,
                    model: nil, provider: nil, cols: nil)
                try await store.setBridgeSessionID(
                    roomKey: roomID, routeID: member.routeID,
                    sessionID: created.sessionID)
            }
            // The rebuild note rides the log BEFORE the turn boundary is
            // frozen, so the member's watermark advance covers it (a note
            // appended after the anchor would leave the watermark lagging
            // the member's own reply and break the contiguous advance).
            if rebuilt {
                try await appendActivityNote(
                    member: member, speaker: Self.qualifiedName(member, in: rosterAtSend),
                    roomID: roomID,
                    text: "\(Self.qualifiedName(member, in: rosterAtSend)) joined a fresh session on its gateway; recent room history was re-delivered.",
                    reason: "bridge_session_rebuilt")
            }
            // Group-context turn (Build 76): re-read the room at turn start —
            // the authoritative roster, current name, and the member's
            // delivery watermark all come from the live record, not the
            // fan-out snapshot. A member removed from the roster mid-flight
            // is skipped entirely (FR-09); the delta is everything after the
            // member's watermark (FR-03/FR-04).
            guard let live = await store.record(roomKey: roomID),
                  live.disbandedAt == nil,
                  live.members.contains(where: { $0.routeID == member.routeID }) else { return }
            let seen = live.deliveryWatermarks[member.routeID] ?? 0
            // A rebuilt session is context-less: its delta is the bounded
            // RECENT history regardless of the watermark (which describes
            // the dead session), so the member re-anchors on real room state.
            let delta = rebuilt ? live.events : live.events.filter {
                $0.seq > (retryFromSeq.map { min(seen, $0 - 1) } ?? seen)
            }
            // Desktop's room log holds only conversation entries; Fleet's
            // event list also carries local notes (turn.failed,
            // room.activity). A delta of notes alone is not a turn — skip
            // it (the anchor below still consumes them, so they never
            // re-trigger this check).
            let hasConversation = delta.contains {
                $0.kind == "message.user" || $0.kind == "message.member"
            }
            guard hasConversation else {
                try await store.advanceDeliveryWatermark(
                    roomKey: roomID, routeID: member.routeID,
                    to: live.events.last?.seq ?? 0)
                return
            }
            // The frozen submit boundary (Desktop `anchorId`): a failure or
            // timeout never advances past this seq; a late reply that lands
            // after newer events does not acknowledge them.
            let anchorSeq = live.events.last?.seq ?? 0
            let prompt = BridgedRoomTurnPrompt.build(.init(
                roomName: live.name, viewer: member, members: live.members, delta: delta))
            let startedAt = Date()
            // Subscribe BEFORE submitting so no streamed event between
            // submit and subscription is missed (live-tail stream, no
            // replay). One stream serves both collection phases.
            let events = conversation.events
            _ = try await conversation.submitPrompt(
                sessionID: created.sessionID, text: prompt)
            // Watermark commit (Desktop contract): advance ONLY after the
            // submit was accepted (the RPC returned without throwing). A
            // throw above skips this entirely — the missed events are
            // re-delivered on the member's next turn.
            try await store.advanceDeliveryWatermark(
                roomKey: roomID, routeID: member.routeID, to: anchorSeq)
            // Phase 1: collect with an activity-extended window. A member
            // that keeps streaming never expires; only a silent member
            // times out (then phase 2 watches for the late reply).
            let outcome = await Self.collectReply(
                events: events,
                sessionID: created.sessionID,
                inactivity: memberTimeout,
                total: lateCollectionWindow)
            if Task.isCancelled {
                // Stop or a superseding turn cancelled this collector. The
                // gateway may still finish; do not invent a room event.
                return
            }
            if case let .reply(reply) = outcome {
                // A completed turn that is exactly "(pass)" — or empty text,
                // which Desktop's `isGroupPassText` also counts as silence —
                // is a GOOD turn: no reply row, no failure note.
                guard !BridgedRoomTurnPrompt.isPassText(reply) else { return }
                await appendMemberMessage(member: member, reply: reply, roomID: roomID, late: false)
                return
            }
            if case let .failed(detail) = outcome {
                try await appendFailure(member: member, reason: "member_turn_failed", roomID: roomID, detail: detail)
                return
            }
            // Honest interim state. The late stream is subscribed BEFORE the
            // note is appended (subscription registers synchronously with the
            // transport), so no terminal event can slip through the gap
            // between phase 1 expiring and phase 2 iterating — and the note
            // append is AWAITED, so it is durable before phase 2 can land a
            // late reply (the documented order: the note first, the reply
            // after; an unstructured append has no ordering guarantee against
            // the reply's awaited append, and `try?`-ing it away would drop
            // the note silently).
            let lateEvents = conversation.events
            try await appendNote(member: member, roomID: roomID,
                       text: "\(member.displayName) didn't answer in time. If it is still working, its reply will appear here.",
                       reason: "member_timeout")
            let remaining = lateCollectionWindow - Date().timeIntervalSince(startedAt)
            guard remaining > 0 else { return }
            // Phase 2 is BACKGROUND collection: bounded only by the total
            // window, not by inactivity — the whole point is to catch a
            // reply that arrives after the user-visible timeout, so an
            // inactivity watchdog here would re-create the exact race the
            // phase exists to close.
            let lateOutcome = await Self.collectReply(
                events: lateEvents,
                sessionID: created.sessionID,
                inactivity: remaining,
                total: remaining)
            if case let .reply(reply) = lateOutcome,
               !Task.isCancelled, !BridgedRoomTurnPrompt.isPassText(reply) {
                await appendMemberMessage(member: member, reply: reply, roomID: roomID, late: true)
            } else if case let .failed(detail) = lateOutcome, !Task.isCancelled {
                // A TERMINAL failure that lands AFTER the interim note is the
                // turn's real outcome: surface it (the note first, this after)
                // instead of leaving the room on a bare "didn't answer in
                // time". Only the canonical completion predicate ever produces
                // `.failed` — a bare advisory `.error` frame does not.
                try await appendFailure(member: member, reason: "member_turn_failed", roomID: roomID, detail: detail)
            }
        } catch {
            try await appendFailure(member: member, reason: Self.reason(for: error), roomID: roomID)
        }
    }

    /// Collect this member's reply: the next terminal `message.complete` on
    /// the member's bridge session, bounded by an INACTIVITY deadline that
    /// any streamed event on the session extends, plus a hard total cap.
    ///
    /// Classification is the app's CANONICAL completion predicate
    /// (`ConversationViewModel.swift:2281`, `ImageGenerationActivity.swift:96`):
    /// ONLY `status == "error"` or a carried `error` is a failed turn.
    /// Everything else is the turn's reply — including `status == "interrupted"`
    /// (the gateway's `TurnStatus` for a cancelled turn, `prompt_turn._result_status`,
    /// which sets NO error payload) and a nil status. An empty/pass reply is
    /// silence for the caller's `isPassText` rule, so a cancel stays silent
    /// instead of fabricating a member failure, and a partial-text interrupted
    /// turn stays a reply.
    ///
    /// A bare session `.error` frame is NOT terminal here: every
    /// `_emit("error", …)` site on this gateway sets exactly `message`
    /// (`tui_gateway/contracts/events.py`) — an advisory (e.g. "Could not switch
    /// model" on a live session, or an ownership refusal) that can arrive while
    /// the turn is still running. Returning on one discarded the member's real
    /// reply that landed after it, so it only proves the session is alive and
    /// falls through to the activity extension below. A turn that really dies
    /// with no terminal frame is still reported honestly: it times out into the
    /// interim note, and phase 2 keeps watching for the late reply.
    private enum ReplyOutcome: Sendable {
        case reply(String)
        case failed(String?)
        case timedOut
    }

    private static func collectReply(
        events: AsyncStream<ConversationEvent>,
        sessionID: String,
        inactivity: TimeInterval,
        total: TimeInterval
    ) async -> ReplyOutcome {
        // Activity-extended deadline shared between the iterator and the
        // watchdog (lock-guarded; the stream is the only writer of extends).
        final class Window: @unchecked Sendable {
            private let lock = NSLock()
            private var inactivityDeadline: ContinuousClock.Instant
            private let totalDeadline: ContinuousClock.Instant
            init(inactivity: TimeInterval, total: TimeInterval) {
                let now = ContinuousClock.now
                self.inactivityDeadline = now + .seconds(max(0, inactivity))
                self.totalDeadline = now + .seconds(max(0, total))
            }
            func extend(inactivity: TimeInterval) {
                lock.lock(); defer { lock.unlock() }
                inactivityDeadline = .now + .seconds(max(0, inactivity))
            }
            var expired: Bool {
                lock.lock(); defer { lock.unlock() }
                return inactivityDeadline <= .now || totalDeadline <= .now
            }
        }
        let window = Window(inactivity: inactivity, total: total)
        return await withTaskGroup(of: ReplyOutcome.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                while let event = await iterator.next() {
                    guard let sid = event.sessionID, sid == sessionID else { continue }
                    switch event {
                    case let .messageComplete(_, text, status, error, _):
                        if status == "error" || error != nil {
                            return .failed(error ?? (text.isEmpty ? nil : text))
                        }
                        return .reply(text)
                    case .error:
                        // Advisory, not turn-terminal (see the doc comment).
                        break
                    default:
                        break
                    }
                    // Any activity for this session: the member is working.
                    window.extend(inactivity: inactivity)
                }
                return .failed(nil)
            }
            group.addTask {
                // Inactivity watchdog: poll cheaply until the (extended)
                // deadline or the hard cap passes. MUST exit on
                // cancellation — `try?` would swallow CancellationError and
                // busy-spin, blocking the group's return after the other
                // child wins (the late-reply-collected-but-never-appended
                // bug).
                while true {
                    if window.expired { return .timedOut }
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return .timedOut }
                }
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    // MARK: event appends (main-actor serialized seq allocation)

    private func appendMemberMessage(
        member: BridgedRooms.MemberRef, reply: String, roomID: String, late: Bool
    ) async {
        let seq = nextSeq
        nextSeq += 1
        let event = BridgedRooms.EventRecord(
            seq: seq,
            eventID: "fleet-bridged-\(seq)-\(member.routeID)\(late ? "-late" : "")",
            kind: "message.member",
            actorKind: "member",
            actorID: member.routeID,
            actorDisplayName: await qualifiedName(member: member, roomID: roomID),
            actorProfile: member.profile,
            payloadText: reply,
            createdAt: Date().timeIntervalSince1970)
        // The contiguous own-reply advance (Desktop `group-round-members.ts`
        // 249-255): a reply cannot acknowledge entries that arrived during
        // inference, but when the member's watermark already sits at the
        // log's tail its own reply extends it — so the member never has its
        // own words re-delivered on its next turn.
        try? await store.append(events: [event], to: roomID, advancingWatermarkFor: member.routeID)
    }

    /// Display name for persisted rows, qualified by source when the LIVE
    /// roster carries another member with the same display name (the two
    /// `default`s on different gateways must never collapse in the
    /// transcript). Unique names render plain.
    private func qualifiedName(member: BridgedRooms.MemberRef, roomID: String) async -> String {
        let record = await store.record(roomKey: roomID)
        return Self.qualifiedName(member, in: record?.members ?? [member])
    }

    /// Pure form: qualified name against a known roster.
    static func qualifiedName(_ member: BridgedRooms.MemberRef, in members: [BridgedRooms.MemberRef]) -> String {
        let twin = members.contains {
            $0.routeID != member.routeID && $0.displayName == member.displayName
        }
        return twin ? "\(member.displayName) · \(member.sourceLabel)" : member.displayName
    }

    /// Durable room-activity note (informational, never an error row).
    private func appendActivityNote(
        member: BridgedRooms.MemberRef, speaker: String, roomID: String, text: String, reason: String
    ) async throws {
        let seq = nextSeq
        nextSeq += 1
        try await store.append(events: [.init(
            seq: seq,
            eventID: "fleet-bridged-\(seq)-\(member.routeID)-\(reason)",
            kind: "room.activity",
            actorKind: "system",
            actorID: "bridge",
            actorDisplayName: nil,
            actorProfile: nil,
            payloadText: text,
            reasonCode: reason,
            createdAt: Date().timeIntervalSince1970)], to: roomID)
    }

    /// Durable member-failure/interim note. `async throws` (like
    /// `appendActivityNote`/`appendFailure`) so the caller can ORDER it
    /// against the late reply's append — the relay's contract is "the note
    /// lands first, the late reply appends after".
    private func appendNote(
        member: BridgedRooms.MemberRef, roomID: String, text: String, reason: String
    ) async throws {
        let seq = nextSeq
        nextSeq += 1
        let event = BridgedRooms.EventRecord(
            seq: seq,
            eventID: "fleet-bridged-\(seq)-\(member.routeID)-failed",
            kind: "turn.failed",
            actorKind: "member",
            actorID: member.routeID,
            actorDisplayName: member.displayName,
            actorProfile: member.profile,
            payloadText: text,
            reasonCode: reason,
            createdAt: Date().timeIntervalSince1970)
        try await store.append(events: [event], to: roomID)
    }

    private func appendFailure(
        member: BridgedRooms.MemberRef, reason: String, roomID: String, detail: String? = nil
    ) async throws {
        let text: String
        if reason == "bridge_session_expired_context_lost" {
            text = "\(member.displayName)'s bridge session expired; context was lost. Create a new Group to continue."
        } else if reason == "member_turn_failed" {
            let safeDetail = detail.map(Redaction.safeText)?.trimmingCharacters(in: .whitespacesAndNewlines)
            text = "\(member.displayName)'s Group turn failed. \(safeDetail.flatMap { $0.isEmpty ? nil : $0 } ?? "The gateway did not give a reason.")"
        } else {
            text = "\(member.displayName) couldn't be reached for this Group (\(reason))."
        }
        let seq = nextSeq
        nextSeq += 1
        try await store.append(events: [BridgedRooms.EventRecord(
            seq: seq,
            eventID: "fleet-bridged-\(seq)-\(member.routeID)-failed",
            kind: "turn.failed",
            actorKind: "member",
            actorID: member.routeID,
            actorDisplayName: member.displayName,
            actorProfile: member.profile,
            payloadText: text,
            reasonCode: reason == "gateway_unavailable" ? "bridge_member_unreachable" : reason,
            createdAt: Date().timeIntervalSince1970)], to: roomID)
    }

    public func rename(roomID: String, name: String) async throws {
        try await store.rename(roomKey: roomID, to: name, at: Date().timeIntervalSince1970)
    }

    public func disband(roomID: String) async throws {
        try await store.disband(roomKey: roomID, at: Date().timeIntervalSince1970)
    }

    public func stop(roomID: String) async throws -> Int {
        var cancelled = 0
        for (_, tail) in memberTails[roomID] ?? [:] {
            tail.task.cancel()
            cancelled += 1
        }
        memberTails[roomID] = nil
        return cancelled
    }

    public func retry(roomID: String, taskID: String) async throws {
        // The phone bridge has no hosted task id. Retry the latest failed
        // member after the latest user message, preserving that message's
        // single transcript row and the healthy members' completed turns.
        _ = taskID
        guard let record = await store.record(roomKey: roomID) else { return }
        guard record.disbandedAt == nil else {
            throw RoomCommandFailure.rpcFailed(
                "This Group was disbanded — it no longer accepts messages.", 0)
        }
        guard let lastUser = record.events.last(where: { $0.kind == "message.user" }),
              let failed = record.events.last(where: {
                  $0.kind == "turn.failed" && $0.seq > lastUser.seq
              }),
              let member = record.members.first(where: { $0.routeID == failed.actorID }) else { return }
        let sessionID = record.bridgeSessionIDs[member.routeID]
        memberTails[roomID]?[member.routeID]?.task.cancel()
        let token = UUID()
        let tail = Task<Void, Never> {
            try? await self.relay(
                member: member, roomID: roomID, sessionID: sessionID,
                rosterAtSend: record.members, retryFromSeq: lastUser.seq)
            self.pruneTail(roomID: roomID, routeID: member.routeID, token: token)
        }
        memberTails[roomID, default: [:]][member.routeID] = MemberTail(task: tail, token: token)
    }

    public func approve(roomID: String, action: RoomPendingApproval, choice: String) async throws {}

    public func createRoom(roomID: String, name: String, members: [[String: String]]) async throws -> String {
        roomID
    }

    private static func reason(for error: Error) -> String {
        if let connectivity = error as? GatewayConnectivityError {
            switch connectivity {
            case .unreachable: return "gateway_unreachable"
            case .authenticationRequired: return "authentication_required"
            case .authSurfaceHTTP: return "auth_surface_error"
            case .authStrategyRejected: return "authentication_required"
            case .unsupported: return "gateway_unsupported_surface"
            case .timeout: return "gateway_timeout"
            case .connectionFailed: return "gateway_connection_failed"
            case .invalidState: return "gateway_invalid_state"
            }
        }
        if let conversation = error as? ConversationError {
            switch conversation {
            case .notConnected: return "gateway_unreachable"
            default: return "member_rpc_failed"
            }
        }
        return "member_error"
    }
}
