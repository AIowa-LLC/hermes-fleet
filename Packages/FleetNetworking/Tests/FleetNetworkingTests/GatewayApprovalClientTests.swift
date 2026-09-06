import XCTest
import FleetCore
@testable import FleetNetworking

/// R9-T1: `GatewayApprovalClient` — decode/subscribe/respond over the
/// conversation transport, against in-process fixture servers. Wire shapes
/// verified against hermes-agent 0.21.0 source:
/// - push event `approval.request`: `tui_gateway/server.py:3102`
///   `_emit_approval_request` → `_event_frame`
///   (`{"jsonrpc":"2.0","method":"event","params":{"type","session_id","payload"}}`)
/// - payload: `request_id` (uuid4 hex — tools/approval.py:2826), redacted
///   `command`, `description`, `choices` (server.py:3036
///   `_approval_request_payload`).
/// - `approval.respond`: `tui_gateway/methods_prompt.py:1881` — params
///   `{session_id, choice: once|session|always|deny, request_id?, all?}` →
///   `{"resolved": N}`.
/// - per-session YOLO: `config.set key=yolo value=1 scope=session`
///   (server.py:14967-15035); readback on `session.info`
///   `{yolo, approval_mode}` (server.py:7758).
final class GatewayApprovalClientTests: XCTestCase {

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

