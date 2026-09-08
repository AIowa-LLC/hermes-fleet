import Foundation
import FleetCore

/// TRUE BOTS MODE slice 5 (D19) — RoomLink wire client.
///
/// Exact `groups.peer.*` / replicate / promote / demote requests and decodes.
/// Originally derived from upstream 08b140d; re-verified against current
/// upstream main 966637323e (2026-09-08) — contracts unchanged:
/// - `groups.peer.invite` — tui_gateway/methods_groups.py:250-279; response
///   `{grant, target_profile, catalog, endpoint}`; the FULL capability
///   catalog is captured verbatim on the grant — grant payload claims
///   (permissions/status_expires_at) are server-owned and the client treats
///   the token as opaque.
/// - `groups.peer.register` — methods_groups.py:297-343; takes the EXACT
///   capability catalog advertised by the target (validated upstream by
///   `GatewayRoomCatalog.from_mapping`: exact fields + digest HMAC +
///   equality with the live probe catalog). Fleet sends the invite-time
///   catalog verbatim and fails closed client-side when it is missing,
///   partial, or carries a synthetic installation identity. Validation
///   failures (5120) carry the exact strings decoded into
///   `RoomLinkRegistrationRefusal`.
/// - `groups.peer.revoke` — methods_groups.py:282-294.
/// - `groups.replica_state` — gateway/hosted_room_replicas.py:184-195.
/// - `groups.replicate` — methods_groups.py:496-501 →
///   hosted_room_replicas.py ingest_page (requires real room name, members,
///   and a verbatim `groups.log`-shaped page with events + authority;
///   idempotent, refuses gaps and epoch regressions). Fleet assembles the
///   page via `RoomReplicator` from `groups.state` + `groups.log` — never
///   placeholders.
/// - `groups.promote` — methods_groups.py:508-517 (confirm:true required,
///   4118 otherwise) / hosted_room_replicas.py:198-244 receipt.
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
            protocolVersions: catalog?["protocol_versions"]?.arrayValue?.compactMap(\.numberValue).map(Int.init) ?? [],
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

    /// `groups.peer.invite` on this (target) gateway. The response carries
    /// the target's FULL capability catalog — captured VERBATIM on the grant
    /// so `registerPeer` can send it unchanged (never reconstructed).
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
        // The catalog is REQUIRED for a registrable grant: registration
        // sends it verbatim upstream. A grant without one is malformed.
        guard let catalog = result["catalog"] else {
            throw RoomLinkError.malformed("groups.peer.invite missing 'catalog'")
        }
        let endpointURL = result["endpoint"]?.objectValue?["url"]?.stringValue
        let now = Date()
        return RoomLinkGrant(
            id: UUID().uuidString,
            token: grantToken,
            roomID: roomID,
            memberID: memberID,
            targetProfile: result["target_profile"]?.stringValue ?? "",
            permissions: RoomLinkGrant.Permission.allCases,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(ttlSeconds),
            catalog: ModernProfilesDecoder.toMetadataValue(catalog),
            endpointURL: endpointURL)
    }

    /// `groups.peer.register` on the room's gateway. Sends the grant's
    /// VERBATIM invite-time catalog — upstream validates it structurally
    /// (`GatewayRoomCatalog.from_mapping`, exact fields + digest) and
    /// compares it with the target's live probe catalog; any Fleet-side
    /// reconstruction would be rejected (or, worse, a stale synthetic one
    /// could misroute). Fails closed before the wire when the grant carries
    /// no complete catalog.
    public func registerPeer(
        roomID: String,
        memberID: String,
        grant: RoomLinkGrant,
        targetURL: String
    ) async throws -> RoomPeerRoute {
        if let refusal = RoomLinkCatalogValidation.validate(
            catalog: grant.catalog, targetProfile: grant.targetProfile
        ) {
            throw RoomLinkError.malformed(refusal)
        }
        let params: [String: JSONValue] = [
            "target_url": .string(targetURL),
            "catalog": Self.setupJSON(grant.catalog ?? .null),
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

    /// `groups.replicate` with a verbatim `groups.log` page for the room
    /// (assembled by `RoomReplicator` from the authority surface — never
    /// placeholders). Members are carried as the parsed JSON value so the
    /// authority's own member objects round-trip untouched.
    public func replicate(
        roomID: String, roomName: String, members: MetadataValue,
        page: MetadataValue
    ) async throws -> RoomReplicateReceipt {
        let result = try await requestMapped(
            method: "groups.replicate",
            params: .object([
                "room_id": .string(roomID),
                "room_name": .string(roomName),
                "members": Self.setupJSON(members),
                "page": Self.setupJSON(page),
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
    // MARK: - Replay source (manual replication choreography)

    /// `groups.state` room row → authority room profile (name + members
    /// verbatim — exactly what `groups.replicate` requires upstream).
    public func roomProfile(roomID: String) async throws -> RoomReplayProfile {
        let result = try await requestMapped(
            method: "groups.state",
            params: .object(["room_id": .string(roomID)]))
        guard let room = result["room"]?.objectValue else {
            throw RoomLinkError.malformed("groups.state missing 'room'")
        }
        guard let name = room["name"]?.stringValue, !name.isEmpty else {
            throw RoomLinkError.malformed("groups.state room has no name")
        }
        guard let members = room["members"] else {
            throw RoomLinkError.malformed("groups.state room has no members")
        }
        return RoomReplayProfile(
            roomID: room["room_id"]?.stringValue ?? roomID,
            name: name,
            members: ModernProfilesDecoder.toMetadataValue(members),
            authorityGatewayID: room["authority_gateway_id"]?.stringValue ?? "",
            authorityEpoch: room["authority_epoch"]?.numberValue.map(Int.init) ?? 0)
    }

    /// One `groups.log` page (VERBATIM result object — submitted to
    /// `groups.replicate` untouched; upstream read_events shape
    /// {events, cursor, latest_seq, has_more, authority}).
    public func logPage(roomID: String, sinceSeq: Int) async throws -> RoomReplayLogPage {
        let result = try await requestMapped(
            method: "groups.log",
            params: .object([
                "room_id": .string(roomID),
                "since_seq": .number(Double(sinceSeq)),
                "limit": .number(500),
            ]))
        guard let o = result.objectValue else {
            throw RoomLinkError.malformed("groups.log response not an object")
        }
        let authority = o["authority"]?.objectValue
        return RoomReplayLogPage(
            roomID: roomID,
            page: ModernProfilesDecoder.toMetadataValue(result),
            cursor: o["cursor"]?.numberValue.map(Int.init) ?? sinceSeq,
            latestSeq: o["latest_seq"]?.numberValue.map(Int.init) ?? 0,
            hasMore: o["has_more"]?.boolValue ?? false,
            authorityGatewayID: authority?["gateway_id"]?.stringValue ?? "",
            authorityEpoch: authority?["epoch"]?.numberValue.map(Int.init) ?? 0)
    }
}

extension GatewayRoomLinkClient: RoomReplaySourceProviding, RoomReplicateSink {}

extension GatewayRoomLinkClient: CrossGatewayRoomCommanding {
    public func roomLinkTarget(profile: String) async throws -> RoomLinkTargetSnapshot {
        let result = try await requestMapped(method: "groups.capabilities", params: .object(["profile": .string(profile)]))
        guard let catalog = result["room_link"]?["catalog"] else {
            throw RoomLinkError.malformed("RoomLink is not available on this gateway")
        }
        return RoomLinkTargetSnapshot(negotiation: Self.decodeNegotiation(result),
            catalog: ModernProfilesDecoder.toMetadataValue(catalog), driver: result["driver"]?.boolValue == true)
    }

    public func createScopedRoom(roomID: String, name: String, members: [MetadataValue]) async throws -> FleetRoom {
        let caps = try await requestMapped(method: "groups.capabilities", params: .object([:]))
        let methods = caps["methods"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard caps["driver"]?.boolValue == true, methods.contains("groups.create") else {
            throw RoomLinkError.malformed("This gateway cannot create hosted rooms")
        }
        let result = try await requestMapped(method: "groups.create", params: .object([
            "room_id": .string(roomID), "name": .string(name), "members": .array(members.map(Self.setupJSON))
        ]))
        guard let json = result["room"] else { throw RoomLinkError.malformed("Missing created room") }
        let row = try GatewayGroupsClient.decodeRoom(json)
        guard row.roomID == roomID, !row.authorityGatewayID.isEmpty, row.authorityEpoch > 0 else {
            throw RoomLinkError.malformed("Created room has no verified authority")
        }
        return FleetRoom(id: FleetRoomID(provenance: .hosted, gatewayID: gatewayID, key: row.roomID),
            name: row.name, members: row.members, revision: row.revision,
            hosted: HostedRoomState(authorityGatewayID: row.authorityGatewayID,
                authorityEpoch: row.authorityEpoch, latestSeq: row.latestSeq,
                advertisedMethods: methods, driverAvailable: true))
    }

    public func inviteScopedRoom(room: FleetRoom, profile: String, memberID: String) async throws -> ScopedRoomGrant {
        guard let authority = room.hosted else { throw RoomLinkError.malformed("Missing room authority") }
        let result = try await requestMapped(method: "groups.peer.invite", params: .object([
            "room_id": .string(room.id.key), "profile": .string(profile), "member_id": .string(memberID),
            "home_install_id": .string(authority.authorityGatewayID),
            "authority_gateway_id": .string(authority.authorityGatewayID),
            "authority_epoch": .number(Double(authority.authorityEpoch)), "ttl_seconds": .number(3600)
        ]))
        guard let token = result["grant"]?.stringValue, !token.isEmpty,
              result["target_profile"]?.stringValue == profile, let catalog = result["catalog"] else {
            throw RoomLinkError.malformed("The target did not return a scoped room grant")
        }
        return ScopedRoomGrant(token: token, profile: profile, catalog: ModernProfilesDecoder.toMetadataValue(catalog))
    }

    public func registerScopedPeer(roomID: String, memberID: String, target: RoomLinkTargetSnapshot, grant: ScopedRoomGrant) async throws {
        guard target.supportsTarget, grant.catalog == target.catalog,
              grant.profile == target.negotiation.profile, let endpoint = target.negotiation.endpoint?.url else {
            throw RoomLinkError.malformed("The target policy or capability catalog changed; refresh before linking")
        }
        let result = try await requestMapped(method: "groups.peer.register", params: .object([
            "room_id": .string(roomID), "member_id": .string(memberID),
            "target_url": .string(endpoint), "catalog": Self.setupJSON(grant.catalog),
            "target_profile": .string(grant.profile), "grant": .string(grant.token)
        ]))
        guard result["registered"]?.boolValue == true, result["mode"]?.stringValue == "direct",
              result["target_install_id"]?.stringValue == target.negotiation.installationID,
              result["target_profile"]?.stringValue == grant.profile else {
            throw RoomLinkError.malformed("The home gateway did not confirm the scoped direct route")
        }
    }

    public func revokeScopedPeer(_ grant: ScopedRoomGrant) async throws {
        _ = try await requestMapped(method: "groups.peer.revoke", params: .object([
            "grant": .string(grant.token), "profile": .string(grant.profile)
        ]))
    }

    private static func setupJSON(_ value: MetadataValue) -> JSONValue {
        switch value {
        case .null: return .null
        case .bool(let v): return .bool(v)
        case .number(let v): return .number(v)
        case .string(let v): return .string(v)
        case .array(let v): return .array(v.map(setupJSON))
        case .object(let v): return .object(v.mapValues(setupJSON))
        }
    }
}
