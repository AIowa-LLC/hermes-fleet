import XCTest
import FleetCore
@testable import FleetNetworking

/// R10-T3 — `GatewayProjectsClient` wire tests against the in-process
/// fixture server. Wire shapes verified against hermes-agent 0.21.0
/// (`~/.hermes/hermes-agent/tui_gateway`):
/// - `projects.tree` (methods_config.py:117-153): result
///   `{projects[], active_id, scoped_session_ids}`; node shape from
///   project_tree.py `_project_node` (:540-571) + `_build_repos`
///   (:373-401); session rows from `_project_tree_row`
///   (server.py:15827-15866). `hydrate=False` overview: lane
///   `sessions` are EMPTY, previews ride `previewSessions`.
/// - `projects.project_sessions` (methods_config.py:157-191): params
///   `{project_id, profile?}`; result `{project: <hydrated node|null>}`;
///   error 5063 when project_id missing.
/// - `complete.path` (methods_complete.py:41-326): params
///   `{word, cwd?}`; result `{items: [{text, display, meta}]}` with
///   `text` already carrying the `@file:`/`@folder:` prefix.
final class GatewayProjectsClientTests: XCTestCase {

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

    private final class ParamCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _last: (String, [String: Any]) = ("", [:])
        var last: (String, [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            return _last
        }
        func record(_ method: String, _ params: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            _last = (method, params)
        }
    }