    private static func eventFrame(
        type: String, sessionID: String, payload: [String: Any]? = nil, seq: Int? = nil
    ) -> String {
        var params: [String: Any] = ["type": type, "session_id": sessionID]
        if let seq { params["seq"] = seq }
        if let payload { params["payload"] = payload }
        let data = try! JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "method": "event", "params": params])
        return String(data: data, encoding: .utf8)!
    }

    /// The captured approval.request shape (server.py:3102 + :3036):
    /// command is ALREADY gateway-redacted (#48456) — the client re-masks as a
    /// second pass, never trusting the server blindly.
    private static func approvalRequestFrame(sessionID: String, requestID: String = "req-0001") -> String {
        eventFrame(
            type: "approval.request",
            sessionID: sessionID,
            payload: [
                "request_id": requestID,
                "command": "curl -H 'Authorization: Bearer [REDACTED]' https://api.example.com/v1/x",
                "description": "HTTP request to api.example.com",
                "choices": ["once", "session", "always", "deny"],
                "allow_session": true,
                "allow_permanent": true,
            ]
        )
    }

    // MARK: 1. event plumbing

    func testApprovalRequestEventSurfacesOnConversationStream() async throws {
        // Server pushes approval.request right after ready; no RPC needed.
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame(), Self.approvalRequestFrame(sessionID: "abc12345")]
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        // Subscribe BEFORE connecting — the push frames fan out at open; a
        // subscriber registered after connect() would miss them.
        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let stream = client.events
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        try await withTimeout(.seconds(3)) {
            for await event in stream {
                if case .approvalRequested(let sid, let rid, let command, let detail, let choices, _) = event {
                    XCTAssertEqual(sid, "abc12345")
                    XCTAssertEqual(rid, "req-0001")
                    XCTAssertTrue(command.contains("curl -H"), "command preview preserved: \(command)")
                    XCTAssertEqual(detail, "HTTP request to api.example.com")
                    XCTAssertEqual(choices, ["once", "session", "always", "deny"])
                    return
                }
            }
            XCTFail("approval.request never surfaced on the conversation stream")
        }
    }

    func testApprovalRequestEventWithoutRequestIDIsDroppedFailSoft() async throws {
        // Unknown/malformed shapes must not crash or surface — the frame is
        // logged and dropped (fail-soft decode). A benign status.update
        // pushed AFTER the malformed frame proves the transport survived it.
        let malformed = Self.eventFrame(
            type: "approval.request",
            sessionID: "abc12345",
            payload: ["command": "rm -rf /x", "choices": ["once", "deny"]]  // no request_id
        )
        let benign = Self.eventFrame(
            type: "status.update", sessionID: "abc12345",
            payload: ["kind": "process", "text": "working"]
        )
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame(), malformed, benign]
        )
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
                if case .approvalRequested = event {
                    XCTFail("a frame without request_id must be dropped, not surfaced")
                    return
                }
                if case .statusUpdate = event {
                    // The benign event arrived AFTER the malformed frame —
                    // the transport stayed alive and nothing leaked through.
                    return
                }
            }
            XCTFail("benign status.update never arrived — transport died on the malformed frame")
        }
    }

    // MARK: 2. respond RPC shape

    func testRespondSendsCorrectParamsAndDecodesResolvedCount() async throws {
        let captured = ApprovalParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, params) = Self.extractRequest(frame) else { return [] }
                if method == "approval.respond" {
                    captured.record(params)
                    return [Self.responseFrame(id: id, result: ["resolved": 1])]
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

        let client = GatewayApprovalClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let resolved = try await client.respond(
            sessionID: "abc12345", requestID: "req-0001", choice: .once, all: false
        )
        XCTAssertEqual(resolved, 1)

        let params = await captured.params
        XCTAssertEqual(params["session_id"] as? String, "abc12345")
        XCTAssertEqual(params["choice"] as? String, "once")
        XCTAssertEqual(params["request_id"] as? String, "req-0001")
        XCTAssertEqual(params["all"] as? Bool, false)
        XCTAssertEqual(params.count, 4, "exactly the four documented params — no extras")
    }

    // MARK: 3. YOLO toggle RPC shape

    func testSessionYoloToggleSendsConfigSetYoloSessionScope() async throws {
        let captured = ApprovalParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, params) = Self.extractRequest(frame) else { return [] }
                if method == "config.set" {
                    captured.record(params)
                    // server.py:15023-15032 shape
                    return [Self.responseFrame(id: id, result: ["key": "yolo", "value": "1", "scope": "session"])]
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

        let client = GatewayApprovalClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let enabled = try await client.setSessionYolo(true, sessionID: "abc12345")
        XCTAssertTrue(enabled)

        let params = await captured.params
        XCTAssertEqual(params["key"] as? String, "yolo")
        XCTAssertEqual(params["value"] as? String, "1")
        XCTAssertEqual(params["scope"] as? String, "session")
        XCTAssertEqual(params["session_id"] as? String, "abc12345")
    }

    // MARK: 4. pending snapshot RPC (reconnect restore)

    func testPendingSnapshotDecodesApprovalsList() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "approval.pending" {
                    return [Self.responseFrame(id: id, result: [
                        "approvals": [[
                            "request_id": "req-p1",
                            "command": "git push --force",
                            "description": "Force push",
                            "choices": ["once", "deny"],
                        ]]
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

        let client = GatewayApprovalClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let pending = try await client.pendingApprovals(sessionID: "abc12345")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.requestID, "req-p1")
        XCTAssertEqual(pending.first?.sessionID, "abc12345")
    }

    // MARK: 5. session.info yolo decode

    func testSessionInfoEventDecodesYoloAndApprovalMode() async throws {
        let infoFrame = Self.eventFrame(
            type: "session.info",
            sessionID: "abc12345",
            payload: ["model": "m1", "provider": "nous", "yolo": true, "approval_mode": "manual"]
        )
        let script = InProcessWebSocketServer.Script(onOpen: [Self.readyFrame(), infoFrame])
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let stream = client.events
        try await withTimeout(.seconds(3)) {
            for await event in stream {
                if case .sessionInfo(_, _, _, _, _, _, let yolo, let mode, _) = event {
                    XCTAssertEqual(yolo, true)
                    XCTAssertEqual(mode, "manual")
                    return
                }
            }
            XCTFail("session.info yolo/approval_mode never surfaced")
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

/// Records the params of the last captured RPC (thread-safe).
final class ApprovalParamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _params: [String: Any] = [:]
    var params: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return _params
    }
    func record(_ params: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        _params = params
    }
}
