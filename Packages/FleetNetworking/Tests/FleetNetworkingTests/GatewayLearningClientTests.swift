import XCTest
import FleetCore
@testable import FleetNetworking

/// R9-T7: `GatewayLearningClient` — read-only learning star map over the
/// conversation transport, against an in-process fixture server. Wire shapes
/// verified against hermes-agent 0.21.0 installed source:
/// - `learning.frames` handler (tui_gateway/methods_tools.py:1840-1862):
///   params `{cols, rows, frames}` (int-coerced, floored: cols≥20, rows≥10,
///   frames clamped 2…240); result is `render_frames`
///   (agent/learning_graph_render.py:626-657) —
///   `{frames: [...grid...], legend, categories, buckets, summary, axis,
///   count, cols, rows}`.
/// - `buckets` rows (`_bucket_rows`, learning_graph_render.py:345-361):
///   `{index, label, date, skills, memories, total, category, color,
///   nodes: [{id, glyph, label, fullLabel, meta, body, style}]}`.
/// - `summary` (build_summary :586-606): `[str]`; `axis` (:566-570):
///   `{start, end}`; `count` (int).
/// - `learning.detail` handler (methods_tools.py:1864-1872) →
///   `node_detail` (agent/learning_mutations.py:86-118):
///   `{ok: true, kind, id, label, content}`; failure `{ok: false, message}`.
/// - NO `learning.graph` method exists on the WS registry (verified by
///   exhaustive @method scan); the structured nodes+edges payload is
///   desktop-REST only (web_server.py:4412 `GET /api/learning/graph`).
final class GatewayLearningClientTests: XCTestCase {

    // MARK: helpers

