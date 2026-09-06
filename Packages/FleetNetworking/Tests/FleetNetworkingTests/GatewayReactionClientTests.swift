import XCTest
import FleetCore
@testable import FleetNetworking

/// R10-T2 — `GatewayReactionClient` wire tests against the in-process
/// fixture server. Wire shapes verified against hermes-agent 0.21.0
/// (`~/.hermes/hermes-agent/tui_gateway/methods_session.py:1563-1614`):
/// params `{session_id, row_id? | newest_role, emoji|null}`; result
/// `{row_id: Int, reactions: [{emoji, author, at?}]}`; errors 4023/4024/
/// 4025/4040/4001/5007. Read-back: history rows carry
/// `display_metadata.reactions` (hermes_state.py:14153 → server.py:9936).
final class GatewayReactionClientTests: XCTestCase {

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

    // MARK: 1. params shape

    func testReactDurableSendsRowIDAndEmoji() async throws {
        let captured = ParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "message.react" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "row_id": 42,
                        "reactions": [["emoji": "👍", "author": "user", "at": 1_788_500_000.5]],
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

        let client = GatewayReactionClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let result = try await client.react(
            sessionID: "abc12345",
            target: .durable(rowID: "42"),
            emoji: "👍")

        // Wire params: session_id + row_id (number) + emoji. No author — the
        // server default "user" is exactly the local user reacting.
        let (method, params) = await captured.last
        XCTAssertEqual(method, "message.react")
        XCTAssertEqual(params["session_id"] as? String, "abc12345")
        XCTAssertEqual(params["row_id"] as? Int, 42)
        XCTAssertNil(params["newest_role"], "durable target must not send newest_role")
        XCTAssertEqual(params["emoji"] as? String, "👍")
        XCTAssertNil(params["author"], "author defaults server-side to 'user'")

        // Result decode: row_id + full post-write reaction list.
        XCTAssertEqual(result.rowID, "42")
        XCTAssertEqual(result.reactions.count, 1)
        XCTAssertEqual(result.reactions[0].emoji, "👍")
        XCTAssertEqual(result.reactions[0].author, "user")
        XCTAssertEqual(result.reactions[0].at, 1_788_500_000.5)
    }

    func testReactLiveSendsNewestRoleNotRowID() async throws {
        let captured = ParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "message.react" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "row_id": 7,
                        "reactions": [["emoji": "❤️", "author": "user"]],
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

        let client = GatewayReactionClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let result = try await client.react(
            sessionID: "abc12345",
            target: .newest(role: "assistant"),
            emoji: "❤️")

        let (_, params) = await captured.last
        XCTAssertEqual(params["newest_role"] as? String, "assistant")
        XCTAssertNil(params["row_id"], "live target must not send row_id")

        XCTAssertEqual(result.rowID, "7")
        XCTAssertEqual(result.reactions.first?.emoji, "❤️")
    }

    func testReactClearSendsEmojiNull() async throws {
        let captured = ParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "message.react" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "row_id": 42,
                        "reactions": [],
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

        let client = GatewayReactionClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let result = try await client.react(
            sessionID: "abc12345",
            target: .durable(rowID: "42"),
            emoji: nil)

        // emoji:null on the wire — an explicit JSON null, not an omitted key
        // (methods_session.py:1585 distinguishes None from absent).
        let (_, params) = await captured.last
        XCTAssertNil(params["emoji"] as? String)
        XCTAssertTrue(
            params.keys.contains("emoji"),
            "emoji must be present as JSON null, not omitted")

        XCTAssertEqual(result.reactions.count, 0, "cleared reaction list decodes empty")
    }

    // MARK: 2. error mapping

