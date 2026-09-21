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
/// - `send` persists the user message, then fans the text out to every
///   member's conversation session (existing per-gateway connections) and
///   collects each member's next `message.complete` as its reply. Failures
///   append honest `turn.failed` notes — never fabricated replies.
/// - `rename` / `disband` are local record updates (disband = final
///   tombstone, matching the hosted contract).
@MainActor
public final class BridgedRoomRelay: RoomChatCommanding {
    /// Resolves the conversation session for a gateway (the environment's
    /// cached per-gateway bundle).
    public typealias SessionResolver = @Sendable (GatewayID) async -> (any ConversationSessionProviding)?

    private let store: BridgedRooms.Store
    private let resolver: SessionResolver
    /// Per-member reply collection window. A slow member must not eat the
    /// others' budget; `send` returns when every window has closed.
    private let memberTimeout: TimeInterval
    private var nextSeq = 1

    public init(
        store: BridgedRooms.Store,
        resolver: @escaping SessionResolver,
        memberTimeout: TimeInterval = 120
    ) {
        self.store = store
        self.resolver = resolver
        self.memberTimeout = memberTimeout
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
        // failure notes land as they close.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for member in record.members {
                let sessionID = record.bridgeSessionIDs[member.routeID]
                group.addTask { [weak self] in
                    try await self?.relay(
                        member: member, text: text, roomID: roomID,
                        sessionID: sessionID)
                }
            }
            try await group.waitForAll()
        }
        let final = await store.record(roomKey: roomID)
        return final?.events.last?.seq ?? userSeq
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
            // Subscribe the collector BEFORE submitting so no streamed
            // event between submit and subscription is missed (live-tail
            // stream, no replay). The submit task parks after success; the
            // collector decides completion (terminal event or deadline).
            let events = conversation.events
            let collector = Task<String?, Never> {
                await Self.collectReply(
                    events: events, sessionID: created.sessionID,
                    timeout: self.memberTimeout)
            }
            defer { collector.cancel() }
            _ = try await conversation.submitPrompt(
                sessionID: created.sessionID, text: text)
            let reply = await collector.value

            let seq = nextSeq
            nextSeq += 1
            let event: BridgedRooms.EventRecord
            if let reply, !reply.isEmpty {
                event = BridgedRooms.EventRecord(
                    seq: seq,
                    eventID: "fleet-bridged-\(seq)-\(member.routeID)",
                    kind: "message.member",
                    actorKind: "member",
                    actorID: member.routeID,
                    actorDisplayName: member.displayName,
                    actorProfile: member.profile,
                    payloadText: reply,
                    createdAt: Date().timeIntervalSince1970)
            } else {
                event = BridgedRooms.EventRecord(
                    seq: seq,
                    eventID: "fleet-bridged-\(seq)-\(member.routeID)-failed",
                    kind: "turn.failed",
                    actorKind: "member",
                    actorID: member.routeID,
                    actorDisplayName: member.displayName,
                    actorProfile: member.profile,
                    payloadText: "\(member.displayName) couldn't answer in this Group.",
                    reasonCode: "member_timeout",
                    createdAt: Date().timeIntervalSince1970)
            }
            try await store.append(events: [event], to: roomID)
        } catch {
            try await appendFailure(member: member, reason: Self.reason(for: error), roomID: roomID)
        }
    }

    /// Collect this member's reply: the next terminal `message.complete` on
    /// the member's bridge session, raced against a deadline so a silent
    /// stream cannot hang the fan-out.
    private static func collectReply(
        events: AsyncStream<ConversationEvent>, sessionID: String, timeout: TimeInterval
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                while let event = await iterator.next() {
                    guard let sid = event.sessionID, sid == sessionID else { continue }
                    if case let .messageComplete(_, text, status, _, _) = event {
                        return status == "error" ? nil : text
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(max(0, timeout)))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func appendFailure(member: BridgedRooms.MemberRef, reason: String, roomID: String) async throws {
        let seq = nextSeq
        nextSeq += 1
        let text = reason == "bridge_session_expired_context_lost"
            ? "\(member.displayName)'s bridge session expired; context was lost. Create a new Group to continue."
            : "\(member.displayName) couldn't be reached for this Group (\(reason))."
        try await store.append(events: [BridgedRooms.EventRecord(
            seq: seq,
            eventID: "fleet-bridged-\(seq)-\(member.routeID)-failed",
            kind: "turn.failed",
            actorKind: "member",
            actorID: member.routeID,
            actorDisplayName: member.displayName,
            actorProfile: member.profile,
            payloadText: text,
            reasonCode: reason,
            createdAt: Date().timeIntervalSince1970)], to: roomID)
    }

    public func rename(roomID: String, name: String) async throws {
        try await store.rename(roomKey: roomID, to: name, at: Date().timeIntervalSince1970)
    }

    public func disband(roomID: String) async throws {
        try await store.disband(roomKey: roomID, at: Date().timeIntervalSince1970)
    }

    public func stop(roomID: String) async throws -> Int { 0 }

    public func retry(roomID: String, taskID: String) async throws {}

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