    private func makeTransport(
        serverPort: UInt16,
        requestTimeout: Duration = .seconds(2)
    ) -> GatewayWebSocketTransport {
        let base = URL(string: "http://127.0.0.1:\(serverPort)")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30),
            inboundDeadline: .seconds(30),
            connectTimeout: .seconds(10),
            requestTimeout: requestTimeout
        )
        return GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: config
        )
    }

    private static func frame(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private static func readyFrame() -> String {
        frame([
            "jsonrpc": "2.0", "method": "event",
            "params": [
                "type": "gateway.ready",
                "payload": ["change_events": true, "heartbeat": false, "replay_epoch": "epoch-1"],
            ] as [String: Any],
        ])
    }

    private static func extractRequest(_ frameText: String) -> (id: String, method: String, params: [String: Any])? {
        guard let data = frameText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String else { return nil }
        return (id, method, obj["params"] as? [String: Any] ?? [:])
    }

    private static func responseFrame(id: String, result: [String: Any]) -> String {
        frame(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func errorFrame(id: String, code: Int, message: String) -> String {
        frame(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// A captured `render_frames` result shaped like the live mac profile
    /// (two date buckets; skills + memories; grid runs omitted here — the
    /// client must ignore them anyway).
    private static func framesResult() -> [String: Any] {
        [
            "frames": [
                [
                    "reveal": 0.0, "date": "", "visible": 0,
                    "grid": [[["trajectory ", "label", 0.55]]],
                    "labels": [] as [[String: Any]],
                ],
                [
                    "reveal": 1.0, "date": "4 Sep 2026", "visible": 14,
                    "grid": [] as [[Any]],
                    "labels": [] as [[String: Any]],
                ],
            ],
            "legend": [
                ["glyph": "●", "style": "skill", "label": "skills (4)"],
                ["glyph": "◆", "style": "memory", "label": "memories (10)"],
            ],
            "categories": [
                ["glyph": "●", "color": "#8FA85B", "label": "apple-product-factory (2)"],
                ["glyph": "●", "color": "#8F5BA8", "label": "skills (1)"],
            ],
            "buckets": [
                [
                    "index": 0,
                    "label": "3 Sep",
                    "date": "3 Sep 2026",
                    "skills": 1,
                    "memories": 1,
                    "total": 2,
                    "category": "software-development",
                    "color": "#5BA88F",
                    "nodes": [
                        [
                            "id": "test-driven-development",
                            "glyph": "●",
                            "label": "test-driven-development",
                            "fullLabel": "test-driven-development",
                            "meta": "software-development · 3 Sep 2026 · x12",
                            "body": "",
                            "style": "skill",
                        ],
                        [
                            "id": "memory:profile:0",
                            "glyph": "◆",
                            "label": "apple-dev profile memory",
                            "fullLabel": "apple-dev profile memory",
                            "meta": "profile memory · 3 Sep 2026",
                            "body": "# apple-dev profile memory\n\nVerified lessons.",
                            "style": "memory",
                        ],
                    ],
                ],
                [
                    "index": 1,
                    "label": "4 Sep",
                    "date": "4 Sep 2026",
                    "skills": 2,
                    "memories": 0,
                    "total": 2,
                    "category": "apple-product-factory",
                    "color": "#8FA85B",
                    "nodes": [
                        [
                            "id": "ios-xcode-project-pipeline",
                            "glyph": "●",
                            "label": "ios-xcode-project-pipeline",
                            "fullLabel": "ios-xcode-project-pipeline",
                            "meta": "apple-product-factory · 4 Sep 2026 · x66",
                            "body": "",
                            "style": "skill",
                        ],
                        [
                            "id": "memory:memory:9",
                            "glyph": "◆",
                            "label": "apple-dev profile memory",
                            "fullLabel": "apple-dev profile memory",
                            "meta": "memory · 4 Sep 2026",
                            "body": "# apple-dev profile memory\n\nLatest chunk.",
                            "style": "memory",
                        ],
                    ],
                ],
            ],
            "summary": [
                "4 learned skills · 10 memories · 3 skill links",
                "10 memory↔skill links · busiest day 4 Sep · 8 learned",
            ],
            "axis": ["start": "3 Sep 2026", "end": "4 Sep 2026"],
            "count": 14,
            "cols": 60,
            "rows": 20,
        ]
    }

    // MARK: 1. learning.frames ask + decode

    func testLearningGraphAsksFramesWithMinimalFrameCountAndDecodesBuckets() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "learning.frames" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: Self.framesResult())]
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

        let client = GatewayLearningClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let graph = try await client.learningGraph(profile: nil)

        // Wire ask: the grid runs we never paint are O(frames) — ask for the
        // server floor (frames clamps to ≥2, learning_graph_render.py:627).
        let (method, params) = await captured.last
        XCTAssertEqual(method, "learning.frames")
        XCTAssertEqual(params["cols"] as? Int, 60)
        XCTAssertEqual(params["rows"] as? Int, 20)
        XCTAssertEqual(params["frames"] as? Int, 2,
                       "pre-rendered grid runs are O(frames) dead weight (~69 KB at 48) — ask for the floor")

        // Buckets decode chronologically with nodes + category.
        XCTAssertEqual(graph.buckets.count, 2)
        let first = graph.buckets[0]
        XCTAssertEqual(first.label, "3 Sep")
        XCTAssertEqual(first.date, "3 Sep 2026")
        XCTAssertEqual(first.category, "software-development")
        XCTAssertEqual(first.nodes.count, 2)
        let skill = first.nodes[0]
        XCTAssertEqual(skill.id, "test-driven-development")
        XCTAssertEqual(skill.label, "test-driven-development")
        XCTAssertFalse(skill.isMemory, "style 'skill' → circle node")
        XCTAssertEqual(skill.meta, "software-development · 3 Sep 2026 · x12")
        let memory = first.nodes[1]
        XCTAssertEqual(memory.id, "memory:profile:0")
        XCTAssertTrue(memory.isMemory, "style 'memory' → diamond node")
        XCTAssertEqual(memory.body, "# apple-dev profile memory\n\nVerified lessons.")

        // Summary + axis + count.
        XCTAssertEqual(graph.summary.lines.count, 2)
        XCTAssertEqual(graph.summary.lines[0], "4 learned skills · 10 memories · 3 skill links")
        XCTAssertEqual(graph.summary.start, "3 Sep 2026")
        XCTAssertEqual(graph.summary.end, "4 Sep 2026")
        XCTAssertEqual(graph.summary.totalCount, 14)

        // Derived counts.
        XCTAssertEqual(graph.skillsCount, 2)
        XCTAssertEqual(graph.memoriesCount, 2)
        XCTAssertEqual(graph.nodes.count, 4)
    }

    func testLearningGraphWithProfileSendsScope() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "learning.frames" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "frames": [] as [[String: Any]],
                        "buckets": [] as [[String: Any]],
                        "summary": [] as [String],
                        "axis": ["start": "oldest", "end": "now"],
                        "count": 0,
                    ])]
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

        let client = GatewayLearningClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let graph = try await client.learningGraph(profile: "default")

        XCTAssertTrue(graph.buckets.isEmpty)
        XCTAssertEqual(graph.summary.totalCount, 0)
        let (_, params) = await captured.last
        XCTAssertEqual(params["profile"] as? String, "default",
                       "profile scope forwards (cron/skills-style HERMES_HOME scoping)")
    }

    func testEmptyGraphDecodesAsHonestEmptyNotError() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "learning.frames" {
                    // Empty profile: render_frames still returns the envelope
                    // with a placeholder grid and NO buckets.
                    return [Self.responseFrame(id: id, result: [
                        "frames": [["reveal": 1.0, "date": "", "visible": 0,
                                    "grid": [[["no learning yet — keep using Hermes and it maps out here", "dim", 0.7]]],
                                    "labels": [] as [[String: Any]]]],
                        "legend": [
                            ["glyph": "●", "style": "skill", "label": "skills (0)"],
                            ["glyph": "◆", "style": "memory", "label": "memories (0)"],
                        ],
                        "categories": [] as [[String: Any]],
                        "buckets": [] as [[String: Any]],
                        "summary": ["0 learned skills · 0 memories · 0 skill links"],
                        "axis": ["start": "oldest", "end": "now"],
                        "count": 0,
                        "cols": 60,
                        "rows": 20,
                    ])]
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

        let client = GatewayLearningClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let graph = try await client.learningGraph(profile: nil)

        XCTAssertTrue(graph.buckets.isEmpty, "no learning yet is a valid state, not an error")
        XCTAssertEqual(graph.summary.totalCount, 0)
    }

    func testMalformedFramesResultThrowsMalformedResponse() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "learning.frames" {
                    // Not the render_frames envelope at all.
                    return [Self.responseFrame(id: id, result: ["unexpected": true])]
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

        let client = GatewayLearningClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.learningGraph(profile: nil)
            XCTFail("malformed envelope must throw")
        } catch let error as GatewayLearningError {
            XCTAssertEqual(error, .malformedResponse("learning.frames result missing 'buckets'"))
        }
    }

    // MARK: 2. learning.detail

    func testNodeDetailSendsIdAndDecodesContent() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "learning.detail" {
                    captured.record(method, params)
                    // node_detail skill shape (learning_mutations.py:112-118).
                    return [Self.responseFrame(id: id, result: [
                        "ok": true,
                        "kind": "skill",
                        "id": params["id"] as? String ?? "",
                        "label": params["id"] as? String ?? "",
                        "content": "---\nname: test-driven-development\n---\n\nTDD body.",
                    ])]
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

        let client = GatewayLearningClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let detail = try await client.nodeDetail(id: "test-driven-development")

        XCTAssertEqual(detail.id, "test-driven-development")
        XCTAssertEqual(detail.kind, "skill")
        XCTAssertEqual(detail.label, "test-driven-development")
        XCTAssertTrue(detail.content.contains("TDD body."))
        let (method, params) = await captured.last
        XCTAssertEqual(method, "learning.detail")
        XCTAssertEqual(params["id"] as? String, "test-driven-development")
    }

    func testNodeDetailMapsOkFalseToNodeNotFound() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "learning.detail" {
                    // node_detail failure shape (learning_mutations.py:91-92).
                    return [Self.responseFrame(id: id, result: [
                        "ok": false,
                        "message": "skill 'ghost' not found",
                    ])]
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

        let client = GatewayLearningClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.nodeDetail(id: "ghost")
            XCTFail("ok:false must throw nodeNotFound")
        } catch let error as GatewayLearningError {
            XCTAssertEqual(error, .nodeNotFound("skill 'ghost' not found"))
        }
    }

    func testRPCErrorMapsToRpcFailed() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "learning.frames" {
                    // learning.frames failure (methods_tools.py:1861).
                    return [Self.errorFrame(id: id, code: 5000, message: "learning.frames failed: boom")]
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

        let client = GatewayLearningClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.learningGraph(profile: nil)
            XCTFail("rpc error must throw rpcFailed")
        } catch let error as GatewayLearningError {
            XCTAssertEqual(error, .rpcFailed("learning.frames failed: boom (5000)"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testConnectsColdTransportOnFirstCall() async throws {
        // The learning pane's transport starts cold (no explicit connect);
        // the first learning RPC must open it (idempotent-connect pattern).
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "learning.frames" {
                    return [Self.responseFrame(id: id, result: [
                        "frames": [] as [[String: Any]],
                        "buckets": [] as [[String: Any]],
                        "summary": [] as [String],
                        "axis": ["start": "oldest", "end": "now"],
                        "count": 0,
                    ])]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        // NOTE: no connect() here — the client must do it.

        let client = GatewayLearningClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let graph = try await client.learningGraph(profile: nil)
        XCTAssertEqual(graph.summary.totalCount, 0)
        defer { Task { await transport.disconnect() } }
    }

    // MARK: 3. learning.edit / learning.delete (R10-T5)

    /// edit handler (methods_tools.py:1079-1082) → `edit_node`
    /// (learning_mutations.py:136-157): params `{id, content}` (both
    /// str-coerced); success `{ok: true, message: "updated …"}`.
    func testEditNodeSendsIdAndContentAndDecodesMessage() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "learning.edit" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "ok": true,
                        "message": "updated memory in MEMORY.md",
                    ])]
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

        let client = GatewayLearningClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let message = try await client.editNode(
            id: "memory:memory:3", content: "# chunk\n\nedited body")

        XCTAssertEqual(message, "updated memory in MEMORY.md")
        let (method, params) = await captured.last
        XCTAssertEqual(method, "learning.edit")
        XCTAssertEqual(params["id"] as? String, "memory:memory:3")
        XCTAssertEqual(params["content"] as? String, "# chunk\n\nedited body")
    }

    /// edit refusal (empty body, learning_mutations.py:152-153): the
    /// refusal is RESULT data `{ok: false, message}`, not an RPC error.
    func testEditNodeMapsEmptyBodyRefusalToMutationFailed() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "learning.edit" {
                    return [Self.responseFrame(id: id, result: [
                        "ok": false,
                        "message": "empty memory — use delete to remove it",
                    ])]
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

        let client = GatewayLearningClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.editNode(id: "memory:memory:3", content: "  ")
            XCTFail("ok:false must throw mutationFailed")
        } catch let error as GatewayLearningError {
            XCTAssertEqual(error, .mutationFailed("empty memory — use delete to remove it"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// delete handler (methods_tools.py:1079-1082) → `delete_node`
    /// (learning_mutations.py:108-131): params `{id}`; skill success
    /// message carries the restore recipe (archive, not erase).
    func testDeleteNodeSendsIdAndDecodesArchiveMessage() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "learning.delete" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "ok": true,
                        "message": "archived 'test-driven-development' — restore with: hermes curator restore test-driven-development",
                    ])]
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

        let client = GatewayLearningClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let message = try await client.deleteNode(id: "test-driven-development")

        XCTAssertEqual(
            message,
            "archived 'test-driven-development' — restore with: hermes curator restore test-driven-development")
        let (method, params) = await captured.last
        XCTAssertEqual(method, "learning.delete")
        XCTAssertEqual(params["id"] as? String, "test-driven-development")
    }

    /// delete refusal (pinned skill, learning_mutations.py:119-120): the
    /// pin message must reach the user verbatim — it names the remedy.
    func testDeleteNodeMapsPinnedRefusalToMutationFailed() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "learning.delete" {
                    return [Self.responseFrame(id: id, result: [
                        "ok": false,
                        "message": "'apple-product-factory' is pinned — unpin it first (hermes curator unpin apple-product-factory)",
                    ])]
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

        let client = GatewayLearningClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.deleteNode(id: "apple-product-factory")
            XCTFail("ok:false must throw mutationFailed")
        } catch let error as GatewayLearningError {
            XCTAssertEqual(
                error,
                .mutationFailed("'apple-product-factory' is pinned — unpin it first (hermes curator unpin apple-product-factory)"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
