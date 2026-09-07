import Foundation
import FleetCore

/// TRUE BOTS MODE slice 5 (D19) — RoomLink wire client.
///
/// Exact `groups.peer.*` / replicate / promote / demote requests and decodes
/// against upstream 08b140d:
/// - `groups.peer.invite` — tui_gateway/methods_groups.py:250-279; response
///   `{grant, target_profile, catalog, endpoint}`; grant payload claims
///   (permissions/status_expires_at) are server-owned — the client treats the
///   token as opaque and derives display lifetime from `ttl_seconds`.
/// - `groups.peer.register` — methods_groups.py:297-343; validation failures
///   (5120) carry the exact strings decoded into
///   `RoomLinkRegistrationRefusal`.
/// - `groups.peer.revoke` — methods_groups.py:282-294.
/// - `groups.replica_state` — gateway/hosted_room_replicas.py:184-195.
/// - `groups.replicate` — hosted_room_replicas.py:179-181
///   (`{room_id, stored_seq, ingested, authority, caught_up}`).
/// - `groups.promote` — methods_groups.py:508-517 (confirm:true required,
///   4118 otherwise) / hosted_room_replicas.py:241-244 receipt.
/// - `groups.demote` — hosted_room_replicas.py:247-286.
public struct GatewayRoomLinkClient: Sendable {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    public enum RoomLinkError: Error, Sendable, Equatable {
        case notConnected
        case malformed(String)
        /// peer.register validation refusal (5120) with the exact upstream
        /// message.
        case registrationRefusal(String)
        /// promote without confirm (4118).
        case confirmRequired(String)
        case rpcFailed(String, Int)
    }

    // MARK: - Negotiation

    /// `groups.capabilities` → negotiated RoomLink truth (catalog mapping
    /// decoded verbatim — hosted_room_peer.py:226-284).
    public func negotiate() async throws -> RoomLinkNegotiation {
        let result = try await requestMapped(
            method: "groups.capabilities", params: .object([:]))
        return Self.decodeNegotiation(result)
    }

