import XCTest
import FleetCore
@testable import FleetNetworking

/// Bot Mode networking tests: modern profiles.list decoding, canonical
/// lookup/creation, metadata CAS, and hosted groups.* — all against
/// `InProcessWebSocketServer` fixtures using wire shapes captured from
/// upstream 08b140d source. No live gateway.
final class BotModeNetworkingTests: XCTestCase {

    // MARK: helpers

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

    private static func errorFrame(id: String, code: Int, message: String, data: String? = nil) -> String {
        if let data {
            return #"{"jsonrpc":"2.0","id":"\#(id)","error":{"code":\#(code),"message":"\#(message)","data":\#(data)}}}"#
        }
        return #"{"jsonrpc":"2.0","id":"\#(id)","error":{"code":\#(code),"message":"\#(message)"}}"#
    }

    /// Capture incoming requests for assertion.
    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [String] = []
        func record(_ frame: String) { lock.lock(); frames.append(frame); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return frames }
        func params(of method: String) -> [[String: Any]] {
            all.compactMap { frame in
                guard let data = frame.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      obj["method"] as? String == method else { return nil }
                return obj["params"] as? [String: Any]
            }
        }
    }

    // MARK: - modern profiles.list decoding

    /// Full modern wire shape (methods_profiles.py:225-254) — one row with
    /// canonical_session, worker_session, ui_meta_revisions, ui_meta.
    static let modernProfilesResult = #"""
    {"profiles":[{"name":"researcher","path":"/synthetic/home/profiles/researcher","is_default":false,"model":"hermes","provider":"nous","description":"research","display_name":"Researcher","skill_count":4,"last_session":{"id":"ls-1","title":"misc","preview":"hello","started_at":1700000000,"last_active":1700000500,"message_count":3},"worker_session":{"id":"wk-1","source":"kanban","title":"worker","last_active":1700000900},"canonical_session":{"id":"reg-1","resolved_id":"tip-9","root_title":"Bot Chat","title":"Bot Chat","preview":"canonical preview","started_at":1699990000,"last_active":1700000950,"message_count":42},"ui_meta_revisions":{"hermes-bots":3,"hermes-bots-groups":2},"ui_meta":{"hermes-bots":{"title":"Researcher","hidden":true,"futureField":{"nested":true}}},"has_avatar":true}],"bot_mode_protocol":true}
    """#

    func testModernProfilesDecode() throws {
        let json = try JSONDecoder().decode(JSONValue.self,
                                            from: Data(Self.modernProfilesResult.utf8))
        let decoded = try ModernProfilesDecoder.decode(json)
        XCTAssertEqual(decoded.profiles.count, 1)
        XCTAssertTrue(decoded.botModeProtocol)

        let p = try XCTUnwrap(decoded.profiles.first)
        XCTAssertEqual(p.name, "researcher")
        XCTAssertEqual(p.canonicalSession?.id, "reg-1")
        XCTAssertEqual(p.canonicalSession?.resolvedID, "tip-9")
        XCTAssertEqual(p.workerSession?.source, "kanban")
        XCTAssertEqual(p.uiMetaRevisions?["hermes-bots"], 3)
        XCTAssertEqual(p.botModeMetadata?.title, "Researcher")
        XCTAssertEqual(p.botModeMetadata?.hidden, true)
        // Unknown keys retained:
        XCTAssertEqual(p.botModeMetadata?.unknownKeys["futureField"], .object(["nested": .bool(true)]))
        XCTAssertTrue(p.hasAvatar)
    }

    func testOlderGatewayOmitsGracefully() throws {
        // Older gateway: only legacy fields — honest degradation, no fabrication.
        let older = #"{"profiles":[{"name":"default","path":"/h","is_default":true}]}"#
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(older.utf8))
        let decoded = try ModernProfilesDecoder.decode(json)
        let p = try XCTUnwrap(decoded.profiles.first)
        XCTAssertNil(p.canonicalSession)
        XCTAssertNil(p.workerSession)
        XCTAssertNil(p.uiMetaRevisions)
        XCTAssertNil(p.botModeMetadata)
        XCTAssertFalse(decoded.botModeProtocol)
    }

    // MARK: - canonical lookup over the wire

    func testCanonicalLookupSendsExactTitleAndHidden() async throws {
        let log = RequestLog()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "session.list" {
                    return [Self.responseFrame(id: id, resultObject: #"""
                    {"sessions":[{"id":"tip-9","resolved_id":"tip-9","title":"Bot Chat","preview":"p","message_count":7,"source":"bot_chat"}]}
                    """#)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayBotModeClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let lookup = try await client.lookupCanonicalChat(profile: "researcher")

        // Wire shape assertions: title-exact, hidden included.
        let params = log.params(of: "session.list").first
        XCTAssertEqual(params?["title"] as? String, "Bot Chat")
        XCTAssertEqual(params?["include_hidden"] as? Bool, true)
        XCTAssertEqual(params?["profile"] as? String, "researcher")
        XCTAssertEqual(lookup.rows.count, 1)
        XCTAssertEqual(lookup.first?.id, "tip-9")
    }

    func testCanonicalCreationSendsHiddenAndFollowsProfileConfig() async throws {
        let log = RequestLog()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                switch method {
                case "session.create":
                    return [Self.responseFrame(id: id, resultObject: #"{"session_id":"new-1","stored_session_id":"stored-1","message_count":0,"info":{}}"#)]
                case "session.title":
                    return [Self.responseFrame(id: id, resultObject: #"{"ok":true}"#)]
                default:
                    return []
                }
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayBotModeClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let id = try await client.createCanonicalChat(profile: "researcher")
        XCTAssertEqual(id, "new-1")

        let createParams = log.params(of: "session.create").first
        XCTAssertEqual(createParams?["title"] as? String, "Bot Chat")
        XCTAssertEqual(createParams?["hidden"] as? Bool, true)
        XCTAssertEqual(createParams?["follow_profile_config"] as? Bool, true)
        // Eager title write happened:
        let titleParams = log.params(of: "session.title").first
        XCTAssertEqual(titleParams?["title"] as? String, "Bot Chat")
    }

    // MARK: - metadata CAS

    func testMetadataWriteSendsExpectedRevisionAndDecodesReceipt() async throws {
        let log = RequestLog()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "profiles.configure" {
                    return [Self.responseFrame(id: id, resultObject: #"""
                    {"ok":true,"applied":{"ui_meta":true,"ui_meta_revisions":{"hermes-bots":4}}}
                    """#)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayBotModeClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        var meta = BotModeMetadata()
        meta.title = "Researcher"
        let receipt = try await client.writeBotMetadata(
            profile: "researcher", metadata: meta,
            expectedRevision: 3, previousRaw: nil)
        XCTAssertTrue(receipt.applied)
        XCTAssertEqual(receipt.newRevisions["hermes-bots"], 4)

        let params = log.params(of: "profiles.configure").first
        let expectedRevisions = params?["ui_meta_expected_revisions"] as? [String: Double]
        XCTAssertEqual(expectedRevisions?["hermes-bots"], 3)
        let uiMeta = params?["ui_meta"] as? [String: Any]
        XCTAssertNotNil(uiMeta?["hermes-bots"])
    }

    func testMetadataConflictIsTypedNotSilent() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "profiles.configure" {
                    return [Self.responseFrame(id: id, resultObject: #"""
                    {"ok":false,"applied":{"ui_meta":false,"ui_meta_conflicts":{"hermes-bots":{"expected":3,"actual":7}},"ui_meta_revisions":{"hermes-bots":7}}}
                    """#)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayBotModeClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        var meta = BotModeMetadata()
        meta.title = "Researcher"
        do {
            _ = try await client.writeBotMetadata(
                profile: "researcher", metadata: meta,
                expectedRevision: 3, previousRaw: nil)
            XCTFail("expected metadataConflict")
        } catch let error as BotModeProfileError {
            guard case .metadataConflict(let revisions, let conflicts) = error else {
                return XCTFail("expected metadataConflict, got \(error)")
            }
            XCTAssertEqual(revisions["hermes-bots"], 7)
            XCTAssertEqual(conflicts["hermes-bots"]?.actual, 7)
            XCTAssertEqual(conflicts["hermes-bots"]?.expected, 3)
        }
    }

    // MARK: - hosted groups client

    static let capabilitiesResult = #"""
    {"protocol_version":2,"driver":true,"persistent_process":true,"authority_gateway_id":"install:abc","room_link":{"enabled":false,"reason":"durable_run_storage_required"},"features":["authority_epoch","monotonic_log"],"methods":["groups.capabilities","groups.list","groups.create","groups.state","groups.send","groups.rename","groups.log","groups.disband","groups.stop","groups.retry","groups.approve"],"max_log_limit":500}
    """#

    static let roomRow = #"""
    {"room_id":"room-1","name":"Research Crew","members":"[{\"name\":\"researcher\"},{\"name\":\"writer\"}]","authority_gateway_id":"install:abc","authority_epoch":1,"revision":2,"created_at":1700000000.0,"updated_at":1700000500.0,"latest_seq":12}
    """#

    func testGroupsCapabilitiesDecode() throws {
        let json = try JSONDecoder().decode(JSONValue.self,
                                            from: Data(Self.capabilitiesResult.utf8))
        let caps = GatewayGroupsClient.decodeCapabilities(json)
        XCTAssertEqual(caps.protocolVersion, 2)
        XCTAssertTrue(caps.driver)
        XCTAssertFalse(caps.roomLinkEnabled)
        XCTAssertEqual(caps.roomLinkDisabledReason, "durable_run_storage_required")
        XCTAssertTrue(caps.methods.contains("groups.send"))
        XCTAssertEqual(caps.maxLogLimit, 500)
    }

    func testGroupsListAndRoomRowDecode() throws {
        let json = try JSONDecoder().decode(JSONValue.self,
                                            from: Data(#"{"rooms":[\#(Self.roomRow)],"next_offset":null}"#.utf8))
        let (rooms, next) = try GatewayGroupsClient.decodeRoomList(json)
        XCTAssertEqual(rooms.count, 1)
        XCTAssertNil(next)
        let room = rooms[0]
        XCTAssertEqual(room.roomID, "room-1")
        XCTAssertEqual(room.name, "Research Crew")
        XCTAssertEqual(room.members.count, 2)
        XCTAssertEqual(room.authorityEpoch, 1)
        XCTAssertEqual(room.latestSeq, 12)
    }

    func testGroupsLogDecode() throws {
        let logJSON = #"""
        {"events":[{"room_id":"room-1","seq":3,"event_id":"e-3","kind":"message.user","actor":{"kind":"user","id":"desktop"},"payload":{"text":"hello crew"},"created_at":1700000400.0},{"room_id":"room-1","seq":4,"event_id":"e-4","kind":"turn.failed","actor":{"kind":"gateway","id":"install:abc"},"payload":{"error":"boom","reason_code":"provider_auth_or_access"},"created_at":1700000500.0}],"cursor":4,"latest_seq":12,"has_more":true,"authority":{"gateway_id":"install:abc","epoch":1}}
        """#
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(logJSON.utf8))
        let page = try GatewayGroupsClient.decodeLogPage(json)
        XCTAssertEqual(page.events.count, 2)
        XCTAssertEqual(page.events[0].text, "hello crew")
        XCTAssertEqual(page.events[0].seq, 3)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.authority.epoch, 1)
        XCTAssertEqual(page.latestSeq, 12)
    }

    func testGroupsSendMintsEventIDAndDecodes() async throws {
        let log = RequestLog()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "groups.send" {
                    return [Self.responseFrame(id: id, resultObject: #"""
                    {"event":{"room_id":"room-1","seq":13,"event_id":"user:abc","kind":"message.user","actor":{"kind":"user","id":"desktop"},"payload":{"text":"hello"},"created_at":1700000600.0},"client_event_id":"fleet-x","accepted":true,"driver_started":true}
                    """#)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayGroupsClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let sent = try await client.send(roomID: "room-1", text: "hello")
        XCTAssertEqual(sent.seq, 13)

        let params = log.params(of: "groups.send").first
        XCTAssertEqual(params?["room_id"] as? String, "room-1")
        let eventID = params?["event_id"] as? String
        XCTAssertTrue(eventID?.hasPrefix("fleet-") == true,
                      "client-minted event id required for idempotency")
        let payload = params?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["text"] as? String, "hello")
    }

    func testForeignAuthorityAndConfirmErrorsMap() {
        XCTAssertEqual(
            GatewayGroupsClient.mapError(JSONRPCError(
                code: 4110, message: "This Group Chat is managed by another gateway.")),
            .foreignAuthority("This Group Chat is managed by another gateway."))
        XCTAssertEqual(
            GatewayGroupsClient.mapError(JSONRPCError(
                code: 4118, message: "promotion requires confirm=true acknowledging the previous authority can no longer commit")),
            .confirmRequired("promotion requires confirm=true acknowledging the previous authority can no longer commit"))
        guard case .unsupportedMethod = GatewayGroupsClient.mapError(
            JSONRPCError(code: -32601, message: "method not found")) else {
            return XCTFail("old gateway must map to unsupportedMethod")
        }
    }

    // MARK: - legacy projection over the roster path

    func testLegacyGroupProjectionTravelsThroughProfilesList() async throws {
        // The legacy rooms projection rides the default profile's ui_meta in
        // profiles.list — prove the full path: wire → ModernProfilesDecoder →
        // LegacyGroupProjectionDecoder.
        let groupsEnvelope = #"""
        {"version":3,"updatedAt":1700000500000,"rooms":{"id:r-abc":{"name":"Design Crew","roomId":"r-abc","revision":4,"members":[{"name":"researcher","connectionId":"workstation"}],"log":[{"id":"m1","from":{"kind":"member","name":"researcher"},"text":"shipping now","at":1700000400000}]}},"deleted":{}}
        """#
        // Embed the envelope as a raw JSON object in ui_meta.
        let rowJSON = #"{"name":"default","path":"/h","is_default":true,"ui_meta_revisions":{"hermes-bots-groups":2},"ui_meta":{"hermes-bots-groups":\#(groupsEnvelope)}}"#
        let json = try JSONDecoder().decode(JSONValue.self,
                                            from: Data(#"{"profiles":[\#(rowJSON)],"bot_mode_protocol":true}"#.utf8))
        let decoded = try ModernProfilesDecoder.decode(json)
        let p = try XCTUnwrap(decoded.profiles.first)

        let meta = ModernProfilesDecoder.toMetadataValue(
            json["profiles"]!.arrayValue![0]["ui_meta"]!["hermes-bots-groups"]!)
        let result = LegacyGroupProjectionDecoder.decode(
            gatewayID: GatewayID(rawValue: "workstation"), metaValue: meta)
        XCTAssertEqual(result.rooms.count, 1)
        XCTAssertEqual(result.rooms[0].name, "Design Crew")
        XCTAssertEqual(result.rooms[0].id.provenance, .desktopLegacy)
        XCTAssertEqual(result.rooms[0].id.key, "id:r-abc")
        XCTAssertEqual(result.rooms[0].recentLog.first?.text, "shipping now")
        _ = p
    }
}
