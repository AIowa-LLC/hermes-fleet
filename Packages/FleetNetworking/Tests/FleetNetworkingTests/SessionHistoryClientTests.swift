import XCTest
import FleetCore
import FleetNetworking

/// M4 session READ path client: `GatewaySessionHistoryClient`
/// (session.history / session.status) against in-process fixture servers —
/// no live Hermes gateway is touched.
///
/// The last test is the session-safety gate (spec §36 "Session safety tests:
/// ensure read-only screens do not accidentally issue mutating calls"): the
/// full read path must send ONLY read-only methods — never session.create /
/// session.resume / session.interrupt / session.close / session.delete /
/// prompt.submit or any other mutating call.
final class SessionHistoryClientTests: XCTestCase {

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

    /// `{"jsonrpc":"2.0","id":<id>,"result":{...}}` with an object body.
    private static func responseFrame(id: String, result: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        return String(data: data, encoding: .utf8)!
    }

    /// JSON-RPC error frame with the given code (e.g. 4001 session-not-found).
    private static func errorFrame(id: String, code: Int, message: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: session.history

    func testFetchSessionHistoryDecodesMessages() async throws {
        let historyJSON = """
        [
          {"role":"user","text":"hi","timestamp":1700000000.0,"row_id":1},
          {"role":"assistant","text":"hello!","timestamp":1700000002.0,"row_id":2},
          {"role":"tool","name":"web_search","context":"search(\\"x\\")"},
          {"role":"assistant","text":"","reasoning":"thinking deep","row_id":4},
          {"role":"developer","text":"ignored content"},
          {"role":"system","text":"","timestamp":0.0}
        ]
        """
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                switch method {
                case "session.history":
                    return [Self.responseFrame(id: id, result: [
                        "count": 6, "messages": try! JSONSerialization.jsonObject(
                            with: Data(historyJSON.utf8)) as! [Any]])
                    ]
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

        let client = GatewaySessionHistoryClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let history = try await client.fetchSessionHistory(sessionID: "sess-001")

        XCTAssertEqual(history.sessionID, "sess-001")
        XCTAssertEqual(history.count, 6)
        XCTAssertEqual(history.messages.count, 5, "only the empty system row is dropped; unknown-role content is preserved (tolerant decode)")

        XCTAssertEqual(history.messages[0].role, .user)
        XCTAssertEqual(history.messages[0].text, "hi")
        XCTAssertEqual(history.messages[0].rowID, "1", "row_id becomes a stable string id")

        XCTAssertEqual(history.messages[1].role, .assistant)
        XCTAssertEqual(history.messages[1].text, "hello!")

        XCTAssertEqual(history.messages[2].role, .tool)
        XCTAssertEqual(history.messages[2].toolName, "web_search")

        // Reasoning-only assistant turn kept (server.py #44022).
        XCTAssertEqual(history.messages[3].role, .assistant)
        XCTAssertEqual(history.messages[3].reasoning, "thinking deep")
        XCTAssertEqual(history.messages[3].text, "")

        // Unknown role (e.g. a newer gateway's "developer") is preserved with
        // its content as .unknown — never dropped, never fatal (spec §5.5).
        XCTAssertEqual(history.messages[4].role, .unknown)
        XCTAssertEqual(history.messages[4].text, "ignored content")
    }

    func testFetchSessionHistorySendsSessionIDParam() async throws {
        let captured = SessionParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "session.history", let data = frame.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    captured.record(obj["params"] as? [String: Any] ?? [:])
                }
                return [Self.responseFrame(id: id, result: ["count": 0, "messages": []])]
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewaySessionHistoryClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        _ = try await client.fetchSessionHistory(sessionID: "sess-abc")
        XCTAssertEqual(captured.sessionID, "sess-abc")
    }

    func testFetchSessionHistorySessionNotFound() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "session.history" {
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

        let client = GatewaySessionHistoryClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.fetchSessionHistory(sessionID: "stale")
            XCTFail("expected sessionNotFound")
        } catch let error as SessionHistoryError {
            XCTAssertEqual(error, .sessionNotFound("session not found"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFetchSessionHistoryNotConnectedThrows() async {
        let transport = makeTransport(serverPort: 1) // never connected
        let client = GatewaySessionHistoryClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.fetchSessionHistory(sessionID: "s")
            XCTFail("expected notConnected")
        } catch let error as SessionHistoryError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: session.status

    func testFetchSessionStatusDecodesOutput() async throws {
        let output = """
        Hermes TUI Status

        Session ID: sess-abc
        Path: /Users/t/.hermes
        Title: Research plans
        Model: deepseek-v4-flash (nous)
        Created: 2026-08-29 12:00
        Last Activity: 2026-08-29 12:30
        Tokens: 12,345
        Agent Running: Yes
        """
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "session.status" {
                    return [Self.responseFrame(id: id, result: ["output": output])]
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

        let client = GatewaySessionHistoryClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let status = try await client.fetchSessionStatus(sessionID: "sess-abc")
        XCTAssertEqual(status.sessionID, "sess-abc")
        XCTAssertEqual(status.model, "deepseek-v4-flash")
        XCTAssertEqual(status.provider, "nous")
        XCTAssertEqual(status.title, "Research plans")
        XCTAssertEqual(status.agentRunning, true)
        XCTAssertEqual(status.rawOutput, output)
    }

    func testFetchSessionStatusFallbackSessionIDFromCaller() async throws {
        // A minimal status block without a "Session ID:" line still resolves
        // the sessionID from the caller's request (best-effort).
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "session.status" {
                    return [Self.responseFrame(id: id, result: ["output": "Hermes TUI Status\nAgent Running: No"])]
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

        let client = GatewaySessionHistoryClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let status = try await client.fetchSessionStatus(sessionID: "sess-from-caller")
        XCTAssertEqual(status.sessionID, "sess-from-caller")
        XCTAssertEqual(status.agentRunning, false)
    }

    func testFetchSessionStatusMalformedThrows() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "session.status" {
                    return [Self.responseFrame(id: id, result: ["nope": true])]
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

        let client = GatewaySessionHistoryClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.fetchSessionStatus(sessionID: "s")
            XCTFail("expected malformedPayload")
        } catch let error as SessionHistoryError {
            guard case .malformedPayload = error else {
                return XCTFail("expected malformedPayload, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: session safety — the §5.4 / §36 read-only-never-mutates gate

    /// Runs the ENTIRE read path (history + status + the M2 roster reads)
    /// against a server that records EVERY inbound method, then asserts the
    /// client never issued a mutating call. This is the session-safety test
    /// the acceptance criteria name ("read-only never mutates").
    func testReadPathNeverIssuesMutatingCalls() async throws {
        let recorded = RecordedMethods()

        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                recorded.record(method)
                switch method {
                case "session.history":
                    return [Self.responseFrame(id: id, result: ["count": 1, "messages": [
                        ["role": "user", "text": "hi"]
                    ]])]
                case "session.status":
                    return [Self.responseFrame(id: id, result: ["output": "Hermes TUI Status\nAgent Running: No"])]
                case "session.list":
                    return [Self.responseFrame(id: id, result: ["sessions": [
                        ["id": "s1", "title": "t", "preview": "", "started_at": 1, "message_count": 1, "source": "tui"]
                    ]])]
                case "profiles.list":
                    return [Self.responseFrame(id: id, result: ["profiles": [
                        ["name": "default", "path": "/home/t", "is_default": true]
                    ]])]
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

        let gatewayID = GatewayID(rawValue: "workstation")
        let historyClient = GatewaySessionHistoryClient(gatewayID: gatewayID, transport: transport)
        let rosterClient = GatewayRosterClient(gatewayID: gatewayID, transport: transport)
        let route = Route(gatewayID: gatewayID, profileSlug: ProfileSlug(rawValue: "default"))

        // Exercise the full read surface exactly as a read-only screen would.
        _ = try await historyClient.fetchSessionHistory(sessionID: "s1")
        _ = try await historyClient.fetchSessionStatus(sessionID: "s1")
        _ = try await rosterClient.fetchProfiles()
        _ = try await rosterClient.fetchSessions(for: route, limit: 50)

        // The only methods a read screen may send. This is the safety contract:
        // NO session.create / resume / interrupt / close / delete / undo /
        // activate / branch / compress / save, NO prompt.submit, NO privileged
        // surface.
        let readOnlyWhitelist: Set<String> = [
            "session.history", "session.status", "session.list", "profiles.list",
        ]
        let allowed = recorded.all
        XCTAssertFalse(allowed.isEmpty, "read path should have issued requests")
        let offending = allowed.filter { !readOnlyWhitelist.contains($0) }
        XCTAssertTrue(
            offending.isEmpty,
            "read path issued mutating/non-read calls: \(offending.sorted())"
        )
        XCTAssertEqual(
            Set(allowed), readOnlyWhitelist,
            "read path should have used exactly the read-only methods"
        )
    }

    // MARK: M9 — session-key traversal guards fail closed

    func testFetchSessionHistoryRejectsUnsafeSessionKeyBeforeTransport() async {
        let client = GatewaySessionHistoryClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: makeTransport(serverPort: 1))
        do {
            _ = try await client.fetchSessionHistory(sessionID: "../etc")
            XCTFail("expected invalidSessionKey")
        } catch let error as SessionHistoryError {
            guard case .invalidSessionKey = error else {
                return XCTFail("expected invalidSessionKey, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFetchSessionStatusRejectsUnsafeSessionKeyBeforeTransport() async {
        let client = GatewaySessionHistoryClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: makeTransport(serverPort: 1))
        do {
            _ = try await client.fetchSessionStatus(sessionID: "a/b")
            XCTFail("expected invalidSessionKey")
        } catch let error as SessionHistoryError {
            guard case .invalidSessionKey = error else {
                return XCTFail("expected invalidSessionKey, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

/// Thread-safe recorder of every inbound RPC method, observed server-side.
private final class RecordedMethods: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [String] = []

    var all: [String] { lock.lock(); defer { lock.unlock() }; return _all }

    func record(_ method: String) {
        lock.lock()
        _all.append(method)
        lock.unlock()
    }
}

/// Thread-safe capture of a session.* request's `session_id` param.
private final class SessionParamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _sessionID: String?

    var sessionID: String? { lock.lock(); defer { lock.unlock() }; return _sessionID }

    func record(_ params: [String: Any]) {
        lock.lock()
        _sessionID = params["session_id"] as? String
        lock.unlock()
    }
}
