import Foundation
import FleetCore

/// Errors for hosted-groups operations.
public enum GroupsError: Error, Sendable, Equatable, LocalizedError {
    case notConnected
    case malformedPayload(String)
    case rpcFailed(String)
    /// The gateway is foreign authority for this room (methods_groups.py:411).
    case foreignAuthority(String)
    /// Promotion requires explicit confirm (4118).
    case confirmRequired(String)
    case unsupportedMethod(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "gateway not connected"
        case .malformedPayload(let s): return "malformed groups payload: \(s)"
        case .rpcFailed(let s): return "groups RPC failed: \(s)"
        case .foreignAuthority(let s): return s
        case .confirmRequired(let s): return s
        case .unsupportedMethod(let s): return "gateway does not support \(s) — update the gateway"
        }
    }
}

/// Wire row for a hosted room (gateway/hosted_rooms.py:465-474).
public struct HostedRoomRow: Hashable, Sendable {
    public let roomID: String
    public let name: String
    public let membersJSON: String
    public let authorityGatewayID: String
    public let authorityEpoch: Int
    public let revision: Int
    public let createdAt: Double
    public let updatedAt: Double
    public let disbandedAt: Double?
    public let latestSeq: Int?

    /// Decoded members (best effort — the wire carries a JSON array string).
    public var members: [FleetRoomMember] {
        guard let data = membersJSON.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { o in
            guard let name = o["name"] as? String ?? o["profile"] as? String else { return nil }
            return FleetRoomMember(
                name: name,
                handle: o["handle"] as? String,
                connectionID: (o["target"] as? [String: Any])?["peer_id"] as? String ?? o["connection_id"] as? String,
                connectionLabel: nil,
                sourceScoped: (o["target"] as? [String: Any])?["kind"] as? String == "peer"
            )
        }
    }
}

/// Decoded `groups.capabilities` truth (methods_groups.py:218-247).
public struct GroupsCapabilities: Hashable, Sendable {
    public let protocolVersion: Int
    public let driver: Bool
    public let persistentProcess: Bool
    public let authorityGatewayID: String
    public let roomLinkEnabled: Bool
    public let roomLinkDisabledReason: String?
    public let features: [String]
    public let methods: [String]
    public let maxLogLimit: Int
}

public struct SentRoomEvent: Hashable, Sendable {
    public let roomID: String
    public let seq: Int
    public let eventID: String
}

public struct RoomLogPage: Sendable {
    public let events: [HostedRoomEvent]
    public let cursor: Int
    public let latestSeq: Int
    public let hasMore: Bool
    public let authority: RoomAuthority
}

public struct RoomAuthority: Hashable, Sendable {
    public let gatewayID: String
    public let epoch: Int
}

public struct HostedRoomEvent: Hashable, Sendable, Identifiable {
    public let roomID: String
    public let seq: Int
    public let eventID: String
    public let kind: String
    public let actorKind: String
    public let actorID: String
    public let text: String
    public let createdAt: Double

    public var id: String { "\(roomID)#\(seq)" }
}

/// Hosted `groups.*` client over the shared per-gateway transport.
///
/// Sendable: an immutable value holding a `GatewayWebSocketTransport` actor
/// reference (same shape as `GatewayRosterClient`).
public struct GatewayGroupsClient: Sendable {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: - capabilities

    /// `groups.capabilities` → capability truth for this gateway.
    public func capabilities() async throws -> GroupsCapabilities {
        let result = try await request(method: "groups.capabilities", params: .object([:]))
        return Self.decodeCapabilities(result)
    }

    // MARK: - rooms

    /// `groups.list` (single page).
    public func listRooms(limit: Int = 200, includeDisbanded: Bool = false) async throws -> (rooms: [HostedRoomRow], nextOffset: Int?) {
        let params: [String: JSONValue] = [
            "limit": .number(Double(limit)),
            "include_disbanded": .bool(includeDisbanded),
        ]
        let result = try await request(method: "groups.list", params: .object(params))
        return try Self.decodeRoomList(result)
    }

    /// `groups.create` — idempotent on (id, name, members).
    public func createRoom(name: String, members: [JSONValue], profile: String?) async throws -> HostedRoomRow {
        var params: [String: JSONValue] = [
            "name": .string(name),
            "members": .array(members),
        ]
        if let profile { params["profile"] = .string(profile) }
        let result = try await request(method: "groups.create", params: .object(params))
        guard let room = result["room"] else {
            throw GroupsError.malformedPayload("groups.create missing 'room'")
        }
        return try Self.decodeRoom(room)
    }

