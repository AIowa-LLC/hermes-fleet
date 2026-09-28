import XCTest
import FleetCore
@testable import FleetNetworking

/// Live Ops v1 — `GatewayLiveOpsClient` over in-process fixture servers.
/// Wire shapes verified against hermes-agent origin/main 6636b08 (see
/// `GatewayLiveOpsClient.swift` header + `FleetCore/LiveOps.swift`):
/// - `session.active_list` → `{"sessions": [...]}`.
/// - `delegation.status` → `{"active": [...]}`.
/// - `subagent.list`/`subagent.tail`/`subagent.interrupt`/`subagent.steer`.
/// - unknown method → JSON-RPC -32601; not-attached → 4001.
final class GatewayLiveOpsClientTests: XCTestCase {

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

    private static func errorFrame(id: String, code: Int, message: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        return String(data: data, encoding: .utf8)!
    }

    private func connectedClient(
        script: InProcessWebSocketServer.Script
    ) async throws -> (client: GatewayLiveOpsClient, server: InProcessWebSocketServer, transport: GatewayWebSocketTransport) {
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        let client = GatewayLiveOpsClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        return (client, server, transport)
    }

    // MARK: 1. session.active_list → snapshot decode

    func testMissingSessionsArrayIsUnavailableNotReportingZero() async throws {
        let (client, server, transport) = try await connectedClient(script: .init(
            onOpen: [Self.readyFrame()], onText: { frame in
                guard let (id, _, _) = Self.extractRequest(frame) else { return [] }
                return [Self.responseFrame(id: id, result: [:])]
            }))
        defer { server.stop(); Task { await transport.disconnect() } }
        let snapshot = await client.snapshot()
        XCTAssertFalse(snapshot.coverage.isReporting)
        XCTAssertTrue(LiveOpsSnapshot(gateways: [snapshot]).activeCount.isPartial)
    }

    func testSnapshotConnectsColdTransportBeforeReporting() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "session.active_list" {
                    return [Self.responseFrame(id: id, result: ["sessions": []])]
                }
                if method == "delegation.status" {
                    return [Self.errorFrame(id: id, code: -32601, message: "method not found")]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        let client = GatewayLiveOpsClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        defer { Task { await transport.disconnect() } }

        XCTAssertEqual(transport.state, .disconnected, "test starts with the transport cold")
        let snapshot = await client.snapshot()

        XCTAssertEqual(snapshot.coverage, .reporting)
        XCTAssertTrue(snapshot.operations.isEmpty)
        XCTAssertEqual(transport.state, .connected, "snapshot owns opening its per-gateway transport")
    }

