import Foundation
import FleetCore
import FleetNetworking
import FleetUI

/// Hosted-room provider: `groups.list` over the gateway's Bot Mode client
/// transport, normalized into `FleetRoom`s with `.hosted` provenance.
///
/// Capability truth is fetched once per provider instance via
/// `groups.capabilities` and attached to every room (fail closed when
/// unavailable: rooms decode with no advertised methods → observational).
struct HostedRoomProvider: FleetRoomProviding {
    let gatewayID: GatewayID
    private let client: GatewayGroupsClient

    init(gatewayID: GatewayID, client: GatewayGroupsClient) {
        self.gatewayID = gatewayID
        self.client = client
    }

    func rooms() async throws -> [FleetRoom] {
        let caps: GroupsCapabilities?
        do {
            caps = try await client.capabilities()
        } catch {
            // Old gateway without groups.*: no hosted rooms, honest absence.
            if case GroupsError.unsupportedMethod = error { return [] }
            throw error
        }
        guard let caps else { return [] }
        let page = try await client.listRooms()
        return page.rooms.map { row in
            FleetRoom(
                id: FleetRoomID(provenance: .hosted, gatewayID: gatewayID, key: row.roomID),
                name: row.name,
                members: row.members,
                recentLog: [],
                image: nil,
                revision: row.revision,
                isDeleted: row.disbandedAt != nil,
                hosted: HostedRoomState(
                    authorityGatewayID: row.authorityGatewayID,
                    authorityEpoch: row.authorityEpoch,
                    latestSeq: row.latestSeq,
                    createdAt: row.createdAt,
                    updatedAt: row.updatedAt,
                    disbandedAt: row.disbandedAt,
                    advertisedMethods: caps.methods,
                    driverAvailable: caps.driver
                )
            )
        }
        .filter { !$0.isDeleted }
    }
}

/// Desktop-legacy-room provider: decodes the `hermes-bots-groups` v3
/// projection from the DEFAULT profile's ui_meta via `profiles.list`.
struct DesktopLegacyRoomProvider: FleetRoomProviding {
    let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    func rooms() async throws -> [FleetRoom] {
        guard case .connected = transport.state else { throw RosterError.notConnected }
        let result = try await transport.request(method: "profiles.list", params: .object([:]))
        // Find the default profile's row and decode its projection.
        guard let profiles = result["profiles"]?.arrayValue else {
            throw RosterError.malformedPayload("profiles.list missing 'profiles'")
        }
        let defaultRow = profiles.first { $0["is_default"]?.boolValue == true }
            ?? profiles.first
        guard let row = defaultRow else { return [] }
        guard let metaJSON = row["ui_meta"]?["hermes-bots-groups"] else { return [] }
        let metaValue = ModernProfilesDecoder.toMetadataValue(metaJSON)
        return LegacyGroupProjectionDecoder.decode(gatewayID: gatewayID, metaValue: metaValue).rooms
    }
}

/// Union room source for one gateway: hosted rooms + legacy projection,
/// identities never merged (distinct provenance keys by construction).
/// Conforms to the FleetCore `FleetRoomSourceProviding` seam (slice 2).
struct GatewayRoomSource {
    let hosted: HostedRoomProvider
    let legacy: DesktopLegacyRoomProvider

    /// Both providers, best-effort per source: a legacy-decode failure must
    /// not hide hosted rooms and vice versa (addendum: observational rooms
    /// degrade without invented state).
    func rooms() async -> [FleetRoom] {
        var out: [FleetRoom] = []
        if let hostedRooms = try? await hosted.rooms() {
            out.append(contentsOf: hostedRooms)
        }
        if let legacyRooms = try? await legacy.rooms() {
            out.append(contentsOf: legacyRooms)
        }
        return out
    }
}

/// Slice 2 seam adapter: `FleetRoomSourceProviding` over the union source.
struct GatewayRoomSourceAdapter: FleetRoomSourceProviding {
    let gatewayID: GatewayID
    let hosted: HostedRoomProvider
    let legacy: DesktopLegacyRoomProvider
    /// Sections-registry + legacy-projection reader (the Bot Mode client).
    let profileReader: GatewayBotModeClient

    func rooms() async -> [FleetRoom] {
        await GatewayRoomSource(hosted: hosted, legacy: legacy).rooms()
    }
}