    /// `groups.state`.
    public func roomState(roomID: String) async throws -> HostedRoomRow {
        let result = try await request(method: "groups.state", params: .object([
            "room_id": .string(roomID),
        ]))
        guard let room = result["room"] else {
            throw GroupsError.malformedPayload("groups.state missing 'room'")
        }
        return try Self.decodeRoom(room)
    }

    /// `groups.send` — client-minted event id for idempotency
    /// (hosted_rooms.py:244-246 maps event_id → "user:" + sha256).
    public func send(
        roomID: String,
        text: String,
        threadID: String? = nil,
        profile: String? = nil
    ) async throws -> SentRoomEvent {
        var payload: [String: JSONValue] = ["text": .string(text)]
        if let threadID { payload["thread_id"] = .string(threadID) }
        var params: [String: JSONValue] = [
            "room_id": .string(roomID),
            "event_id": .string(Self.mintEventID()),
            "payload": .object(payload),
        ]
        if let profile { params["profile"] = .string(profile) }
        let result = try await request(method: "groups.send", params: .object(params))
        guard let event = result["event"]?.objectValue else {
            throw GroupsError.malformedPayload("groups.send missing 'event'")
        }
        let seq = event["seq"]?.numberValue.map(Int.init) ?? 0
        let eventID = event["event_id"]?.stringValue ?? ""
        return SentRoomEvent(roomID: roomID, seq: seq, eventID: eventID)
    }

    /// `groups.log` since_seq paging (hosted_rooms.py:1111-1160).
    public func log(
        roomID: String,
        sinceSeq: Int = 0,
        limit: Int = 100
    ) async throws -> RoomLogPage {
        let result = try await request(method: "groups.log", params: .object([
            "room_id": .string(roomID),
            "since_seq": .number(Double(sinceSeq)),
            "limit": .number(Double(limit)),
        ]))
        return try Self.decodeLogPage(result)
    }

    /// `groups.rename` (atomic rename + room.renamed event — :884-910).
    public func rename(roomID: String, name: String) async throws -> HostedRoomRow {
        let result = try await request(method: "groups.rename", params: .object([
            "room_id": .string(roomID),
            "event_id": .string(Self.mintEventID()),
            "name": .string(name),
        ]))
        guard let room = result["room"] else {
            throw GroupsError.malformedPayload("groups.rename missing 'room'")
        }
        return try Self.decodeRoom(room)
    }

    /// `groups.disband` (stop work + revoke peer routes + tombstone).
    public func disband(roomID: String) async throws {
        _ = try await request(method: "groups.disband", params: .object([
            "room_id": .string(roomID),
        ]))
    }

    /// `groups.stop` → cancelled count.
    public func stop(roomID: String) async throws -> Int {
        let result = try await request(method: "groups.stop", params: .object([
            "room_id": .string(roomID),
        ]))
        return result["cancelled"]?.numberValue.map(Int.init) ?? 0
    }

    /// `groups.retry {room_id, task_id}`.
    public func retry(roomID: String, taskID: String) async throws -> Bool {
        let result = try await request(method: "groups.retry", params: .object([
            "room_id": .string(roomID),
            "task_id": .string(taskID),
        ]))
        return result["retried"]?.boolValue ?? false
    }

    /// `groups.approve {room_id, member_id, task_id, execution_generation,
    /// choice ("once"|"deny"), request_id}` (hosted_room_service.py:507-508).
    public func approve(
        roomID: String,
        memberID: String,
        taskID: String,
        executionGeneration: Int,
        choice: String,
        requestID: String
    ) async throws -> Bool {
        let result = try await request(method: "groups.approve", params: .object([
            "room_id": .string(roomID),
            "member_id": .string(memberID),
            "task_id": .string(taskID),
            "execution_generation": .number(Double(executionGeneration)),
            "choice": .string(choice),
            "request_id": .string(requestID),
        ]))
        return result["approved"]?.boolValue ?? false
    }

    // MARK: - event-id minting (client-side idempotency)

    static func mintEventID() -> String {
        "fleet-" + UUID().uuidString.lowercased()
    }