    func testSnapshotDecodesActiveListRowsWithSourceQualifiedIdentity() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "session.active_list" {
                    return [Self.responseFrame(id: id, result: [
                        "sessions": [[
                            "id": "sid-1", "session_key": "durable-1", "title": "Fixture",
                            "preview": "doing work", "model": "fixture-model",
                            "started_at": 1000.0, "last_active": 2000.0,
                            "message_count": 4, "status": "working",
                        ]]
                    ])]
                }
                if method == "delegation.status" {
                    return [Self.errorFrame(id: id, code: -32601, message: "method not found")]
                }
                return []
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.coverage, .reporting)
        XCTAssertEqual(snapshot.operations.count, 1)
        let op = try XCTUnwrap(snapshot.operations.first)
        XCTAssertEqual(op.id.gatewayID, GatewayID(rawValue: "workstation"))
        XCTAssertEqual(op.id.runtimeSessionID, "sid-1")
        XCTAssertEqual(op.sessionKey, "durable-1")
        XCTAssertEqual(op.status, .working)
        XCTAssertEqual(op.messageCount, 4)
        // delegation.status unsupported here — subagents unknown, not zero.
        XCTAssertFalse(op.subagentsKnown)
        XCTAssertNil(op.subagents)
    }

    func testSameRuntimeSidOnDifferentGatewaysDoesNotCollide() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "session.active_list" {
                    return [Self.responseFrame(id: id, result: [
                        "sessions": [["id": "sid-shared", "session_key": "k1", "status": "idle"]]
                    ])]
                }
                if method == "delegation.status" {
                    return [Self.errorFrame(id: id, code: -32601, message: "method not found")]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }
        let transportA = makeTransport(serverPort: server.listeningPort)
        try await transportA.connect()
        let clientA = GatewayLiveOpsClient(gatewayID: GatewayID(rawValue: "gw-a"), transport: transportA)
        let snapshotA = await clientA.snapshot()
        defer { Task { await transportA.disconnect() } }

        XCTAssertEqual(snapshotA.operations.first?.id.gatewayID, GatewayID(rawValue: "gw-a"))
        XCTAssertNotEqual(
            snapshotA.operations.first?.id,
            LiveOperationID(gatewayID: GatewayID(rawValue: "gw-b"), runtimeSessionID: "sid-shared")
        )
    }

    func testMalformedRowsDroppedMissingIDOrSessionKey() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "session.active_list" {
                    return [Self.responseFrame(id: id, result: [
                        "sessions": [
                            ["id": "sid-good", "session_key": "key-good", "status": "idle"],
                            ["session_key": "key-no-id", "status": "idle"], // missing id
                            ["id": "sid-no-key", "status": "idle"], // missing session_key
                        ]
                    ])]
                }
                if method == "delegation.status" {
                    return [Self.errorFrame(id: id, code: -32601, message: "method not found")]
                }
                return []
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.operations.count, 1, "only the well-formed row survives")
        XCTAssertEqual(snapshot.operations.first?.id.runtimeSessionID, "sid-good")
    }

    func testBoundedSessionRowCount() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "session.active_list" {
                    let rows: [[String: Any]] = (0..<300).map { i in
                        ["id": "sid-\(i)", "session_key": "key-\(i)", "status": "idle"]
                    }
                    return [Self.responseFrame(id: id, result: ["sessions": rows])]
                }
                if method == "delegation.status" {
                    return [Self.errorFrame(id: id, code: -32601, message: "method not found")]
                }
                return []
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.operations.count, GatewayLiveOpsClient.maxSessionRows, "hostile row count is capped")
    }

    // MARK: 2. delegation.status join (owner_agent_session_id → session_key)

    func testDelegationStatusJoinsSubagentsBySessionKeyNotRuntimeID() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "session.active_list" {
                    return [Self.responseFrame(id: id, result: [
                        "sessions": [[
                            // Deliberately DIFFERENT from session_key — the
                            // join must use session_key, never id.
                            "id": "runtime-sid-999", "session_key": "owner-a",
                            "status": "working",
                        ]]
                    ])]
                }
                if method == "delegation.status" {
                    return [Self.responseFrame(id: id, result: [
                        "active": [[
                            "subagent_id": "child-1", "parent_id": NSNull(), "depth": 0,
                            "goal": "fixture goal", "model": "m", "started_at": 500.0,
                            "status": "running", "tool_count": 2,
                            "owner_agent_session_id": "owner-a",
                        ]]
                    ])]
                }
                return []
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        let snapshot = await client.snapshot()
        let op = try XCTUnwrap(snapshot.operations.first)
        XCTAssertTrue(op.subagentsKnown)
        XCTAssertEqual(op.subagents?.count, 1)
        XCTAssertEqual(op.subagents?.first?.subagentID, "child-1")
    }

    func testDelegationStatusRowWithoutOwnerIsDropped() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "session.active_list" {
                    return [Self.responseFrame(id: id, result: [
                        "sessions": [["id": "sid-1", "session_key": "key-1", "status": "idle"]]
                    ])]
                }
                if method == "delegation.status" {
                    return [Self.responseFrame(id: id, result: [
                        "active": [["subagent_id": "orphaned-row", "status": "running"]] // no owner id
                    ])]
                }
                return []
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        let snapshot = await client.snapshot()
        let op = try XCTUnwrap(snapshot.operations.first)
        XCTAssertTrue(op.subagentsKnown, "delegation.status DID answer — known-empty, not unknown")
        XCTAssertEqual(op.subagents, [])
    }

    func testBoundedSubagentRowCount() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "session.active_list" {
                    return [Self.responseFrame(id: id, result: [
                        "sessions": [["id": "sid-1", "session_key": "durable-1", "status": "working"]]
                    ])]
                }
                if method == "delegation.status" {
                    let manyChildren: [[String: Any]] = (0..<700).map { i in
                        ["subagent_id": "child-\(i)", "status": "running", "owner_agent_session_id": "durable-1"]
                    }
                    return [Self.responseFrame(id: id, result: ["active": manyChildren])]
                }
                return []
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        let snapshot = await client.snapshot()
        XCTAssertEqual(
            snapshot.operations.first?.subagents?.count, GatewayLiveOpsClient.maxSubagentRows,
            "hostile subagent count is capped")
    }

    // MARK: 3. coverage classification

    func testUnsupportedMethodClassifiesAsUnsupportedCoverage() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, _, _) = Self.extractRequest(frame) else { return [] }
                return [Self.errorFrame(id: id, code: -32601, message: "method not found")]
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.coverage, .unsupported)
        XCTAssertEqual(snapshot.operations, [])
    }

    func testColdTransportConnectFailureClassifiesAsFailedCoverage() async throws {
        let transport = makeTransport(serverPort: 1) // never connected
        let client = GatewayLiveOpsClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let snapshot = await client.snapshot()
        guard case .failed = snapshot.coverage else {
            return XCTFail("expected a classified connect failure, got \(snapshot.coverage)")
        }
        XCTAssertEqual(snapshot.operations, [])
    }

    func testGenericRPCFailureClassifiesAsFailedWithRedactedReason() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, _, _) = Self.extractRequest(frame) else { return [] }
                return [Self.errorFrame(id: id, code: 5000, message: "internal failure")]
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        let snapshot = await client.snapshot()
        guard case .failed(let reason) = snapshot.coverage else {
            return XCTFail("expected .failed, got \(snapshot.coverage)")
        }
        XCTAssertTrue(reason.contains("internal failure"))
    }

    // MARK: 4. subagent.list / tail / interrupt — 4001 not-attached

    func testSubagentListSendsSessionScopedParams() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, params) = Self.extractRequest(frame) else { return [] }
                if method == "subagent.list" {
                    XCTAssertEqual(params["session_id"] as? String, "sess-1")
                    return [Self.responseFrame(id: id, result: [
                        "subagents": [[
                            "subagent_id": "child-1", "status": "running",
                            "accepting_steer": true,
                        ]]
                    ])]
                }
                return []
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        let subagents = try await client.listSubagents(sessionID: "sess-1")
        XCTAssertEqual(subagents.count, 1)
        XCTAssertEqual(subagents.first?.acceptingSteer, true)
    }

    func testSubagentListMapsErrorCode4001ToNotAttached() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "subagent.list" {
                    return [Self.errorFrame(id: id, code: 4001, message: "session not found or not owned by this transport")]
                }
                return []
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        do {
            _ = try await client.listSubagents(sessionID: "sess-1")
            XCTFail("expected .notAttached")
        } catch LiveOpsControlError.notAttached {
            // expected
        }
    }

    func testSubagentInterruptDecodesFound() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, params) = Self.extractRequest(frame) else { return [] }
                if method == "subagent.interrupt" {
                    XCTAssertEqual(params["subagent_id"] as? String, "child-1")
                    return [Self.responseFrame(id: id, result: ["found": true, "subagent_id": "child-1"])]
                }
                return []
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        let found = try await client.interrupt(subagentID: "child-1", sessionID: "sess-1")
        XCTAssertTrue(found)
    }

    func testSubagentInterruptUnsupportedMethodMapsToUnsupportedError() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, _, _) = Self.extractRequest(frame) else { return [] }
                return [Self.errorFrame(id: id, code: -32601, message: "method not found")]
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        do {
            _ = try await client.interrupt(subagentID: "child-1", sessionID: "sess-1")
            XCTFail("expected .unsupported")
        } catch LiveOpsControlError.unsupported {
            // expected
        }
    }

    func testSubagentTailDecodesAvailableTextTruncated() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "subagent.tail" {
                    return [Self.responseFrame(id: id, result: [
                        "available": true, "text": "fixture transcript tail", "truncated": true,
                    ])]
                }
                return []
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        let tail = try await client.tail(subagentID: "child-1", sessionID: "sess-1")
        XCTAssertTrue(tail.available)
        XCTAssertEqual(tail.text, "fixture transcript tail")
        XCTAssertTrue(tail.truncated)
    }

    // MARK: 5. subagent.steer — queued vs rejected (never throws on rejection)

    func testSubagentSteerQueued() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, params) = Self.extractRequest(frame) else { return [] }
                if method == "subagent.steer" {
                    XCTAssertEqual(params["text"] as? String, "keep going")
                    return [Self.responseFrame(id: id, result: [
                        "status": "queued", "subagent_id": "child-1", "text": "keep going",
                    ])]
                }
                return []
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        let result = try await client.steer(subagentID: "child-1", sessionID: "sess-1", text: "keep going")
        XCTAssertEqual(result, .queued)
    }

    func testSubagentSteerRejectedIsNotAnError() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "subagent.steer" {
                    return [Self.responseFrame(id: id, result: [
                        "status": "rejected", "subagent_id": "child-1", "text": "hi",
                    ])]
                }
                return []
            }
        )
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        // A "rejected" gateway answer is a successful RPC, not a thrown error.
        let result = try await client.steer(subagentID: "child-1", sessionID: "sess-1", text: "hi")
        XCTAssertEqual(result, .rejected)
    }

    // MARK: 6. session-key validation (M9) — fail closed before any RPC

    func testInvalidSessionKeyRejectedBeforeAnyRPC() async throws {
        let script = InProcessWebSocketServer.Script(onOpen: [Self.readyFrame()])
        let (client, server, transport) = try await connectedClient(script: script)
        defer { server.stop(); Task { await transport.disconnect() } }

        do {
            _ = try await client.listSubagents(sessionID: "../etc/passwd")
            XCTFail("expected a validation failure for an unsafe session key")
        } catch LiveOpsControlError.rpcFailed {
            // expected — fails closed before any RPC is sent
        }
    }

    // MARK: 7. cold transport connects on demand; connection failure is surfaced

    func testControlConnectFailureIsMappedToRPCFailure() async throws {
        let transport = makeTransport(serverPort: 1) // never connected
        let client = GatewayLiveOpsClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.listSubagents(sessionID: "sess-1")
            XCTFail("expected a classified connection failure")
        } catch LiveOpsControlError.rpcFailed {
            // A failed connect is preserved as an RPC transport failure.
        } catch {
            XCTFail("expected .rpcFailed, got \(error)")
        }
    }
}