/// Empty room source for gateways with no endpoint (honest absence).
struct EmptyRoomSource: FleetRoomSourceProviding {
    func rooms() async -> [FleetRoom] { [] }
}

/// Slice 4: production room-command adapter — the FleetCore
/// `RoomChatCommanding` seam over the per-gateway `GatewayGroupsClient`.
/// Every mapping is exact (methods_groups.py at upstream 08b140d); typed
/// `GroupsError`s cross as FleetCore `RoomCommandFailure`s so FleetUI never
/// imports FleetNetworking.
struct GatewayRoomCommandAdapter: RoomChatCommanding {
    let gatewayID: GatewayID
    private let client: GatewayGroupsClient

    init(gatewayID: GatewayID, client: GatewayGroupsClient) {
        self.gatewayID = gatewayID
        self.client = client
    }

    func replay(roomID: String, sinceSeq: Int, limit: Int) async throws -> RoomLogPageSlice {
        do {
            let page = try await client.log(roomID: roomID, sinceSeq: sinceSeq, limit: limit)
            return RoomLogPageSlice(
                events: page.events.map(Self.value),
                cursor: page.cursor,
                latestSeq: page.latestSeq,
                hasMore: page.hasMore,
                authorityGatewayID: page.authority.gatewayID,
                authorityEpoch: page.authority.epoch)
        } catch {
            throw Self.map(error)
        }
    }

    func send(roomID: String, text: String, threadID: String?) async throws -> Int {
        do {
            return try await client.send(roomID: roomID, text: text, threadID: threadID).seq
        } catch {
            throw Self.map(error)
        }
    }

    func rename(roomID: String, name: String) async throws {
        do {
            _ = try await client.rename(roomID: roomID, name: name)
        } catch {
            throw Self.map(error)
        }
    }

    func disband(roomID: String) async throws {
        do {
            try await client.disband(roomID: roomID)
        } catch {
            throw Self.map(error)
        }
    }

    func stop(roomID: String) async throws -> Int {
        do {
            return try await client.stop(roomID: roomID)
        } catch {
            throw Self.map(error)
        }
    }

    func retry(roomID: String, taskID: String) async throws {
        do {
            _ = try await client.retry(roomID: roomID, taskID: taskID)
        } catch {
            throw Self.map(error)
        }
    }

    func approve(
        roomID: String, action: RoomPendingApproval, choice: String
    ) async throws {
        do {
            _ = try await client.approve(
                roomID: roomID,
                memberID: action.memberID,
                taskID: action.taskID,
                executionGeneration: action.executionGeneration,
                choice: choice,
                requestID: action.requestID ?? "")
        } catch {
            throw Self.map(error)
        }
    }

    func createRoom(name: String, members: [[String: String]]) async throws -> String {
        let wireMembers: [JSONValue] = members.map { member in
            var object: [String: JSONValue] = [:]
            for (key, value) in member { object[key] = .string(value) }
            return JSONValue.object(object)
        }
        do {
            return try await client.createRoom(name: name, members: wireMembers, profile: nil).roomID
        } catch {
            throw Self.map(error)
        }
    }

    /// FleetNetworking event row → FleetCore value (payload text + actor
    /// extras are decoded here; unknown payload fields are dropped, not
    /// invented).
    static func value(_ event: HostedRoomEvent) -> HostedRoomEventValue {
        HostedRoomEventValue(
            roomID: event.roomID,
            seq: event.seq,
            eventID: event.eventID,
            kind: event.kind,
            actorKind: event.actorKind,
            actorID: event.actorID,
            payloadText: event.text.isEmpty ? nil : event.text,
            createdAt: event.createdAt)
    }

    static func map(_ error: Error) -> RoomCommandFailure {
        guard let groupsError = error as? GroupsError else {
            if let rpc = error as? JSONRPCError {
                return .rpcFailed(rpc.message, rpc.code)
            }
            return .notConnected
        }
        switch groupsError {
        case .unsupportedMethod(let m): return .unsupportedMethod(m)
        case .foreignAuthority(let m): return .foreignAuthority(m)
        case .confirmRequired(let m): return .confirmRequired(m)
        case .rpcFailed(let m): return .rpcFailed(m, 0)
        case .notConnected: return .notConnected
        case .malformedPayload(let m): return .rpcFailed(m, 0)
        }
    }
}