    func testReact4040MapsToMessageNotFound() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "message.react" {
                    return [Self.errorFrame(id: id, code: 4040, message: "message not found in this session")]
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

        let client = GatewayReactionClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.react(sessionID: "abc12345", target: .durable(rowID: "999"), emoji: "👍")
            XCTFail("expected messageNotFound")
        } catch let error as ReactionError {
            XCTAssertEqual(error, .messageNotFound("message not found in this session"))
        }
    }

    func testReact4023And4024MapToTypedErrors() async throws {
        for (code, expected) in [
            (4023, ReactionError.targetRequired("row_id or newest_role required")),
            (4024, ReactionError.emptyEmoji("emoji must be a non-empty string or null")),
        ] {
            let script = InProcessWebSocketServer.Script(
                onOpen: [Self.readyFrame()],
                onText: { frameText in
                    guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                    if method == "message.react" {
                        return [Self.errorFrame(id: id, code: code, message: expected.description)]
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

            let client = GatewayReactionClient(
                gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
            do {
                _ = try await client.react(sessionID: "abc12345", target: .durable(rowID: "1"), emoji: "👍")
                XCTFail("expected \(expected) for code \(code)")
            } catch let error as ReactionError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testReact4001MapsToSessionNotFoundRecoverableViaResume() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "message.react" {
                    return [Self.errorFrame(id: id, code: 4001, message: "session not found")]
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

        let client = GatewayReactionClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.react(sessionID: "reaped", target: .durable(rowID: "1"), emoji: "👍")
            XCTFail("expected sessionNotFound")
        } catch let error as ReactionError {
            // 4001 is session-reaped: the caller recovers via session.resume
            // (server.py:3696) — surfaced distinctly from a bad row.
            if case .sessionNotFound = error {} else {
                XCTFail("expected sessionNotFound, got \(error)")
            }
        }
    }

    // MARK: 3. malformed result

    func testReactMalformedResultThrowsTypedError() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "message.react" {
                    return [Self.responseFrame(id: id, result: ["reactions": []])]
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

        let client = GatewayReactionClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.react(sessionID: "abc12345", target: .durable(rowID: "1"), emoji: "👍")
            XCTFail("expected malformedResponse")
        } catch let error as ReactionError {
            if case .malformedResponse = error {} else {
                XCTFail("expected malformedResponse, got \(error)")
            }
        }
    }

    // MARK: 4. history read-back decode (display_metadata.reactions)

    func testHistoryDecodesReactionsFromDisplayMetadata() async throws {
        // @unchecked Sendable capture: the fixture dictionary is written
        // once before the script closure reads it.
        nonisolated(unsafe) let historyResult: [String: Any] = [
            "count": 2,
            "messages": [
                [
                    "role": "user",
                    "text": "hello",
                    "row_id": 11,
                    "display_metadata": [
                        "reactions": [["emoji": "👀", "author": "user", "at": 1.5]],
                    ],
                ] as [String: Any],
                [
                    "role": "assistant",
                    "text": "hi there",
                    "row_id": 12,
                ] as [String: Any],
            ],
        ]
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "session.history" {
                    return [Self.responseFrame(id: id, result: historyResult)]
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

        let history = GatewaySessionHistoryClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let decoded = try await history.fetchSessionHistory(sessionID: "abc12345")

        XCTAssertEqual(decoded.messages.count, 2)
        XCTAssertEqual(decoded.messages[0].rowID, "11")
        XCTAssertEqual(decoded.messages[0].reactions?.map(\.emoji), ["👀"],
                       "display_metadata.reactions must decode onto the message")
        XCTAssertEqual(decoded.messages[0].reactions?.first?.author, "user")
        XCTAssertEqual(decoded.messages[0].reactions?.first?.at, 1.5)
        // Rows without display_metadata carry no reactions.
        XCTAssertEqual(decoded.messages[1].rowID, "12")
        XCTAssertNil(decoded.messages[1].reactions)
    }

    func testHistoryIgnoresMalformedReactionMetadata() async throws {
        // @unchecked Sendable capture: same one-shot fixture discipline.
        nonisolated(unsafe) let historyResult: [String: Any] = [
            "count": 1,
            "messages": [
                [
                    "role": "user",
                    "text": "hello",
                    "row_id": 11,
                    "display_metadata": ["reactions": "junk-not-a-list"],
                ] as [String: Any],
            ],
        ]
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "session.history" {
                    return [Self.responseFrame(id: id, result: historyResult)]
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

        let history = GatewaySessionHistoryClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let decoded = try await history.fetchSessionHistory(sessionID: "abc12345")

        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertNil(decoded.messages[0].reactions,
                     "malformed display_metadata.reactions is treated as not disclosed — never fails the row")
    }

    // MARK: 5. fail-closed

    func testUnsupportedReactionProvidingThrowsHonestError() async throws {
        let seam = UnsupportedReactionProviding()
        do {
            _ = try await seam.react(sessionID: "s", target: .durable(rowID: "1"), emoji: "👍")
            XCTFail("expected fail-closed throw")
        } catch let error as ReactionError {
            XCTAssertEqual(error, .rpcFailed("gateway not configured"))
        }
    }
}