    // MARK: - transport

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        if !isTransportReady {
            try await transport.connect()
        }
        do {
            return try await transport.request(method: method, params: params)
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        }
    }

    private var isTransportReady: Bool {
        if case .connected = transport.state { return true }
        return false
    }

    // MARK: - decoding

    static func decodeCapabilities(_ result: JSONValue) -> GroupsCapabilities {
        let roomLink = result["room_link"]?.objectValue
        return GroupsCapabilities(
            protocolVersion: result["protocol_version"]?.numberValue.map(Int.init) ?? 0,
            driver: result["driver"]?.boolValue ?? false,
            persistentProcess: result["persistent_process"]?.boolValue ?? false,
            authorityGatewayID: result["authority_gateway_id"]?.stringValue ?? "",
            roomLinkEnabled: roomLink?["enabled"]?.boolValue ?? false,
            roomLinkDisabledReason: roomLink?["reason"]?.stringValue,
            features: result["features"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            methods: result["methods"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            maxLogLimit: result["max_log_limit"]?.numberValue.map(Int.init) ?? 0
        )
    }

    static func decodeRoomList(_ result: JSONValue) throws -> (rooms: [HostedRoomRow], nextOffset: Int?) {
        guard let rooms = result["rooms"]?.arrayValue else {
            throw GroupsError.malformedPayload("groups.list missing 'rooms'")
        }
        let nextOffset = result["next_offset"]?.numberValue.map(Int.init)
        let decoded = rooms.compactMap { try? Self.decodeRoom($0) }
        return (decoded, nextOffset)
    }

    static func decodeRoom(_ json: JSONValue) throws -> HostedRoomRow {
        guard let o = json.objectValue,
              let roomID = o["room_id"]?.stringValue, !roomID.isEmpty else {
            throw GroupsError.malformedPayload("room row missing room_id")
        }
        return HostedRoomRow(
            roomID: roomID,
            name: o["name"]?.stringValue ?? "",
            membersJSON: o["members"]?.stringValue ?? "[]",
            authorityGatewayID: o["authority_gateway_id"]?.stringValue ?? "",
            authorityEpoch: o["authority_epoch"]?.numberValue.map(Int.init) ?? 0,
            revision: o["revision"]?.numberValue.map(Int.init) ?? 0,
            createdAt: o["created_at"]?.numberValue ?? 0,
            updatedAt: o["updated_at"]?.numberValue ?? 0,
            disbandedAt: o["disbanded_at"]?.numberValue,
            latestSeq: o["latest_seq"]?.numberValue.map(Int.init)
        )
    }

    static func decodeLogPage(_ result: JSONValue) throws -> RoomLogPage {
        guard let events = result["events"]?.arrayValue else {
            throw GroupsError.malformedPayload("groups.log missing 'events'")
        }
        let cursor = result["cursor"]?.numberValue.map(Int.init) ?? 0
        let latestSeq = result["latest_seq"]?.numberValue.map(Int.init) ?? 0
        let hasMore = result["has_more"]?.boolValue ?? false
        let authorityObj = result["authority"]?.objectValue
        let authority = RoomAuthority(
            gatewayID: authorityObj?["gateway_id"]?.stringValue ?? "",
            epoch: authorityObj?["epoch"]?.numberValue.map(Int.init) ?? 0
        )
        let decodedEvents: [HostedRoomEvent] = events.compactMap(Self.decodeEvent)
        return RoomLogPage(
            events: decodedEvents,
            cursor: cursor,
            latestSeq: latestSeq,
            hasMore: hasMore,
            authority: authority
        )
    }

    static func decodeEvent(_ json: JSONValue) -> HostedRoomEvent? {
        guard let o = json.objectValue,
              let eventID = o["event_id"]?.stringValue,
              let kind = o["kind"]?.stringValue else { return nil }
        let actorObj = o["actor"]?.objectValue
        return HostedRoomEvent(
            roomID: o["room_id"]?.stringValue ?? "",
            seq: o["seq"]?.numberValue.map(Int.init) ?? 0,
            eventID: eventID,
            kind: kind,
            actorKind: actorObj?["kind"]?.stringValue ?? "",
            actorID: actorObj?["id"]?.stringValue ?? "",
            text: o["payload"]?["text"]?.stringValue ?? "",
            createdAt: o["created_at"]?.numberValue ?? 0
        )
    }

    static func mapError(_ error: JSONRPCError) -> GroupsError {
        switch error.code {
        case -32601: return .unsupportedMethod(error.message)
        case 4118: return .confirmRequired(error.message)
        default:
            if error.message.contains("managed by another gateway") {
                return .foreignAuthority(error.message)
            }
            return .rpcFailed("\(error.message) (\(error.code))")
        }
    }
}