/// Slice 4: driver-status adapter — `groups.state` → normalized
/// `driver_status` (pending retry/approval actions, hosted_room_service.py
/// status() shape).
struct GatewayRoomDriverStatusAdapter: RoomDriverStatusProviding {
    let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    func driverStatus(roomID: String) async throws -> RoomDriverStatus? {
        guard case .connected = transport.state else {
            throw RoomCommandFailure.notConnected
        }
        let result: JSONValue
        do {
            result = try await transport.request(
                method: "groups.state",
                params: .object(["room_id": .string(roomID)]))
        } catch let error as JSONRPCError {
            throw GatewayRoomCommandAdapter.map(error)
        }
        guard let status = result["driver_status"]?.objectValue else { return nil }
        let actions = status["pending_actions"]?.arrayValue ?? []
        var retries: [RoomPendingRetry] = []
        var approvals: [RoomPendingApproval] = []
        for action in actions {
            guard let object = action.objectValue, let kind = object["kind"]?.stringValue else {
                continue
            }
            if kind == "retry", let taskID = object["task_id"]?.stringValue {
                retries.append(RoomPendingRetry(taskID: taskID))
            } else if kind == "approval",
                      let taskID = object["task_id"]?.stringValue,
                      let memberID = object["member_id"]?.stringValue {
                approvals.append(RoomPendingApproval(
                    memberID: memberID,
                    taskID: taskID,
                    executionGeneration: object["execution_generation"]?.numberValue.map(Int.init) ?? 0,
                    runID: object["run_id"]?.stringValue,
                    sessionID: object["session_id"]?.stringValue,
                    requestID: object["request_id"]?.stringValue,
                    approval: ModernProfilesDecoder.toMetadataValue(object["approval"] ?? .object([:])).objectValue ?? [:]))
            }
        }
        var counts: [String: Int] = [:]
        if let countsObject = status["counts"]?.objectValue {
            for (key, value) in countsObject {
                counts[key] = value.numberValue.map(Int.init) ?? 0
            }
        }
        return RoomDriverStatus(
            working: status["working"]?.boolValue ?? false,
            blocked: status["blocked"]?.boolValue ?? false,
            counts: counts,
            pendingRetries: retries,
            pendingApprovals: approvals)
    }
}

/// Fail-closed bot-profile seam for gateways without an endpoint.
struct UnsupportedBotProfileManagement: BotProfileManaging {
    func describeProfile(_ profile: String) async throws -> BotProfileDescription {
        throw RosterError.notConnected
    }

    func configureProfile(_ profile: String, edit: BotProfileEdit) async throws -> BotProfileEditOutcome {
        throw RosterError.notConnected
    }

    func configureProfile(
        _ profile: String, edit: BotProfileEdit, confirmExpensiveModel: Bool
    ) async throws -> BotProfileEditOutcome {
        throw RosterError.notConnected
    }

    func createProfile(_ spec: BotCreateSpec) async throws -> String {
        throw RosterError.notConnected
    }

    func uploadAvatar(_ profile: String, dataURL: String) async throws {
        throw RosterError.notConnected
    }

    func clearAvatar(_ profile: String) async throws {
        throw RosterError.notConnected
    }

    func avatarData(_ profile: String) async throws -> Data? {
        throw RosterError.notConnected
    }
}

/// Section-registry sync on the Bot Mode client: the Fleet registry rides
/// the gateway DEFAULT profile's ui_meta key `bot-sections-v1` with per-key
/// CAS (load revision → write with expected revision; typed conflict on
/// mismatch — never silent overwrite).
extension GatewayBotModeClient: BotSectionRegistryLoading, BotSectionRegistryWriting {
    public func loadSectionRegistry() async throws -> (sections: [BotSection], revision: Int?) {
        let revision = try await uiMetaRevision(
            profile: "default", key: BotSectionRegistry.metaKey)
        let meta = try await profileUIMeta(profile: "default")
        let sections = BotSectionRegistry.normalize(meta?[BotSectionRegistry.metaKey])
        return (sections, revision)
    }

    public func writeSectionRegistry(
        value: MetadataValue, expectedRevision: Int?
    ) async throws -> MetadataWriteReceiptLike {
        let receipt = try await writeUIMetaKey(
            profile: "default",
            key: BotSectionRegistry.metaKey,
            value: value,
            expectedRevision: expectedRevision
        )
        return MetadataWriteReceiptLike(
            applied: receipt.applied, newRevisions: receipt.newRevisions)
    }
}
