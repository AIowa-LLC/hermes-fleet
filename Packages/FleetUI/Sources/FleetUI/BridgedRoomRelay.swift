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
/// - Reply collection is an INACTIVITY window, not a turn cap: any streamed
///   event on the member's session extends the deadline (real agentic turns
///   run 3-4 minutes while streaming). A timed-out member stays watched for
///   a late `message.complete` within `lateCollectionWindow` — the failure
///   note lands first (honest interim state), the late reply appends after.
/// - `rename` / `disband` are local record updates (disband = final
///   tombstone, matching the hosted contract).
/// - `stop` cancels the room's live tails; `retry` re-sends the room's last
///   user message (the only retryable unit the bridge owns).
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
    /// Live fan-out tails: room storage key -> route id -> task. A new send
    /// for the same member cancels its previous tail (the newest turn
    /// supersedes); `stop` cancels every tail for the room.
    private var memberTails: [String: [String: Task<Void, Never>]] = [:]
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
    public func transcriptChanges(roomID: String) -> AsyncStream<Void>? {
        let store = self.store
        return AsyncStream<Void> { continuation in
            let task = Task {
                let changes = await store.changes()
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

    public func send(roomID: String, text: String, threadID: String?) async throws -> Int {
        guard let record = await store.record(roomKey: roomID) else {
            throw RoomCommandFailure.notConnected
        }
        syncSeq(roomID: roomID, latest: record.events.last?.seq)

        let userSeq = nextSeq
        nextSeq += 1
        try await store.append(events: [BridgedRooms.EventRecord(
            seq: userSeq,
            eventID: "fleet-bridged-\(userSeq)-user",
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
            memberTails[roomID]?[member.routeID]?.cancel()
            let tail = Task<Void, Never> {
                // The task inherits this @MainActor context; the relay is
                // environment-owned for the app's lifetime.
                try? await self.relay(
                    member: member, text: text, roomID: roomID,
                    sessionID: sessionID)
            }
            memberTails[roomID, default: [:]][member.routeID] = tail
        }
        return userSeq
    }

    private func relay(
        member: BridgedRooms.MemberRef, text: String, roomID: String,
        sessionID: String?
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
            let created: ConversationSession
            if let sessionID {
                do {
                    created = try await conversation.resumeSession(
                        sessionID: sessionID, lastEventID: nil,
                        profile: route.profileSlug.rawValue)
                } catch ConversationError.sessionNotFound {
                    try await appendFailure(
                        member: member,
                        reason: "bridge_session_expired_context_lost",
                        roomID: roomID)
                    return
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
            let startedAt = Date()
            // Subscribe BEFORE submitting so no streamed event between
            // submit and subscription is missed (live-tail stream, no
            // replay). One stream serves both collection phases.
            let events = conversation.events
            _ = try await conversation.submitPrompt(
                sessionID: created.sessionID, text: text)
            // Phase 1: collect with an activity-extended window. A member
            // that keeps streaming never expires; only a silent member
            // times out (then phase 2 watches for the late reply).
            var reply = await Self.collectReply(
                events: events,
                sessionID: created.sessionID,
                inactivity: memberTimeout,
                total: lateCollectionWindow)
            if let reply, !reply.isEmpty {
                appendMemberMessage(member: member, reply: reply, roomID: roomID, late: false)
                return
            }
            if Task.isCancelled {
                // The person stopped waiting — nothing failed, and the
                // member's turn still runs on its gateway. No note.
                return
            }
            // Honest interim state. The late stream is subscribed BEFORE the
            // note is appended (subscription registers synchronously with the
            // transport), so no terminal event can slip through the gap
            // between phase 1 expiring and phase 2 iterating.
            let lateEvents = conversation.events
            appendNote(member: member, roomID: roomID,
                       text: "\(member.displayName) didn't answer in time. If it is still working, its reply will appear here.",
                       reason: "member_timeout")
            let remaining = lateCollectionWindow - Date().timeIntervalSince(startedAt)
            guard remaining > 0 else { return }
            // Phase 2 is BACKGROUND collection: bounded only by the total
            // window, not by inactivity — the whole point is to catch a
            // reply that arrives after the user-visible timeout, so an
            // inactivity watchdog here would re-create the exact race the
            // phase exists to close.
            reply = await Self.collectReply(
                events: lateEvents,
                sessionID: created.sessionID,
                inactivity: remaining,
                total: remaining)
            if let reply, !reply.isEmpty, !Task.isCancelled {
                appendMemberMessage(member: member, reply: reply, roomID: roomID, late: true)
            }
        } catch {
            try await appendFailure(member: member, reason: Self.reason(for: error), roomID: roomID)
        }
    }

    /// Collect this member's reply: the next terminal `message.complete` on
    /// the member's bridge session, bounded by an INACTIVITY deadline that
    /// any streamed event on the session extends, plus a hard total cap.
    private static func collectReply(
        events: AsyncStream<ConversationEvent>,
        sessionID: String,
        inactivity: TimeInterval,
        total: TimeInterval
    ) async -> String? {
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
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                while let event = await iterator.next() {
                    guard let sid = event.sessionID, sid == sessionID else { continue }
                    if case let .messageComplete(_, text, status, _, _) = event {
                        return status == "error" ? nil : text
                    }
                    // Any activity for this session: the member is working.
                    window.extend(inactivity: inactivity)
                }
                return nil
            }
            group.addTask {
                // Inactivity watchdog: poll cheaply until the (extended)
                // deadline or the hard cap passes. MUST exit on
                // cancellation — `try?` would swallow CancellationError and
                // busy-spin, blocking the group's return after the other
                // child wins (the late-reply-collected-but-never-appended
                // bug).
                while true {
                    if window.expired { return nil }
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return nil }
                }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: event appends (main-actor serialized seq allocation)

    private func appendMemberMessage(
        member: BridgedRooms.MemberRef, reply: String, roomID: String, late: Bool
    ) {
        let seq = nextSeq
        nextSeq += 1
        let event = BridgedRooms.EventRecord(
            seq: seq,
            eventID: "fleet-bridged-\(seq)-\(member.routeID)\(late ? "-late" : "")",
            kind: "message.member",
            actorKind: "member",
            actorID: member.routeID,
            actorDisplayName: member.displayName,
            actorProfile: member.profile,
            payloadText: reply,
            createdAt: Date().timeIntervalSince1970)
        Task { try? await store.append(events: [event], to: roomID) }
    }

    private func appendNote(
        member: BridgedRooms.MemberRef, roomID: String, text: String, reason: String
    ) {
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
        Task { try? await store.append(events: [event], to: roomID) }
    }

    private func appendFailure(member: BridgedRooms.MemberRef, reason: String, roomID: String) async throws {
        let text: String
        if reason == "bridge_session_expired_context_lost" {
            text = "\(member.displayName)'s bridge session expired; context was lost. Create a new Group to continue."
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
        for (_, task) in memberTails[roomID] ?? [:] {
            task.cancel()
            cancelled += 1
        }
        memberTails[roomID] = nil
        return cancelled
    }

    public func retry(roomID: String, taskID: String) async throws {
        // The only retryable unit the bridge owns: re-send the room's last
        // user message (a fresh fan-out with fresh seq numbers).
        guard let record = await store.record(roomKey: roomID) else { return }
        guard let lastUser = record.events.last(where: { $0.kind == "message.user" }),
              let text = lastUser.payloadText else { return }
        _ = try await send(roomID: roomID, text: text, threadID: nil)
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
