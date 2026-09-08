import XCTest
import FleetCore
@testable import FleetNetworking

/// TRUE BOTS MODE slice 5 (D19) RoomLink wire tests — every request/response
/// shape asserted against `groups.capabilities` / `groups.peer.*` /
/// `groups.replica_state` / `groups.replicate` / `groups.promote` /
/// `groups.demote` as implemented upstream. Originally derived from 08b140d;
/// re-verified against current upstream main 966637323e (2026-09-08).
/// All fixtures run against `InProcessWebSocketServer` — no live gateway.
final class RoomLinkNetworkingTests: XCTestCase {

    // MARK: helpers

    /// Async-safe request capture (NSLock is banned in async contexts on
    /// this toolchain). Returns JSON strings (Sendable) — parsed at the
    /// assertion site.
    actor Captured {
        var framesByMethod: [String: [String]] = [:]
        func record(frame: String) {
            guard let data = frame.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String else { return }
            framesByMethod[method, default: []].append(frame)
        }
        nonisolated func frames(of method: String) async -> [String] {
            await framesInternal(of: method)
        }
        private func framesInternal(of method: String) -> [String] {
            framesByMethod[method] ?? []
        }
    }

    private func makeTransport(serverPort: UInt16) -> GatewayWebSocketTransport {
        let base = URL(string: "http://127.0.0.1:\(serverPort)")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30),
            inboundDeadline: .seconds(30),
            connectTimeout: .seconds(10),
            requestTimeout: .seconds(2)
        )
        return GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: config
        )
    }

    private static func readyFrame() -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true,"heartbeat":false,"replay_epoch":"epoch-1"}}}"#
    }

    private static func extractRequest(_ frame: String) -> (id: String, method: String)? {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String else { return nil }
        return (id, method)
    }

    private static func responseFrame(id: String, resultObject: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","result":\#(resultObject)}"#
    }

    private static func errorFrame(id: String, code: Int, message: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","error":{"code":\#(code),"message":"\#(message)"}}"#
    }

    /// Parse a captured frame into its params dictionary.
    static func params(of frame: String?) -> [String: Any]? {
        guard let frame,
              let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["params"] as? [String: Any]
    }

    private func withClient(
        handler: @escaping @Sendable (_ id: String, _ method: String, _ respond: (String) -> Void) -> Void
    ) async throws -> (GatewayRoomLinkClient, InProcessWebSocketServer, GatewayWebSocketTransport, Captured) {
        let captured = Captured()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                Task { await captured.record(frame: frame) }
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                var frames: [String] = []
                handler(id, method) { resultObject in
                    frames.append(Self.responseFrame(id: id, resultObject: resultObject))
                }
                return frames
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        let client = GatewayRoomLinkClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        return (client, server, transport, captured)
    }

    // MARK: - groups.capabilities → RoomLinkNegotiation

    /// Wire shape from methods_groups.py:218-247 + hosted_room_peer.py:226-284.
    func testNegotiateDecodesCatalog() async throws {
        let digestA = String(repeating: "a", count: 64)
        let digestB = String(repeating: "b", count: 64)
        let (client, server, transport, _) = try await withClient { id, method, respond in
            guard method == "groups.capabilities" else { return }
            respond(#"{"protocol_version":2,"driver":true,"persistent_process":true,"authority_gateway_id":"install:home-1","room_link":{"enabled":true,"profile":"default","catalog":{"installation_id":"home-1","protocol_versions":[2],"link_modes":["direct"],"persistent_process":true,"text":true,"attachments":false,"execution_policy":{"version":1,"target_profile":"default","enabled_toolsets":["bot_room","web"],"approval_mode":"manual","max_iterations":12,"policy_digest":"\#(digestA)"},"catalog_digest":"\#(digestB)","endpoint":{"available":true,"url":"https://roomlink.example.test/v1","transport_security":"tls"}}},"features":["authority_epoch"],"methods":["groups.capabilities","groups.peer.invite","groups.peer.register","groups.peer.revoke"],"max_log_limit":500}"#)
        }
        defer {
            server.stop()
            Task { await transport.disconnect() }
        }

        let negotiation = try await client.negotiate()
        XCTAssertTrue(negotiation.enabled)
        XCTAssertEqual(negotiation.authorityGatewayID, "install:home-1")
        XCTAssertEqual(negotiation.protocolVersions, [2])
        XCTAssertTrue(negotiation.supportsProtocol(2))
        XCTAssertFalse(negotiation.supportsProtocol(1))
        XCTAssertEqual(negotiation.installationID, "home-1")
        XCTAssertEqual(negotiation.linkModes, ["direct"])
        XCTAssertTrue(negotiation.supportsDirectMode)
        XCTAssertTrue(negotiation.textOnly)
        XCTAssertFalse(negotiation.attachmentsSupported)
        XCTAssertEqual(negotiation.catalogDigest, digestB)
        XCTAssertEqual(negotiation.executionPolicy?.approvalMode, "manual")
        XCTAssertEqual(negotiation.executionPolicy?.targetProfile, "default")
        XCTAssertEqual(negotiation.endpoint?.url, "https://roomlink.example.test/v1")
        XCTAssertEqual(negotiation.endpoint?.transportSecurity, "tls")
        XCTAssertTrue(negotiation.supports("groups.peer.invite"))
        XCTAssertFalse(negotiation.supports("groups.promote"))
    }

    /// Disabled RoomLink: honest reason decoded and preserved.
    func testNegotiateDisabledReason() async throws {
        let (client, server, transport, _) = try await withClient { id, method, respond in
            guard method == "groups.capabilities" else { return }
            respond(#"{"protocol_version":2,"driver":true,"persistent_process":false,"authority_gateway_id":"install:home-2","room_link":{"enabled":false,"reason":"durable_run_storage_required"},"features":[],"methods":[],"max_log_limit":500}"#)
        }
        defer {
            server.stop()
            Task { await transport.disconnect() }
        }

        let negotiation = try await client.negotiate()
        XCTAssertFalse(negotiation.enabled)
        XCTAssertEqual(negotiation.disabledReason, .durableRunStorageRequired)
    }

    // MARK: - groups.peer.invite

    /// The full upstream catalog shape carried by invite responses.
    static let fullCatalogJSON = #"{"installation_id":"home-1","protocol_versions":[2],"link_modes":["direct"],"persistent_process":true,"text":true,"attachments":false,"execution_policy":{"version":1,"target_profile":"default","enabled_toolsets":["bot_room","web"],"approval_mode":"manual","max_iterations":12,"policy_digest":"\#(String(repeating: "a", count: 64))"},"catalog_digest":"\#(String(repeating: "b", count: 64))","endpoint":{"available":true,"url":"https://roomlink.example.test/v1","transport_security":"tls"}}"#

    func testInviteSendsTTLAndDecodesGrantWithVerbatimCatalog() async throws {
        let catalog = Self.fullCatalogJSON
        let response = #"{"grant":"grant-token-abcdef0123456789","target_profile":"researcher","catalog":"# + catalog + #","endpoint":{"available":true,"url":"https://roomlink.example.test/v1","transport_security":"tls"}}"#
        let (client, server, transport, captured) = try await withClient { id, method, respond in
            guard method == "groups.peer.invite" else { return }
            respond(response)
        }
        defer {
            server.stop()
            Task { await transport.disconnect() }
        }

        let grant = try await client.invite(roomID: "room-alpha", memberID: "m-1", ttlSeconds: 3600)
        XCTAssertEqual(grant.token, "grant-token-abcdef0123456789")
        XCTAssertEqual(grant.targetProfile, "researcher")
        XCTAssertEqual(grant.roomID, "room-alpha")
        XCTAssertEqual(grant.memberID, "m-1")
        XCTAssertTrue(grant.isValid())
        XCTAssertFalse(grant.displayToken.contains("grant-token-abcdef"), "token never fully rendered")
        // The grant captures the VERBATIM catalog — registration will send
        // it unchanged (never a reconstruction).
        let expectedCatalog = try JSONDecoder().decode(JSONValue.self, from: Data(Self.fullCatalogJSON.utf8))
        XCTAssertEqual(grant.catalog, ModernProfilesDecoder.toMetadataValue(expectedCatalog))
        XCTAssertEqual(grant.endpointURL, "https://roomlink.example.test/v1")

        // Wire carries ttl_seconds + room/member scope.
        let params = Self.params(of: await captured.frames(of: "groups.peer.invite").first)
        XCTAssertEqual(params?["ttl_seconds"] as? Double, 3600)
        XCTAssertEqual(params?["room_id"] as? String, "room-alpha")
        XCTAssertEqual(params?["member_id"] as? String, "m-1")
    }

    /// A grant WITHOUT a catalog is malformed — registration can never be
    /// assembled from it (fail closed at decode time).
    func testInviteWithoutCatalogIsMalformed() async throws {
        let (client, server, transport, _) = try await withClient { id, method, respond in
            guard method == "groups.peer.invite" else { return }
            respond(#"{"grant":"grant-token-abcdef0123456789","target_profile":"researcher"}"#)
        }
        defer {
            server.stop()
            Task { await transport.disconnect() }
        }
        do {
            _ = try await client.invite(roomID: "room-alpha", memberID: "m-1", ttlSeconds: 3600)
            XCTFail("expected malformed refusal")
        } catch let error as GatewayRoomLinkClient.RoomLinkError {
            guard case .malformed(let message) = error else {
                return XCTFail("unexpected error shape: \(error)")
            }
            XCTAssertTrue(message.contains("catalog"), "refusal names the missing catalog")
        }
    }

    /// TTL out of bounds → the gateway's exact error message surfaces
    /// (methods_groups.py:262 "ttl_seconds must be between 60 and 86400").
    func testInviteTTLOutOfBoundsSurfacesGatewayError() async throws {
        let (client, server, transport, _) = try await withClient { id, method, respond in
            return  // handled via error below
        }
        // This test needs an ERROR response; the helper only produces results,
        // so drive it with a dedicated script.
        server.stop()
        try await transport.disconnect()
        try await runInviteTTLError()
    }

    private func runInviteTTLError() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame),
                      method == "groups.peer.invite" else { return [] }
                return [Self.errorFrame(
                    id: id, code: 4120,
                    message: "ttl_seconds must be between 60 and 86400")]
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayRoomLinkClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.invite(roomID: "room-alpha", memberID: "m-1", ttlSeconds: 10)
            XCTFail("expected error")
        } catch let error as GatewayRoomLinkClient.RoomLinkError {
            guard case .rpcFailed(let message, let code) = error else {
                return XCTFail("unexpected error shape: \(error)")
            }
            XCTAssertEqual(message, "ttl_seconds must be between 60 and 86400")
            XCTAssertEqual(code, 4120)
        }
    }

    // MARK: - groups.peer.register

    /// Builds a registrable grant: full verbatim catalog as the invite
    /// response would carry it.
    private func makeCatalogGrant(profile: String = "researcher") throws -> RoomLinkGrant {
        let catalog = try JSONDecoder().decode(JSONValue.self, from: Data(Self.fullCatalogJSON.utf8))
        return RoomLinkGrant(
            id: "g", token: "tok", roomID: "room-alpha", memberID: "m-1",
            targetProfile: profile, permissions: [.dispatch],
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(3600),
            catalog: ModernProfilesDecoder.toMetadataValue(catalog),
            endpointURL: "https://roomlink.example.test/v1")
    }

    func testRegisterPeerSendsVerbatimCatalogAndDecodesRoute() async throws {
        let (client, server, transport, captured) = try await withClient { id, method, respond in
            guard method == "groups.peer.register" else { return }
            respond(#"{"registered":true,"mode":"direct","transport_security":"tls","target_install_id":"home-1","target_profile":"researcher"}"#)
        }
        defer {
            server.stop()
            Task { await transport.disconnect() }
        }

        let grant = try makeCatalogGrant()
        let route = try await client.registerPeer(
            roomID: "room-alpha", memberID: "m-1", grant: grant,
            targetURL: "https://roomlink.example.test/v1")

        XCTAssertEqual(route.roomID, "room-alpha")
        XCTAssertEqual(route.memberID, "m-1")
        XCTAssertEqual(route.targetInstallID, "home-1")
        XCTAssertEqual(route.mode, "direct")
        XCTAssertEqual(route.transportSecurity, "tls")
        XCTAssertEqual(route.status, .ready)

        let params = Self.params(of: await captured.frames(of: "groups.peer.register").first)
        XCTAssertEqual(params?["target_url"] as? String, "https://roomlink.example.test/v1")
        XCTAssertEqual(params?["grant"] as? String, "tok")
        XCTAssertEqual(params?["room_id"] as? String, "room-alpha")
        XCTAssertEqual(params?["member_id"] as? String, "m-1")
        XCTAssertEqual(params?["target_profile"] as? String, "researcher")
        // REGRESSION GUARD (defect 1): the wire catalog must be the COMPLETE
        // upstream catalog (_CATALOG_FIELDS) sent verbatim — never a partial
        // or synthetic reconstruction. installation_id must be the target's
        // installation identity, never the profile name.
        let wireCatalog = try XCTUnwrap(params?["catalog"] as? [String: Any])
        let required: Set<String> = [
            "installation_id", "protocol_versions", "link_modes", "persistent_process",
            "text", "attachments", "execution_policy", "catalog_digest"]
        let missing = required.subtracting(wireCatalog.keys)
        XCTAssertTrue(missing.isEmpty, "registerPeer sent an incomplete catalog (missing: \(missing.sorted()))")
        XCTAssertEqual(wireCatalog["installation_id"] as? String, "home-1")
        XCTAssertNotEqual(wireCatalog["installation_id"] as? String, grant.targetProfile,
                          "installation_id must never be the profile name (stale-path defect)")
        XCTAssertEqual((wireCatalog["protocol_versions"] as? [Int]) ?? [], [2])
        XCTAssertEqual(wireCatalog["link_modes"] as? [String], ["direct"])
        XCTAssertNotNil(wireCatalog["execution_policy"] as? [String: Any])
        XCTAssertEqual(wireCatalog["catalog_digest"] as? String, String(repeating: "b", count: 64))
        // Verbatim equality: the sent catalog equals the grant's catalog.
        let sentData = try JSONSerialization.data(withJSONObject: wireCatalog)
        let sentValue = try JSONDecoder().decode(JSONValue.self, from: sentData)
        let expectedCatalog = try JSONDecoder().decode(JSONValue.self, from: Data(Self.fullCatalogJSON.utf8))
        XCTAssertEqual(
            ModernProfilesDecoder.toMetadataValue(sentValue),
            ModernProfilesDecoder.toMetadataValue(expectedCatalog))
    }

    /// REGRESSION (defect 1): a grant whose catalog is missing/partial must
    /// NEVER reach the wire — registration fails closed client-side.
    func testRegisterPeerFailsClosedOnIncompleteCatalog() async throws {
        let (client, server, transport, captured) = try await withClient { id, method, respond in
            guard method == "groups.peer.register" else { return }
            respond(#"{"registered":true,"mode":"direct","transport_security":"tls","target_install_id":"home-1","target_profile":"researcher"}"#)
        }
        defer {
            server.stop()
            Task { await transport.disconnect() }
        }

        // The OLD stale-path shape: partial two-field catalog with a
        // synthetic installation_id taken from the profile.
        let staleGrant = RoomLinkGrant(
            id: "g", token: "tok", roomID: "room-alpha", memberID: "m-1",
            targetProfile: "researcher", permissions: [.dispatch],
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(3600),
            catalog: .object([
                "installation_id": .string("researcher"),
                "catalog_digest": .string(String(repeating: "b", count: 64)),
            ]),
            endpointURL: "https://roomlink.example.test/v1")
        do {
            _ = try await client.registerPeer(
                roomID: "room-alpha", memberID: "m-1", grant: staleGrant,
                targetURL: "https://roomlink.example.test/v1")
            XCTFail("expected fail-closed refusal")
        } catch let error as GatewayRoomLinkClient.RoomLinkError {
            guard case .malformed(let message) = error else {
                return XCTFail("unexpected error shape: \(error)")
            }
            XCTAssertTrue(
                message.contains("incomplete") || message.contains("synthetic"),
                "refusal explains the catalog problem: \(message)")
        }
        // No register frame ever hit the wire.
        let frames = await captured.frames(of: "groups.peer.register")
        XCTAssertTrue(frames.isEmpty, "fail-closed: no wire call with a bad catalog")
    }

    /// REGRESSION (defect 1): a grant with NO catalog at all fails closed.
    func testRegisterPeerFailsClosedOnMissingCatalog() async throws {
        let (client, server, transport, _) = try await withClient { id, method, respond in
            guard method == "groups.peer.register" else { return }
            respond(#"{"registered":true,"mode":"direct","transport_security":"tls","target_install_id":"home-1","target_profile":"researcher"}"#)
        }
        defer {
            server.stop()
            Task { await transport.disconnect() }
        }
        let grant = RoomLinkGrant(
            id: "g", token: "tok", roomID: "room-alpha", memberID: "m-1",
            targetProfile: "researcher", permissions: [.dispatch],
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(3600))
        do {
            _ = try await client.registerPeer(
                roomID: "room-alpha", memberID: "m-1", grant: grant,
                targetURL: "https://roomlink.example.test/v1")
            XCTFail("expected refusal")
        } catch let error as GatewayRoomLinkClient.RoomLinkError {
            guard case .malformed = error else {
                return XCTFail("unexpected error shape: \(error)")
            }
        }
    }

    /// peer.register refusal (5120) with the EXACT upstream message decoded
    /// into the typed refusal.
    func testRegisterPeerRefusalDecodesExactWireString() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame),
                      method == "groups.peer.register" else { return [] }
                return [Self.errorFrame(
                    id: id, code: 5120,
                    message: "target capability catalog changed during setup")]
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayRoomLinkClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        var grant = RoomLinkGrant(
            id: "g", token: "tok", roomID: "room-alpha", memberID: "m-1",
            targetProfile: "researcher", permissions: [.dispatch],
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(3600))
        let catalog = try JSONDecoder().decode(JSONValue.self, from: Data(Self.fullCatalogJSON.utf8))
        grant = RoomLinkGrant(
            id: "g", token: "tok", roomID: "room-alpha", memberID: "m-1",
            targetProfile: "researcher", permissions: [.dispatch],
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(3600),
            catalog: ModernProfilesDecoder.toMetadataValue(catalog),
            endpointURL: "https://roomlink.example.test/v1")
        do {
            _ = try await client.registerPeer(
                roomID: "room-alpha", memberID: "m-1", grant: grant,
                targetURL: "https://roomlink.example.test/v1")
            XCTFail("expected refusal")
        } catch let error as GatewayRoomLinkClient.RoomLinkError {
            guard case .registrationRefusal(let message) = error else {
                return XCTFail("unexpected error shape: \(error)")
            }
            XCTAssertEqual(
                RoomLinkRegistrationRefusal(wireMessage: message),
                .catalogChangedDuringSetup)
        }
    }

    // MARK: - groups.replica_state / replicate / promote / demote

    func testReplicaStateDecodesAndReturnsNilWhenMissing() async throws {
        let replicaResult = #"{"room_id":"room-alpha","name":"Launch Crew","members":[],"authority":{"gateway_id":"install:home-1","epoch":3},"last_seq":10,"latest_seq":10,"event_bytes":4096,"created_at":1.0,"updated_at":2.0}"#
        // First call: replica not found (4117). Second: present.
        let box = ResponseSequenceBox()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame),
                      method == "groups.replica_state" else { return [] }
                if box.takeFirst() {
                    return [Self.errorFrame(id: id, code: 4117, message: "replica not found")]
                }
                return [Self.responseFrame(id: id, resultObject: replicaResult)]
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayRoomLinkClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let none = try await client.replicaState(roomID: "room-alpha")
        XCTAssertNil(none, "absence is not an error")
        let replica = try await client.replicaState(roomID: "room-alpha")
        XCTAssertEqual(replica?.authorityGatewayID, "install:home-1")
        XCTAssertEqual(replica?.authorityEpoch, 3)
        XCTAssertEqual(replica?.lastSeq, 10)
        XCTAssertTrue(replica?.isCaughtUp ?? false)
    }

    func testReplicateSendsVerbatimPageAndDecodesReceipt() async throws {
        let (client, server, transport, captured) = try await withClient { id, method, respond in
            guard method == "groups.replicate" else { return }
            respond(#"{"room_id":"room-alpha","stored_seq":10,"ingested":4,"authority":{"gateway_id":"install:home-1","epoch":3},"caught_up":true}"#)
        }
        defer {
            server.stop()
            Task { await transport.disconnect() }
        }

        // A REAL groups.log page shape (verbatim read_events result).
        let page: MetadataValue = .object([
            "events": .array([
                .object([
                    "room_id": .string("room-alpha"), "seq": .number(9),
                    "event_id": .string("evt-9"), "kind": .string("message.user"),
                    "actor": .object(["kind": .string("member"), "id": .string("m-1")]),
                    "authority_epoch": .number(3),
                    "payload": .object(["text": .string("hello")]),
                    "created_at": .number(1.5),
                ]),
            ]),
            "cursor": .number(9), "latest_seq": .number(10), "has_more": .bool(false),
            "authority": .object(["gateway_id": .string("install:home-1"), "epoch": .number(3)]),
        ])
        let members: MetadataValue = .array([
            .object(["member_id": .string("m-1"), "profile": .string("researcher")]),
        ])
        let receipt = try await client.replicate(
            roomID: "room-alpha", roomName: "Launch Crew",
            members: members, page: page)

        XCTAssertEqual(receipt.storedSeq, 10)
        XCTAssertEqual(receipt.ingested, 4)
        XCTAssertTrue(receipt.caughtUp)
        XCTAssertEqual(receipt.authorityEpoch, 3)

        let params = Self.params(of: await captured.frames(of: "groups.replicate").first)
        XCTAssertEqual(params?["room_id"] as? String, "room-alpha")
        XCTAssertEqual(params?["room_name"] as? String, "Launch Crew")
        // REGRESSION GUARD (defect 2): the wire page must be the FULL
        // authority-stamped page — events list, authority lineage, sequence
        // information, latest_seq — never `{}`, never placeholders.
        let pageObj = try XCTUnwrap(params?["page"] as? [String: Any])
        XCTAssertNotNil(pageObj["events"] as? [[String: Any]], "page.events required")
        let authority = try XCTUnwrap(pageObj["authority"] as? [String: Any], "page.authority required")
        XCTAssertEqual(authority["gateway_id"] as? String, "install:home-1")
        XCTAssertEqual(authority["epoch"] as? Int, 3)
        XCTAssertNotNil(pageObj["latest_seq"], "page.latest_seq required")
        let wireMembers = try XCTUnwrap(params?["members"] as? [[String: Any]], "members required")
        XCTAssertFalse(wireMembers.isEmpty, "members must never be empty")
        let wireName = try XCTUnwrap(params?["room_name"] as? String)
        XCTAssertFalse(wireName.isEmpty, "room_name must never be empty")
    }

    func testPromoteSendsConfirmAndDecodesReceipt() async throws {
        let (client, server, transport, captured) = try await withClient { id, method, respond in
            guard method == "groups.promote" else { return }
            respond(#"{"room_id":"room-alpha","authority_gateway_id":"install:home-1","authority_epoch":4,"previous_gateway_id":"install:old","previous_epoch":3,"claim_seq":11,"latest_seq":10}"#)
        }
        defer {
            server.stop()
            Task { await transport.disconnect() }
        }

        let receipt = try await client.promote(roomID: "room-alpha", confirm: true)
        XCTAssertEqual(receipt.authorityEpoch, 4)
        XCTAssertEqual(receipt.previousGatewayID, "install:old")
        XCTAssertEqual(receipt.previousEpoch, 3)
        XCTAssertEqual(receipt.claimSeq, 11)

        // The wire carries confirm:true ONLY after explicit user consent.
        let params = Self.params(of: await captured.frames(of: "groups.promote").first)
        XCTAssertEqual(params?["confirm"] as? Bool, true)
        XCTAssertEqual(params?["room_id"] as? String, "room-alpha")
    }

    /// promote WITHOUT confirm returns the upstream 4118 handshake — the
    /// client surfaces it as the typed confirmRequired error, never silently
    /// promoting (methods_groups.py:513-515).
    func testPromoteWithoutConfirmSurfaces4118() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame),
                      method == "groups.promote" else { return [] }
                return [Self.errorFrame(
                    id: id, code: 4118,
                    message: "promotion requires confirm=true acknowledging the previous authority can no longer commit")]
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayRoomLinkClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.promote(roomID: "room-alpha", confirm: false)
            XCTFail("expected confirmRequired")
        } catch let error as GatewayRoomLinkClient.RoomLinkError {
            guard case .confirmRequired = error else {
                return XCTFail("unexpected error shape: \(error)")
            }
        }
    }

    func testDemoteSendsObservedAuthority() async throws {
        let (client, server, transport, captured) = try await withClient { id, method, respond in
            guard method == "groups.demote" else { return }
            respond(#"{"room_id":"room-alpha","authority_gateway_id":"install:home-1","authority_epoch":4,"idempotent":true}"#)
        }
        defer {
            server.stop()
            Task { await transport.disconnect() }
        }

        try await client.demote(
            roomID: "room-alpha", observedGatewayID: "install:home-1", observedEpoch: 4)
        let params = Self.params(of: await captured.frames(of: "groups.demote").first)
        XCTAssertEqual(params?["observed_gateway_id"] as? String, "install:home-1")
        XCTAssertEqual(params?["observed_epoch"] as? Int, 4)
        XCTAssertEqual(params?["room_id"] as? String, "room-alpha")
    }
}

/// One-shot mutable flag safe for the @Sendable script closure (unchecked:
/// single boolean toggle, no invariants).
final class ResponseSequenceBox: @unchecked Sendable {
    private var first = true
    func takeFirst() -> Bool {
        let was = first
        first = false
        return was
    }
}
