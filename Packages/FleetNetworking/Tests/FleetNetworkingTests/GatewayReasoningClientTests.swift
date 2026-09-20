import XCTest
import FleetCore
@testable import FleetNetworking

/// Dogfood r8: `GatewayReasoningClient` — read + session-scoped write of the
/// session reasoning level over the conversation transport. Wire shapes
/// verified against the local gateway source 2026-09-20:
/// - `config.get {key:"reasoning", session_id}` (methods_config.py:232
///   `@method("config.get")` → `_cfg_get_reasoning`:151) → `{value, display}`.
/// - `config.set {key:"reasoning", value, scope:"session", session_id}`
///   (methods_config_set.py:306 `_set_reasoning`) → `{key, value, scope}`
///   (`_kv`:54); session override only — never a global write.
final class GatewayReasoningClientTests: XCTestCase {

    // MARK: helpers (GatewayApprovalClientTests harness shape)

    private final class ParamCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Any] = [:]

        func record(_ params: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            storage = params
        }

        var params: [String: Any] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

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

    private static func extractRequest(_ frame: String) -> (id: String, method: String, params: [String: Any])? {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String else { return nil }
        return (id, method, obj["params"] as? [String: Any] ?? [:])
    }

    private static func responseFrame(id: String, result: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        return String(data: data, encoding: .utf8)!
    }

    private static func errorFrame(id: String, code: Int, message: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: 1. read RPC shape + decode

    func testReasoningGetSendsKeyAndSessionAndDecodesState() async throws {
        let captured = ParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, params) = Self.extractRequest(frame) else { return [] }
                if method == "config.get" {
                    captured.record(params)
                    return [Self.responseFrame(id: id, result: ["value": "high", "display": "show"])]
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

        let client = GatewayReasoningClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let state = try await client.reasoning(sessionID: "abc12345")

        XCTAssertEqual(state.level, .high)
        XCTAssertEqual(state.rawValue, "high")
        XCTAssertEqual(state.display, "show")

        let params = captured.params
        XCTAssertEqual(params["key"] as? String, "reasoning")
        XCTAssertEqual(params["session_id"] as? String, "abc12345")
        XCTAssertEqual(params.count, 2, "exactly the two documented params — no extras")
    }

    // MARK: 2. unknown readback word → level nil (honest unknown)

    func testUnknownReadbackWordMapsToNilLevel() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "config.get" {
                    return [Self.responseFrame(id: id, result: ["value": "ultra"])]
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

        let client = GatewayReasoningClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let state = try await client.reasoning(sessionID: "abc12345")
        XCTAssertNil(state.level, "an unknown word is an honest unknown, never a guessed mapping")
        XCTAssertEqual(state.rawValue, "ultra")
    }

    // MARK: 3. write RPC shape + reported-value readback

    func testSetReasoningSendsExactParamsAndReturnsReportedLevel() async throws {
        let captured = ParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, params) = Self.extractRequest(frame) else { return [] }
                if method == "config.set" {
                    captured.record(params)
                    // methods_config_set.py:54 `_kv` shape
                    return [Self.responseFrame(id: id, result: ["key": "reasoning", "value": "high", "scope": "session"])]
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

        let client = GatewayReasoningClient(gatewayID: GatewayID(rawValue: "resume-gw"), transport: transport)
        let reported = try await client.setReasoning(.high, sessionID: "abc12345")
        XCTAssertEqual(reported, .high)

        let params = captured.params
        XCTAssertEqual(params["key"] as? String, "reasoning")
        XCTAssertEqual(params["value"] as? String, "high")
        XCTAssertEqual(params["scope"] as? String, "session")
        XCTAssertEqual(params["session_id"] as? String, "abc12345")
        XCTAssertEqual(params.count, 4, "exactly the four documented params — no extras")
    }

    // MARK: 4. mismatched readback → fail-closed error

    func testSetReasoningFailsClosedOnMismatchedReadback() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "config.set" {
                    // The gateway reports a DIFFERENT level than requested —
                    // the client must throw, never pretend the pick landed.
                    return [Self.responseFrame(id: id, result: ["key": "reasoning", "value": "low", "scope": "session"])]
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

        let client = GatewayReasoningClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.setReasoning(.high, sessionID: "abc12345")
            XCTFail("a mismatched readback must throw, never pretend success")
        } catch {}
    }

    // MARK: 5. error propagation: 4002 (unknown value) → invalidRequest

    func testSetReasoningMapsUnknownValueError() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "config.set" {
                    return [Self.errorFrame(id: id, code: 4002, message: "unknown reasoning value: banana")]
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

        let client = GatewayReasoningClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.setReasoning(.high, sessionID: "abc12345")
            XCTFail("4002 must surface as an error")
        } catch let error as ConversationError {
            guard case .invalidRequest = error else {
                return XCTFail("expected .invalidRequest, got \(error)")
            }
        }
    }

    // MARK: 6. invalid session key → fail-closed BEFORE any RPC (M9)

    func testInvalidSessionKeyIsRejectedBeforeAnyRpc() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { _ in [] }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayReasoningClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.reasoning(sessionID: "../../etc")
            XCTFail("path-traversal key must be rejected before any RPC")
        } catch let error as ConversationError {
            guard case .invalidSessionKey = error else {
                return XCTFail("expected .invalidSessionKey, got \(error)")
            }
        }
        do {
            _ = try await client.setReasoning(.high, sessionID: "../escape")
            XCTFail("path-traversal key must be rejected before any RPC")
        } catch let error as ConversationError {
            guard case .invalidSessionKey = error else {
                return XCTFail("expected .invalidSessionKey, got error: \(error)")
            }
        }
    }
}
