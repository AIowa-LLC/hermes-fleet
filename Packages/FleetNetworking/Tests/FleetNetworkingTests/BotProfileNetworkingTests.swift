import XCTest
import FleetCore
@testable import FleetNetworking

/// Slice 2 networking tests: profiles.describe / configure (per-section
/// dirty flags, partial success, model confirmation, ui_meta CAS conflict)
/// / create (seeds + credential semantics) / avatar clear / generic ui_meta
/// key write — against `InProcessWebSocketServer` fixtures with wire shapes
/// from upstream 08b140d. No live gateway.
final class BotProfileNetworkingTests: XCTestCase {

    // MARK: helpers (mirror BotModeNetworkingTests)

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

    // MARK: - profiles.describe

    func testDescribeDecodesFullSurface() async throws {
        let log = RequestLog()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "profiles.describe" {
                    return [Self.responseFrame(id: id, resultObject: #"""
                    {"name":"researcher","description":"research","soul":"SOUL TEXT",
                     "model":{"provider":"nous","default":"hermes"},
                     "skills":[{"name":"code","enabled":true},{"name":"web","enabled":false}],
                     "toolsets":[{"name":"fs","label":"Files","description":"file ops","tool_count":4,"enabled":true}],
                     "mcp_servers":[{"name":"srv","enabled":true,"transport":"http"}]}
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
        let client = GatewayBotModeClient(gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        let description = try await client.describeProfile("researcher")
        XCTAssertEqual(description.name, "researcher")
        XCTAssertEqual(description.soul, "SOUL TEXT")
        XCTAssertEqual(description.defaultModel, "hermes")
        XCTAssertEqual(description.provider, "nous")
        XCTAssertEqual(description.skills.count, 2)
        XCTAssertEqual(description.disabledSkillNames, ["web"])
        XCTAssertEqual(description.enabledToolsetNames, ["fs"])
        XCTAssertEqual(description.enabledMCPServerNames, ["srv"])
        XCTAssertEqual(description.toolsets.first?.toolCount, 4)
        XCTAssertEqual(description.mcpServers.first?.transport, "http")
        // Sent the right request shape.
        let params = log.params(of: "profiles.describe")
        XCTAssertEqual(params.first?["name"] as? String, "researcher")
    }

    // MARK: - profiles.configure per-section dirty flags

    func testConfigureSendsOnlyDirtySections() async throws {
        let log = RequestLog()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "profiles.configure" {
                    return [Self.responseFrame(id: id, resultObject: #"""
                    {"ok":true,"applied":{"description":true}}
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
        let client = GatewayBotModeClient(gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        // Only the description section is dirty — soul/model/skills/metadata
        // must NOT appear on the wire.
        let edit = BotProfileEdit(descriptionText: "new desc")
        let outcome = try await client.configureProfile("researcher", edit: edit)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.appliedSections, [.description])
        let params = try XCTUnwrap(log.params(of: "profiles.configure").first)
        XCTAssertEqual(params["name"] as? String, "researcher")
        XCTAssertEqual(params["description"] as? String, "new desc")
        XCTAssertNil(params["soul"])
        XCTAssertNil(params["model"])
        XCTAssertNil(params["ui_meta"])
        XCTAssertNil(params["disabled_skills"])
    }

    func testConfigurePartialSuccessDecodesAppliedAndFailed() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "profiles.configure" {
                    return [Self.responseFrame(id: id, resultObject: #"""
                    {"ok":false,"applied":{"soul":true,"model":false}}
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
        let client = GatewayBotModeClient(gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        let edit = BotProfileEdit(soul: "s", model: "m2", provider: "nous")
        let outcome = try await client.configureProfile("researcher", edit: edit)
        XCTAssertEqual(outcome.appliedSections, [.soul])
        XCTAssertEqual(outcome.failedSections, [.model])
        XCTAssertFalse(outcome.succeeded)
    }

    func testConfigureModelConfirmationSurfacesTyped() async throws {
        let log = RequestLog()
        let confirmations = Counter()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "profiles.configure" {
                    let params = (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any]
                    let confirmed = (params?["params"] as? [String: Any])?["confirm_expensive_model"] as? Bool ?? false
                    if !confirmed {
                        confirmations.increment()
                        return [Self.responseFrame(id: id, resultObject: #"""
                        {"ok":false,"applied":{},"confirm_required":true,"confirm_message":"Expensive model: confirm to continue"}
                        """#)]
                    }
                    return [Self.responseFrame(id: id, resultObject: #"""
                    {"ok":true,"applied":{"model":true}}
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
        let client = GatewayBotModeClient(gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        let edit = BotProfileEdit(model: "grand-model", provider: "nous")
        // First attempt: pending confirmation, model NOT applied.
        let pending = try await client.configureProfile("researcher", edit: edit)
        XCTAssertTrue(pending.confirmRequired)
        XCTAssertEqual(pending.confirmMessage, "Expensive model: confirm to continue")
        XCTAssertFalse(pending.succeeded)
        // Confirmation resend: ONLY the model section, with the confirm flag.
        let confirmed = try await client.configureProfile(
            "researcher", edit: edit.modelOnlyResend, confirmExpensiveModel: true)
        XCTAssertEqual(confirmed.appliedSections, [.model])
        XCTAssertTrue(confirmed.succeeded)
        let sentFrames = log.params(of: "profiles.configure")
        XCTAssertEqual(sentFrames.count, 2)
        XCTAssertNil(sentFrames.last?["soul"])
        XCTAssertEqual(sentFrames.last?["confirm_expensive_model"] as? Bool, true)
        XCTAssertEqual(confirmations.value, 1)
    }

    /// Locked counter for sendable script closures.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
        func increment() { lock.lock(); _value += 1; lock.unlock() }
    }

    func testConfigureMetadataCASConflictIsTypedNeverSilent() async throws {
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
        let client = GatewayBotModeClient(gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        let edit = BotProfileEdit(
            metadata: BotModeMetadata(title: "T"),
            metadataExpectedRevision: 3,
            previousMetadataRaw: .object(["unknownKey": .string("keep")]))
        do {
            _ = try await client.configureProfile("researcher", edit: edit)
            XCTFail("expected metadataConflict")
        } catch let error as BotModeProfileError {
            guard case .metadataConflict(let revisions, let conflicts) = error else {
                return XCTFail("expected metadataConflict, got \(error)")
            }
            XCTAssertEqual(revisions["hermes-bots"], 7)
            XCTAssertEqual(conflicts["hermes-bots"]?.expected, 3)
            XCTAssertEqual(conflicts["hermes-bots"]?.actual, 7)
        }
        // The wire carried the CAS header and the unknown-key round-trip.
    }

    func testConfigureMetadataSendsExpectedRevisionAndUnknownKeys() async throws {
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
        let client = GatewayBotModeClient(gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        var meta = BotModeMetadata(title: "New Title")
        meta.unknownKeys = [:]
        let edit = BotProfileEdit(
            metadata: meta,
            metadataExpectedRevision: 3,
            previousMetadataRaw: .object(["futureField": .string("retain-me")]))
        let outcome = try await client.configureProfile("researcher", edit: edit)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.newMetadataRevisions["hermes-bots"], 4)
        let params = try XCTUnwrap(log.params(of: "profiles.configure").first)
        let uiMeta = try XCTUnwrap(params["ui_meta"] as? [String: Any])
        let botsMeta = try XCTUnwrap(uiMeta["hermes-bots"] as? [String: Any])
        XCTAssertEqual(botsMeta["title"] as? String, "New Title")
        XCTAssertEqual(botsMeta["futureField"] as? String, "retain-me")
        let expected = try XCTUnwrap(params["ui_meta_expected_revisions"] as? [String: Any])
        XCTAssertEqual(expected["hermes-bots"] as? Int, 3)
    }

    // MARK: - profiles.create

    func testCreateFreshSendsWireDefaults() async throws {
        let log = RequestLog()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "profiles.create" {
                    return [Self.responseFrame(id: id, resultObject: #"""
                    {"ok":true,"name":"scribe","path":"/h/scribe","soul_written":true,"model_set":true,"mirrored":{"env":true}}
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
        let client = GatewayBotModeClient(gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        let spec = BotCreateSpec(name: "scribe", title: "Scribe", descriptionText: "writes things")
        let created = try await client.createProfile(spec)
        XCTAssertEqual(created, "scribe")
        let params = try XCTUnwrap(log.params(of: "profiles.create").first)
        XCTAssertEqual(params["name"] as? String, "scribe")
        XCTAssertEqual(params["description"] as? String, "writes things")
        XCTAssertEqual(params["share_auth"] as? Bool, false)
        XCTAssertEqual(params["mirror_credentials"] as? Bool, true)
        XCTAssertNil(params["clone_from"])
        XCTAssertNil(params["no_skills"])
    }

    func testCreateCloneAndNoSkillsShapes() async throws {
        let log = RequestLog()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "profiles.create" {
                    return [Self.responseFrame(id: id, resultObject: #"""
                    {"ok":true,"name":"x","path":"/h/x","soul_written":false,"model_set":false,"mirrored":{}}
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
        let client = GatewayBotModeClient(gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        _ = try await client.createProfile(
            BotCreateSpec(name: "researcher-2", seed: .clone(profile: "researcher", cloneAll: false)))
        _ = try await client.createProfile(
            BotCreateSpec(name: "blank", seed: .emptyNoSkills))
        let shapes = log.params(of: "profiles.create")
        XCTAssertEqual(shapes.count, 2)
        XCTAssertEqual(shapes[0]["clone_from"] as? String, "researcher")
        XCTAssertEqual(shapes[0]["clone_all"] as? Bool, false)
        XCTAssertNil(shapes[0]["no_skills"])
        XCTAssertEqual(shapes[1]["no_skills"] as? Bool, true)
        XCTAssertNil(shapes[1]["clone_from"])
    }

    // MARK: - avatar clear

    func testClearAvatarSendsClearTrue() async throws {
        let log = RequestLog()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "profiles.set_asset" {
                    return [Self.responseFrame(id: id, resultObject: #"""
                    {"ok":true,"asset":"avatar","size":0,"removed":1}
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
        let client = GatewayBotModeClient(gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        try await client.clearAvatarAsset(profile: "researcher")
        let params = try XCTUnwrap(log.params(of: "profiles.set_asset").first)
        XCTAssertEqual(params["name"] as? String, "researcher")
        XCTAssertEqual(params["asset"] as? String, "avatar")
        XCTAssertEqual(params["clear"] as? Bool, true)
        XCTAssertNil(params["data"])
    }

    // MARK: - generic ui_meta key write (sections registry)

    func testWriteUIMetaKeySendsOnlyThatKeyWithCAS() async throws {
        let log = RequestLog()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "profiles.configure" {
                    return [Self.responseFrame(id: id, resultObject: #"""
                    {"ok":true,"applied":{"ui_meta":true,"ui_meta_revisions":{"bot-sections-v1":2}}}
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
        let client = GatewayBotModeClient(gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        let registry = BotSectionRegistry.encode([
            BotSection(id: "sec-1", name: "Clients"),
            BotSection(id: "sec-2", name: "Ops"),
        ])
        let receipt = try await client.writeUIMetaKey(
            profile: "default", key: BotSectionRegistry.metaKey,
            value: registry, expectedRevision: 1)
        XCTAssertTrue(receipt.applied)
        XCTAssertEqual(receipt.newRevisions["bot-sections-v1"], 2)
        let params = try XCTUnwrap(log.params(of: "profiles.configure").first)
        let uiMeta = try XCTUnwrap(params["ui_meta"] as? [String: Any])
        XCTAssertEqual(uiMeta.count, 1, "only the named key is written")
        let sections = try XCTUnwrap(uiMeta["bot-sections-v1"] as? [[String: Any]])
        XCTAssertEqual(sections.first?["name"] as? String, "Clients")
        let expected = try XCTUnwrap(params["ui_meta_expected_revisions"] as? [String: Any])
        XCTAssertEqual(expected["bot-sections-v1"] as? Int, 1)
    }

    // MARK: - profiles.list ui_meta row read

    func testProfileUIMetaReadsNamedRow() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "profiles.list" {
                    return [Self.responseFrame(id: id, resultObject: #"""
                    {"profiles":[
                      {"name":"default","is_default":true,"ui_meta_revisions":{"bot-sections-v1":4},"ui_meta":{"bot-sections-v1":[{"id":"sec-1","name":"Clients"}]}},
                      {"name":"researcher","ui_meta_revisions":{}}
                    ]}
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
        let client = GatewayBotModeClient(gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        let meta = try await client.profileUIMeta(profile: "default")
        let sections = BotSectionRegistry.normalize(meta?[BotSectionRegistry.metaKey])
        XCTAssertEqual(sections, [BotSection(id: "sec-1", name: "Clients")])
        let revision = try await client.uiMetaRevision(profile: "default", key: BotSectionRegistry.metaKey)
        XCTAssertEqual(revision, 4)
        let missing = try await client.uiMetaRevision(profile: "researcher", key: BotSectionRegistry.metaKey)
        XCTAssertNil(missing)
        let absentProfile = try await client.profileUIMeta(profile: "ghost")
        XCTAssertNil(absentProfile)
    }
}