    static func decodeNegotiation(_ result: JSONValue) -> RoomLinkNegotiation {
        let roomLink = result["room_link"]?.objectValue
        let catalog = roomLink?["catalog"]?.objectValue
        let endpoint = (catalog?["endpoint"]?.objectValue).map(Self.decodeEndpoint)
        let policy = (catalog?["execution_policy"]?.objectValue).map(Self.decodePolicy)
        return RoomLinkNegotiation(
            authorityGatewayID: result["authority_gateway_id"]?.stringValue ?? "",
            enabled: roomLink?["enabled"]?.boolValue ?? false,
            disabledReason: roomLink?["reason"]?.stringValue.map(RoomLinkDisabledReason.init(wireValue:)),
            profile: roomLink?["profile"]?.stringValue,
            protocolVersion: catalog?["protocol_versions"]?.arrayValue?.compactMap(\.numberValue).first.map(Int.init) ?? 0,
            installationID: catalog?["installation_id"]?.stringValue ?? "",
            linkModes: catalog?["link_modes"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            persistentProcess: catalog?["persistent_process"]?.boolValue ?? false,
            textOnly: catalog?["text"]?.boolValue ?? true,
            attachmentsSupported: catalog?["attachments"]?.boolValue ?? false,
            catalogDigest: catalog?["catalog_digest"]?.stringValue ?? "",
            executionPolicy: policy,
            endpoint: endpoint,
            methods: result["methods"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }

    static func decodeEndpoint(_ o: [String: JSONValue]) -> RoomLinkEndpoint {
        RoomLinkEndpoint(
            available: o["available"]?.boolValue ?? false,
            url: o["url"]?.stringValue,
            transportSecurity: o["transport_security"]?.stringValue,
            unavailableReason: o["reason"]?.stringValue)
    }

    static func decodePolicy(_ o: [String: JSONValue]) -> RoomLinkExecutionPolicy {
        RoomLinkExecutionPolicy(
            version: o["version"]?.numberValue.map(Int.init) ?? 0,
            targetProfile: o["target_profile"]?.stringValue ?? "",
            enabledToolsets: o["enabled_toolsets"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            approvalMode: o["approval_mode"]?.stringValue ?? "",
            maxIterations: o["max_iterations"]?.numberValue.map(Int.init) ?? 0,
            policyDigest: o["policy_digest"]?.stringValue ?? "")
    }

    // MARK: - Grants

    /// `groups.peer.invite` on this (target) gateway.
    public func invite(
        roomID: String?, memberID: String?, ttlSeconds: Double
    ) async throws -> RoomLinkGrant {
        var params: [String: JSONValue] = [
            "ttl_seconds": .number(ttlSeconds),
        ]
        if let roomID { params["room_id"] = .string(roomID) }
        if let memberID { params["member_id"] = .string(memberID) }
        let result = try await requestMapped(method: "groups.peer.invite", params: .object(params))
        guard let grantToken = result["grant"]?.stringValue else {
            throw RoomLinkError.malformed("groups.peer.invite missing 'grant'")
        }
        let now = Date()
        return RoomLinkGrant(
            id: UUID().uuidString,
            token: grantToken,
            roomID: roomID,
            memberID: memberID,
            targetProfile: result["target_profile"]?.stringValue ?? "",
            permissions: RoomLinkGrant.Permission.allCases,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(ttlSeconds))
    }

    /// `groups.peer.register` on the room's gateway.
    public func registerPeer(
        roomID: String,
        memberID: String,
        grant: RoomLinkGrant,
        targetURL: String,
        catalogDigest: String
    ) async throws -> RoomPeerRoute {
        let params: [String: JSONValue] = [
            "target_url": .string(targetURL),
            "catalog": .object([
                "installation_id": .string(grant.targetProfile.isEmpty ? "unknown" : grant.targetProfile),
                "catalog_digest": .string(catalogDigest),
            ]),
            "target_profile": .string(grant.targetProfile),
            "grant": .string(grant.token),
            "room_id": .string(roomID),
            "member_id": .string(memberID),
        ]
        let result = try await requestMapped(method: "groups.peer.register", params: .object(params))
        return RoomPeerRoute(
            roomID: roomID,
            memberID: memberID,
            targetInstallID: result["target_install_id"]?.stringValue ?? "",
            targetProfile: result["target_profile"]?.stringValue ?? grant.targetProfile,
            mode: result["mode"]?.stringValue ?? "direct",
            transportSecurity: result["transport_security"]?.stringValue ?? "",
            status: .ready)
    }

    /// `groups.peer.revoke`.
    public func revoke(grant: RoomLinkGrant) async throws {
        _ = try await requestMapped(
            method: "groups.peer.revoke",
            params: .object(["grant": .string(grant.token)]))
    }

    /// Registered peer routes for a room from `groups.state` driver_status
    /// `peer_routes` ({room_id, member_id, status} —
    /// hosted_room_service.py:528-548).
    public func peerRoutes(roomID: String) async throws -> [RoomPeerRoute] {
        let result = try await requestMapped(
            method: "groups.state",
            params: .object(["room_id": .string(roomID)]))
        guard let routes = result["driver_status"]?["peer_routes"]?.arrayValue else {
            return []
        }
        return routes.compactMap { route in
            guard let o = route.objectValue,
                  let memberID = o["member_id"]?.stringValue else { return nil }
            let status = RoomPeerRoute.Status(
                rawValue: o["status"]?.stringValue ?? "unavailable") ?? .unavailable
            return RoomPeerRoute(
                roomID: o["room_id"]?.stringValue ?? roomID,
                memberID: memberID,
                targetInstallID: "",
                targetProfile: "",
                mode: "direct",
                transportSecurity: "",
                status: status)
        }
    }

    // MARK: - Replication / promotion

    /// `groups.replica_state` (nil when "replica not found" → 4117).
    public func replicaState(roomID: String) async throws -> RoomReplicaState? {
        let result: JSONValue
        do {
            result = try await request(
                method: "groups.replica_state",
                params: .object(["room_id": .string(roomID)]))
        } catch let error as JSONRPCError where error.message.contains("replica not found") {
            return nil
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        }
        guard let o = result.objectValue else {
            throw RoomLinkError.malformed("groups.replica_state response not an object")
        }
        let authority = o["authority"]?.objectValue
        return RoomReplicaState(
            roomID: o["room_id"]?.stringValue ?? roomID,
            name: o["name"]?.stringValue ?? "",
            authorityGatewayID: authority?["gateway_id"]?.stringValue ?? "",
            authorityEpoch: authority?["epoch"]?.numberValue.map(Int.init) ?? 0,
            lastSeq: o["last_seq"]?.numberValue.map(Int.init) ?? 0,
            latestSeq: o["latest_seq"]?.numberValue.map(Int.init) ?? 0,
            eventBytes: o["event_bytes"]?.numberValue.map(Int.init) ?? 0,
            createdAt: o["created_at"]?.numberValue ?? 0,
            updatedAt: o["updated_at"]?.numberValue ?? 0)
    }

    /// `groups.replicate` with a verbatim `groups.log` page for the room.
    public func replicate(
        roomID: String, roomName: String, members: [[String: String]],
        page: JSONValue
    ) async throws -> RoomReplicateReceipt {
        let membersValue: [JSONValue] = members.map { member in
            var object: [String: JSONValue] = [:]
            for (key, value) in member { object[key] = .string(value) }
            return JSONValue.object(object)
        }
        let result = try await requestMapped(
            method: "groups.replicate",
            params: .object([
                "room_id": .string(roomID),
                "room_name": .string(roomName),
                "members": .array(membersValue),
                "page": page,
            ]))
        guard let o = result.objectValue else {
            throw RoomLinkError.malformed("groups.replicate response not an object")
        }
        let authority = o["authority"]?.objectValue
        return RoomReplicateReceipt(
            roomID: o["room_id"]?.stringValue ?? roomID,
            storedSeq: o["stored_seq"]?.numberValue.map(Int.init) ?? 0,
            ingested: o["ingested"]?.numberValue.map(Int.init) ?? 0,
            authorityGatewayID: authority?["gateway_id"]?.stringValue ?? "",
            authorityEpoch: authority?["epoch"]?.numberValue.map(Int.init) ?? 0,
            caughtUp: o["caught_up"]?.boolValue ?? false)
    }

    /// `groups.promote` — confirm:true is REQUIRED upstream (4118 otherwise).
    public func promote(roomID: String, confirm: Bool) async throws -> RoomPromotionReceipt {
        let result = try await requestMapped(
            method: "groups.promote",
            params: .object([
                "room_id": .string(roomID),
                "confirm": .bool(confirm),
            ]))
        guard let o = result.objectValue else {
            throw RoomLinkError.malformed("groups.promote response not an object")
        }
        return RoomPromotionReceipt(
            roomID: o["room_id"]?.stringValue ?? roomID,
            authorityGatewayID: o["authority_gateway_id"]?.stringValue ?? "",
            authorityEpoch: o["authority_epoch"]?.numberValue.map(Int.init) ?? 0,
            previousGatewayID: o["previous_gateway_id"]?.stringValue ?? "",
            previousEpoch: o["previous_epoch"]?.numberValue.map(Int.init) ?? 0,
            claimSeq: o["claim_seq"]?.numberValue.map(Int.init) ?? 0,
            latestSeq: o["latest_seq"]?.numberValue.map(Int.init) ?? 0)
    }

    /// `groups.demote` with the observed authority (idempotent upstream).
    public func demote(
        roomID: String, observedGatewayID: String, observedEpoch: Int
    ) async throws {
        _ = try await requestMapped(
            method: "groups.demote",
            params: .object([
                "room_id": .string(roomID),
                "observed_gateway_id": .string(observedGatewayID),
                "observed_epoch": .number(Double(observedEpoch)),
            ]))
    }

    // MARK: - transport

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        if !isTransportReady {
            try await transport.connect()
        }
        return try await transport.request(method: method, params: params)
    }

    /// Request with typed error mapping.
    private func requestMapped(method: String, params: JSONValue) async throws -> JSONValue {
        do {
            return try await request(method: method, params: params)
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        }
    }

    private var isTransportReady: Bool {
        if case .connected = transport.state { return true }
        return false
    }

    static func mapError(_ error: JSONRPCError) -> RoomLinkError {
        switch error.code {
        case -32601:
            return .registrationRefusal("gateway does not support \(error.message)")
        case 4118:
            return .confirmRequired(error.message)
        case 5120:
            return .registrationRefusal(error.message)
        default:
            return .rpcFailed(error.message, error.code)
        }
    }
}
