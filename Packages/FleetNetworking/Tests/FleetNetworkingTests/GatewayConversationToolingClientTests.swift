import XCTest
import FleetCore
@testable import FleetNetworking

/// R9-T2/T3/T4: `GatewayConversationToolingClient` — model.options,
/// session.usage, session.context_breakdown, session.steer, session.title,
/// session.branch over the conversation transport, against in-process
/// fixture servers. Wire shapes verified against hermes-agent 0.21.0:
/// - `model.options` (methods_complete.py:469 → inventory.py:328): result
///   `{providers: [...], model, provider}`; provider rows carry `slug`,
///   `name`, `is_current`, `authenticated`, `models: [...]`.
/// - `session.usage` (methods_session.py:1828 → server.py:7512): the
///   `_get_usage` shape with OPTIONAL `context_used/context_max/
///   context_percent` (server.py:7542 — present only when the compressor
///   reports a real occupancy).
/// - streamed `session.usage` event (server.py:13133): params
///   `{type, session_id, payload: {usage: {...}}}`.
/// - `session.context_breakdown` (methods_session.py:1852 →
///   agent/context_breakdown.py:163): `{categories: [{id, label, tokens,
///   color}], context_max, context_percent, context_used, estimated_total,
///   model}`.
/// - `session.steer` (methods_session.py:3750): `{session_id, text}` →
///   `{status: "queued"|"rejected", text}`.
/// - `session.title` (methods_session.py:1427): `{session_id, title}` →
///   `{pending, title}`.
/// - `session.branch` (methods_session.py:3282): `{session_id, name?}` →
///   `{session_id, stored_session_id, title, parent, message_count,
///   messages, info}`.
final class GatewayConversationToolingClientTests: XCTestCase {

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

    private static func eventFrame(
        type: String, sessionID: String, payload: [String: Any]? = nil, seq: Int? = nil
    ) -> String {
        var params: [String: Any] = ["type": type, "session_id": sessionID]
        if let seq { params["seq"] = seq }
        if let payload { params["payload"] = payload }
        return frame(["jsonrpc": "2.0", "method": "event", "params": params])
    }

    /// The captured model.options shape (inventory.py:328 + picker_hints).
    private static func modelOptionsResult() -> [String: Any] {
        [
            "providers": [
                [
                    "slug": "nous",
                    "name": "Nous Research",
                    "is_current": true,
                    "authenticated": true,
                    "auth_type": "api_key",
                    "models": ["hermes", "hermes-mini"],
                ],
                [
                    "slug": "openrouter",
                    "name": "OpenRouter",
                    "is_current": false,
                    "authenticated": true,
                    "auth_type": "api_key",
                    "models": ["openai/gpt-5", "anthropic/claude-sonnet-4"],
                ],
            ],
            "model": "hermes",
            "provider": "nous",
        ]
    }

    // MARK: 1. model.options