    /// The exact `projects.tree` overview shape 0.21.0 emits: hydrate=False
    /// so lane `sessions` are empty, previews ride `previewSessions`, the
    /// "No Project" tier leads with `isNoProject` and `path: null`.
    private static func treeResult() -> [String: Any] {
        [
            "projects": [
                [
                    "id": "__no_project__",
                    "label": "No Project",
                    "path": NSNull(),
                    "color": NSNull(),
                    "icon": NSNull(),
                    "isAuto": false,
                    "isNoProject": true,
                    "sessionCount": 1,
                    "lastActive": 1_788_540_000.0,
                    "totalTokens": 500,
                    "totalCostUsd": 0.01,
                    "repos": [
                        [
                            "id": "__no_project__",
                            "label": "No Project",
                            "path": NSNull(),
                            "sessionCount": 1,
                            "groups": [
                                [
                                    "id": "__no_project__",
                                    "label": "No Project",
                                    "path": NSNull(),
                                    "isMain": false,
                                    "isKanban": false,
                                    "sessions": [],
                                ] as [String: Any],
                            ],
                        ] as [String: Any],
                    ],
                    "previewSessions": [
                        [
                            "id": "s9",
                            "title": "Loose scratch chat",
                            "preview": "quick question",
                            "started_at": 1_788_530_000,
                            "last_active": 1_788_540_000,
                            "cwd": "/tmp",
                            "git_branch": "",
                            "message_count": 2,
                            "input_tokens": 200,
                            "output_tokens": 300,
                            "actual_cost_usd": 0.01,
                            "model": "glm-5.3",
                            "profile": "default",
                        ] as [String: Any],
                    ],
                ] as [String: Any],
                [
                    "id": "proj-fleet",
                    "label": "Fleet iOS",
                    "path": "/Users/dev/code/fleet-ios",
                    "color": "#22d3ee",
                    "icon": NSNull(),
                    "isAuto": false,
                    "isNoProject": false,
                    "sessionCount": 3,
                    "lastActive": 1_788_550_000.0,
                    "totalTokens": 1_500,
                    "totalCostUsd": 0.05,
                    "repos": [
                        [
                            "id": "/Users/dev/code/fleet-ios",
                            "label": "fleet-ios",
                            "path": "/Users/dev/code/fleet-ios",
                            "sessionCount": 3,
                            "groups": [
                                [
                                    "id": "/Users/dev/code/fleet-ios::branch::r10-t3",
                                    "label": "r10-t3",
                                    "path": "/Users/dev/code/fleet-ios",
                                    "isMain": false,
                                    "isKanban": false,
                                    "sessions": [],
                                ] as [String: Any],
                                [
                                    "id": "/Users/dev/code/fleet-ios::branch::main",
                                    "label": "main",
                                    "path": "/Users/dev/code/fleet-ios",
                                    "isMain": true,
                                    "isKanban": false,
                                    "sessions": [],
                                ] as [String: Any],
                            ],
                        ] as [String: Any],
                    ],
                    "previewSessions": [
                        [
                            "id": "s1",
                            "title": "WS transport fix",
                            "preview": "correlate rpc ids",
                            "started_at": 1_788_540_000,
                            "last_active": 1_788_550_000,
                            "cwd": "/Users/dev/code/fleet-ios",
                            "git_branch": "r10-t3",
                            "message_count": 12,
                            "input_tokens": 600,
                            "output_tokens": 900,
                            "actual_cost_usd": 0.04,
                            "estimated_cost_usd": 0.05,
                            "model": "glm-5.3",
                            "profile": "default",
                        ] as [String: Any],
                        [
                            "id": "s2",
                            "title": "Reactions round 2",
                            "preview": "promote newest_role",
                            "started_at": 1_788_500_000,
                            "last_active": 1_788_510_000,
                            "cwd": "/Users/dev/code/fleet-ios",
                            "git_branch": "main",
                            "message_count": 8,
                            "input_tokens": 100,
                            "output_tokens": 200,
                            "actual_cost_usd": 0.01,
                            "model": "glm-5.3",
                            "profile": "default",
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ],
            "active_id": "proj-fleet",
            "scoped_session_ids": ["s9", "s1", "s2", "s3"],
        ]
    }

    /// The `projects.project_sessions` hydrated shape: same node structure,
    /// `hydrate=True` so lanes CARRY session rows (and previewSessions is
    /// empty — preview_limit=0 on the drill-in, methods_config.py:179).
    private static func drillResult() -> [String: Any] {
        [
            "project": [
                "id": "proj-fleet",
                "label": "Fleet iOS",
                "path": "/Users/dev/code/fleet-ios",
                "color": NSNull(),
                "icon": NSNull(),
                "isAuto": false,
                "isNoProject": false,
                "sessionCount": 1,
                "lastActive": 1_788_550_000.0,
                "totalTokens": 1_500,
                "totalCostUsd": 0.05,
                "repos": [
                    [
                        "id": "/Users/dev/code/fleet-ios",
                        "label": "fleet-ios",
                        "path": "/Users/dev/code/fleet-ios",
                        "sessionCount": 1,
                        "groups": [
                            [
                                "id": "/Users/dev/code/fleet-ios::branch::r10-t3",
                                "label": "r10-t3",
                                "path": "/Users/dev/code/fleet-ios",
                                "isMain": false,
                                "isKanban": false,
                                "sessions": [
                                    [
                                        "id": "s1",
                                        "title": "WS transport fix",
                                        "preview": "correlate rpc ids",
                                        "started_at": 1_788_540_000,
                                        "last_active": 1_788_550_000,
                                        "cwd": "/Users/dev/code/fleet-ios",
                                        "git_branch": "r10-t3",
                                        "message_count": 12,
                                        "input_tokens": 600,
                                        "output_tokens": 900,
                                        "actual_cost_usd": 0.04,
                                        "model": "glm-5.3",
                                        "profile": "default",
                                    ] as [String: Any],
                                ],
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ],
                "previewSessions": [],
            ] as [String: Any],
        ]
    }

    // MARK: 1. projects.tree

    func testTreeDecodesProjectsActiveIDAndScopedSessions() async throws {
        let captured = ParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "projects.tree" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: Self.treeResult())]
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

        let client = GatewayProjectsClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let tree = try await client.projectTree(profile: "default")

        // Params: optional profile scope only (preview_limit/session_limit
        // stay server-default — 3 previews / 2000 sessions are the 0.21
        // overview defaults, methods_config.py:136-139).
        let (method, params) = await captured.last
        XCTAssertEqual(method, "projects.tree")
        XCTAssertEqual(params["profile"] as? String, "default")

        // Envelope.
        XCTAssertEqual(tree.activeID, "proj-fleet")
        XCTAssertEqual(tree.scopedSessionIDs, ["s9", "s1", "s2", "s3"])
        XCTAssertEqual(tree.projects.count, 2)

        // Explicit project node.
        let fleet = tree.projects[1]
        XCTAssertEqual(fleet.id, "proj-fleet")
        XCTAssertEqual(fleet.label, "Fleet iOS")
        XCTAssertEqual(fleet.path, "/Users/dev/code/fleet-ios")
        XCTAssertEqual(fleet.color, "#22d3ee")
        XCTAssertFalse(fleet.isAuto)
        XCTAssertFalse(fleet.isNoProject)
        XCTAssertEqual(fleet.sessionCount, 3)
        XCTAssertEqual(fleet.lastActive, 1_788_550_000.0, accuracy: 0.001)
        XCTAssertEqual(fleet.totalTokens, 1_500)
        XCTAssertEqual(fleet.totalCostUsd, 0.05, accuracy: 0.0001)
        XCTAssertEqual(fleet.repos.count, 1)
        let repo = fleet.repos[0]
        XCTAssertEqual(repo.id, "/Users/dev/code/fleet-ios")
        XCTAssertEqual(repo.label, "fleet-ios")
        XCTAssertEqual(repo.sessionCount, 3)
        XCTAssertEqual(repo.groups.map(\.label), ["r10-t3", "main"], "lane sort order is wire truth")
        XCTAssertTrue(repo.groups[1].isMain)
        XCTAssertEqual(fleet.previewSessions.count, 2)
        XCTAssertEqual(fleet.previewSessions[0].id, "s1")
        XCTAssertEqual(fleet.previewSessions[0].title, "WS transport fix")
        XCTAssertEqual(fleet.previewSessions[0].gitBranch, "r10-t3")
        XCTAssertEqual(fleet.previewSessions[0].lastActive, 1_788_550_000.0, accuracy: 0.001)
        XCTAssertEqual(fleet.previewSessions[0].actualCostUsd ?? 0, 0.04, accuracy: 0.0001)
        XCTAssertEqual(fleet.previewSessions[0].profile, "default")

        // "No Project" tier: path null, isNoProject true, one preview row.
        let noProject = tree.projects[0]
        XCTAssertTrue(noProject.isNoProject)
        XCTAssertNil(noProject.path)
        XCTAssertEqual(noProject.previewSessions.first?.id, "s9")
    }

    func testTreeEmptyProfileDBDecodesBlankHonestly() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "projects.tree" {
                    // `_profile_db(params)` returning None
                    // (methods_config.py:128-131).
                    return [Self.responseFrame(id: id, result: [
                        "projects": [] as [Any],
                        "active_id": NSNull(),
                        "scoped_session_ids": [] as [Any],
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

        let client = GatewayProjectsClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let tree = try await client.projectTree(profile: nil)

        XCTAssertTrue(tree.projects.isEmpty, "empty profile DB is an honest blank, not an error")
        XCTAssertNil(tree.activeID)
        XCTAssertTrue(tree.scopedSessionIDs.isEmpty)
    }

    func testTreeOmitsProfileParamWhenScopeNil() async throws {
        let captured = ParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "projects.tree" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "projects": [] as [Any],
                        "active_id": NSNull(),
                        "scoped_session_ids": [] as [Any],
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

        let client = GatewayProjectsClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        _ = try await client.projectTree(profile: nil)

        let (_, params) = await captured.last
        XCTAssertNil(params["profile"], "nil scope must omit the profile key entirely")
    }

    // MARK: 2. projects.project_sessions

    func testProjectSessionsSendsProjectIDAndDecodesHydratedLanes() async throws {
        let captured = ParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "projects.project_sessions" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: Self.drillResult())]
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

        let client = GatewayProjectsClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let project = try await client.projectSessions(projectID: "proj-fleet", profile: "default")

        let (method, params) = await captured.last
        XCTAssertEqual(method, "projects.project_sessions")
        XCTAssertEqual(params["project_id"] as? String, "proj-fleet")
        XCTAssertEqual(params["profile"] as? String, "default")

        let hydrated = try XCTUnwrap(project, "the fixture project must decode")
        XCTAssertEqual(hydrated.id, "proj-fleet")
        XCTAssertEqual(hydrated.repos.count, 1)
        let lane = hydrated.repos[0].groups[0]
        XCTAssertEqual(lane.id, "/Users/dev/code/fleet-ios::branch::r10-t3")
        XCTAssertEqual(lane.sessions.count, 1, "hydrate=True lanes carry session rows")
        XCTAssertEqual(lane.sessions[0].id, "s1")
        XCTAssertEqual(lane.sessions[0].profile, "default")
        XCTAssertTrue(hydrated.previewSessions.isEmpty, "drill-in preview_limit=0 → no previewSessions")
    }

    func testProjectSessionsNullProjectDecodesNil() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "projects.project_sessions" {
                    // Empty profile DB / unknown project_id
                    // (methods_config.py:171, :190).
                    return [Self.responseFrame(id: id, result: ["project": NSNull()])]
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

        let client = GatewayProjectsClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let project = try await client.projectSessions(projectID: "missing", profile: nil)
        XCTAssertNil(project, "project:null decodes as nil — the UI shows its empty state")
    }

    func testProjectSessionsEmptyProjectIDFailsClosedBeforeRPC() async throws {
        let server = try InProcessWebSocketServer(script: InProcessWebSocketServer.Script(onOpen: [Self.readyFrame()], onText: { _ in [] }))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayProjectsClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.projectSessions(projectID: "", profile: nil)
            XCTFail("expected projectRequired (server 5063 mirrored client-side)")
        } catch let error as GatewayProjectsError {
            XCTAssertEqual(
                error, .projectRequired("project_id required"),
                "empty project_id fails before the round trip (methods_config.py:163-165)")
        }
    }

    // MARK: 3. complete.path

    func testCompletePathSendsWordAndDecodesItems() async throws {
        let captured = ParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "complete.path" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "items": [
                            ["text": "@folder:Packages/FleetUI/", "display": "FleetUI/", "meta": "dir"],
                            ["text": "@file:Packages/Module.swift", "display": "Module.swift", "meta": "Packages"],
                        ],
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

        let client = GatewayProjectsClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let items = try await client.completePath(word: "@file:Packages/Fle", cwd: "/Users/dev/code/fleet-ios")

        // Params: {word, cwd?} — exactly what methods_complete.py:42-44 reads.
        let (method, params) = await captured.last
        XCTAssertEqual(method, "complete.path")
        XCTAssertEqual(params["word"] as? String, "@file:Packages/Fle")
        XCTAssertEqual(params["cwd"] as? String, "/Users/dev/code/fleet-ios")

        // Items carry the pre-composed @-prefixed text (methods_complete.py:294-302).
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].text, "@folder:Packages/FleetUI/")
        XCTAssertEqual(items[0].display, "FleetUI/")
        XCTAssertEqual(items[0].meta, "dir")
        XCTAssertEqual(items[1].text, "@file:Packages/Module.swift")
    }

    func testCompletePathEmptyWordShortCircuits() async throws {
        let server = try InProcessWebSocketServer(script: InProcessWebSocketServer.Script(onOpen: [Self.readyFrame()], onText: { _ in [] }))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayProjectsClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let items = try await client.completePath(word: "", cwd: nil)
        XCTAssertTrue(items.isEmpty, "empty word is the server's own {items: []} fast path (methods_complete.py:42-44) — no RPC needed")
    }

    // MARK: 4. malformed + errors

    func testTreeMalformedResultThrowsTypedError() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "projects.tree" {
                    return [Self.responseFrame(id: id, result: ["projects": "junk"])]
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

        let client = GatewayProjectsClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.projectTree(profile: nil)
            XCTFail("expected malformedResponse")
        } catch let error as GatewayProjectsError {
            if case .malformedResponse = error {} else {
                XCTFail("expected malformedResponse, got \(error)")
            }
        }
    }

    func testTreeRPCErrorMapsToTypedError() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "projects.tree" {
                    // 5061: projects surface runtime failure (methods_config.py:151).
                    return [Self.errorFrame(id: id, code: 5061, message: "profile db locked")]
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

        let client = GatewayProjectsClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.projectTree(profile: nil)
            XCTFail("expected rpcFailed")
        } catch let error as GatewayProjectsError {
            XCTAssertEqual(error, .rpcFailed("profile db locked (5061)"))
        }
    }
}