    func testModelChoicesFlattensProviderRowsAndMarksCurrent() async throws {
        let captured = ToolingParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "model.options" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: Self.modelOptionsResult())]
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

        let client = GatewayConversationToolingClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let choices = try await client.modelChoices(sessionID: "abc12345")

        XCTAssertEqual(choices.count, 4, "every model of every provider row")
        // Current: nous/hermes (is_current + payload model match).
        let hermes = choices.first { $0.model == "hermes" }
        XCTAssertNotNil(hermes)
        XCTAssertEqual(hermes?.provider, "nous")
        XCTAssertEqual(hermes?.providerName, "Nous Research")
        XCTAssertTrue(hermes?.isCurrent ?? false)
        // Non-current sibling.
        let mini = choices.first { $0.model == "hermes-mini" }
        XCTAssertNotNil(mini)
        XCTAssertFalse(mini?.isCurrent ?? true)
        // Other provider, namespaced id.
        let gpt = choices.first { $0.model == "openai/gpt-5" }
        XCTAssertNotNil(gpt)
        XCTAssertEqual(gpt?.provider, "openrouter")
        XCTAssertFalse(gpt?.isCurrent ?? true)
        XCTAssertEqual(gpt?.id, "openrouter/openai/gpt-5")

        // The open session id travels on the RPC (layered agent state).
        let (method, params) = await captured.last
        XCTAssertEqual(method, "model.options")
        XCTAssertEqual(params["session_id"] as? String, "abc12345")
    }

    func testModelChoicesSessionIDOptionalOmitsParam() async throws {
        let captured = ToolingParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "model.options" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: Self.modelOptionsResult())]
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

        let client = GatewayConversationToolingClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        _ = try await client.modelChoices(sessionID: nil)

        let (_, params) = await captured.last
        XCTAssertNil(params["session_id"], "nil session id must omit the param entirely")
    }

    // MARK: 2. session.usage RPC

    func testUsageDecodesGetUsageShapeWithOptionalContext() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "session.usage" {
                    return [Self.responseFrame(id: id, result: [
                        "model": "hermes",
                        "input": 12_000,
                        "output": 3_400,
                        "reasoning": 900,
                        "prompt": 12_000,
                        "completion": 3_400,
                        "total": 16_300,
                        "calls": 7,
                        "context_used": 45_000,
                        "context_max": 120_000,
                        "context_percent": 38,
                        "compressions": 1,
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

        let client = GatewayConversationToolingClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let usage = try await client.usage(sessionID: "abc12345")
        XCTAssertEqual(usage.model, "hermes")
        XCTAssertEqual(usage.input, 12_000)
        XCTAssertEqual(usage.output, 3_400)
        XCTAssertEqual(usage.total, 16_300)
        XCTAssertEqual(usage.calls, 7)
        XCTAssertEqual(usage.contextUsed, 45_000)
        XCTAssertEqual(usage.contextMax, 120_000)
        XCTAssertEqual(usage.contextPercent, 38)
        XCTAssertTrue(usage.hasContextGauge)
    }

    func testUsageWithoutContextFieldsIsHonestUnknown() async throws {
        // server.py:7542: an engine that reports no current-window occupancy
        // emits NO context fields — the meter must read unknown, not 0%.
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "session.usage" {
                    return [Self.responseFrame(id: id, result: [
                        "model": "hermes",
                        "input": 10, "output": 5, "total": 15, "calls": 1,
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

        let client = GatewayConversationToolingClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let usage = try await client.usage(sessionID: "abc12345")
        XCTAssertNil(usage.contextUsed)
        XCTAssertNil(usage.contextMax)
        XCTAssertNil(usage.contextPercent)
        XCTAssertFalse(usage.hasContextGauge, "no gauge — unknown, never 0%")
    }

    // MARK: 3. streamed session.usage event

    func testSessionUsageEventDecodesOnConversationStream() async throws {
        let usageFrame = Self.eventFrame(
            type: "session.usage", sessionID: "abc12345",
            payload: ["usage": [
                "model": "hermes", "input": 100, "output": 20, "total": 120,
                "calls": 2, "context_used": 90_000, "context_max": 120_000,
                "context_percent": 75,
            ]])
        let script = InProcessWebSocketServer.Script(onOpen: [Self.readyFrame(), usageFrame])
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let stream = client.events
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        try await withTimeout(.seconds(3)) {
            for await event in stream {
                if case .usageUpdate(let sid, let snapshot, _) = event {
                    XCTAssertEqual(sid, "abc12345")
                    XCTAssertEqual(snapshot.contextPercent, 75)
                    XCTAssertEqual(snapshot.contextMax, 120_000)
                    XCTAssertTrue(snapshot.hasContextGauge)
                    return
                }
            }
            XCTFail("session.usage event never surfaced on the conversation stream")
        }
    }

    // MARK: 4. context breakdown

    func testContextBreakdownDecodesCategories() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "session.context_breakdown" {
                    return [Self.responseFrame(id: id, result: [
                        "categories": [
                            ["id": "system_prompt", "label": "System prompt", "tokens": 5_200, "color": "#888"],
                            ["id": "conversation", "label": "Conversation", "tokens": 38_000, "color": "#0af"],
                        ],
                        "context_max": 120_000,
                        "context_percent": 41,
                        "context_used": 49_200,
                        "estimated_total": 50_000,
                        "model": "hermes",
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

        let client = GatewayConversationToolingClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let breakdown = try await client.contextBreakdown(sessionID: "abc12345")
        XCTAssertEqual(breakdown.categories.count, 2)
        XCTAssertEqual(breakdown.categories.first?.id, "system_prompt")
        XCTAssertEqual(breakdown.categories.first?.label, "System prompt")
        XCTAssertEqual(breakdown.categories.first?.tokens, 5_200)
        XCTAssertEqual(breakdown.contextMax, 120_000)
        XCTAssertEqual(breakdown.contextPercent, 41)
        XCTAssertEqual(breakdown.model, "hermes")
    }

    // MARK: 5. steer / title / branch

    func testSteerSendsTextAndDecodesQueued() async throws {
        let captured = ToolingParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "session.steer" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: ["status": "queued", "text": params["text"] ?? ""])]
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

        let client = GatewayConversationToolingClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let queued = try await client.steer(sessionID: "abc12345", text: "use fewer tools")
        XCTAssertTrue(queued)

        let (method, params) = await captured.last
        XCTAssertEqual(method, "session.steer")
        XCTAssertEqual(params["session_id"] as? String, "abc12345")
        XCTAssertEqual(params["text"] as? String, "use fewer tools")
        XCTAssertEqual(params.count, 2, "exactly the two documented params")
    }

    func testSteerRejectedSurfacesFalseNotError() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "session.steer" {
                    return [Self.responseFrame(id: id, result: ["status": "rejected", "text": ""])]
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

        let client = GatewayConversationToolingClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let queued = try await client.steer(sessionID: "abc12345", text: "nudge")
        XCTAssertFalse(queued, "rejected steer is a surfaced false, not a thrown error")
    }

    func testRenameSendsTitleAndReturnsResolvedTitle() async throws {
        let captured = ToolingParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "session.title" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: ["pending": false, "title": params["title"] ?? ""])]
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

        let client = GatewayConversationToolingClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let title = try await client.renameSession(sessionID: "abc12345", title: "Fleet review")
        XCTAssertEqual(title, "Fleet review")

        let (method, params) = await captured.last
        XCTAssertEqual(method, "session.title")
        XCTAssertEqual(params["session_id"] as? String, "abc12345")
        XCTAssertEqual(params["title"] as? String, "Fleet review")
    }

    func testBranchReturnsNewSessionPayload() async throws {
        let captured = ToolingParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "session.branch" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "session_id": "deadbeef",
                        "stored_session_id": "s-branch-1",
                        "title": "Fleet review (branch)",
                        "parent": "s-old",
                        "message_count": 4,
                        "messages": [
                            // server.py:9849 _history_to_messages projection:
                            // `{role, text, timestamp}` (NOT raw `content`).
                            ["role": "user", "text": "hi", "timestamp": 1.0],
                            ["role": "assistant", "text": "hello", "timestamp": 2.0],
                        ],
                        "info": ["model": "hermes", "provider": "nous"],
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

        let client = GatewayConversationToolingClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let branch = try await client.branchSession(sessionID: "abc12345", name: "side quest")
        XCTAssertEqual(branch.sessionID, "deadbeef")
        XCTAssertEqual(branch.storedSessionID, "s-branch-1")
        XCTAssertEqual(branch.messages.count, 2)
        XCTAssertEqual(branch.model, "hermes")

        let (method, params) = await captured.last
        XCTAssertEqual(method, "session.branch")
        XCTAssertEqual(params["session_id"] as? String, "abc12345")
        XCTAssertEqual(params["name"] as? String, "side quest")
    }

    // MARK: 6. error classification

    func testToolingRPCErrorMapsOntoConversationVocabulary() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "model.options" {
                    return [Self.frame([
                        "jsonrpc": "2.0", "id": id,
                        "error": ["code": 5033, "message": "inventory failed"],
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

        let client = GatewayConversationToolingClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.modelChoices(sessionID: nil)
            XCTFail("expected rpcFailed")
        } catch let error as ConversationError {
            guard case .rpcFailed(let detail) = error else {
                return XCTFail("expected rpcFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("5033"), "code preserved: \(detail)")
        }
    }
}

/// Fails the async block after `duration` (test-level watchdog).
private func withTimeout<T: Sendable>(
    _ duration: Duration, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError()
        }
        guard let first = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return first
    }
}

private struct TimeoutError: Error {}

/// Records the method + params of the last captured RPC (thread-safe).
final class ToolingParamCapture: @unchecked Sendable {
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
