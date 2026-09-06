import XCTest
import FleetCore
import FleetNetworking

/// M5 conversation streaming client: `GatewayConversationClient`
/// (session.create / session.resume / prompt.submit / session.interrupt +
/// streamed event rendering) against in-process fixture servers — no live
/// Hermes gateway is touched.
///
/// The final test is the conversation-path safety gate: the mutating seam
/// issues EXACTLY the four deliberate user-action methods, never a read-only
/// or privileged call, and the event subscription itself issues zero RPCs.
final class ConversationClientTests: XCTestCase {

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

    /// A server→client event frame: `{type, session_id, payload?}`.
    private static func eventFrame(
        type: String, sessionID: String, payload: [String: Any]? = nil
    ) -> String {
        var params: [String: Any] = ["type": type, "session_id": sessionID]
        if let payload { params["payload"] = payload }
        let data = try! JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "method": "event", "params": params])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: session.create

    func testCreateSessionSendsParamsAndDecodesSession() async throws {
        let captured = ConversationParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, params) = Self.extractRequest(frame) else { return [] }
                if method == "session.create" {
                    captured.record(params)
                    return [Self.responseFrame(id: id, result: [
                        "session_id": "abc12345",
                        "stored_session_id": "k-1",
                        "message_count": 0,
                        "messages": [],
                        "info": ["model": "deepseek-v4-flash", "provider": "nous", "profile_name": "default"],
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

        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let session = try await client.createSession(title: "Research", profile: "default", model: "deepseek-v4-flash", provider: "nous", cols: 80)

        XCTAssertEqual(session.sessionID, "abc12345")
        XCTAssertEqual(session.storedSessionID, "k-1")
        XCTAssertEqual(session.messageCount, 0)
        XCTAssertEqual(session.model, "deepseek-v4-flash")
        XCTAssertEqual(session.provider, "nous")
        XCTAssertEqual(session.profileName, "default")

        XCTAssertEqual(captured.title, "Research")
        XCTAssertEqual(captured.profile, "default")
        XCTAssertEqual(captured.model, "deepseek-v4-flash")
        XCTAssertEqual(captured.provider, "nous")
        XCTAssertEqual(captured.cols, 80)
    }

    func testCreateSessionDecodesSeedMessages() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "session.create" {
                    return [Self.responseFrame(id: id, result: [
                        "session_id": "s1",
                        "stored_session_id": "k1",
                        "message_count": 2,
                        "messages": [
                            ["role": "user", "text": "hi", "row_id": 1],
                            ["role": "assistant", "text": "hello!", "row_id": 2],
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

        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let session = try await client.createSession(title: nil, profile: nil, model: nil, provider: nil, cols: nil)
        XCTAssertEqual(session.messageCount, 2)
        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(session.messages[0].role, .user)
        XCTAssertEqual(session.messages[0].text, "hi")
        XCTAssertEqual(session.messages[1].role, .assistant)
        XCTAssertEqual(session.messages[1].text, "hello!")
    }

    // MARK: session.resume

    func testResumeSessionSendsSessionIDAndDecodes() async throws {
        let captured = ConversationParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, params) = Self.extractRequest(frame) else { return [] }
                if method == "session.resume" {
                    captured.record(params)
                    return [Self.responseFrame(id: id, result: [
                        "session_id": "sess-001",
                        "stored_session_id": "stored-001",
                        "message_count": 1,
                        "messages": [["role": "user", "text": "hello", "row_id": 9]],
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

        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let session = try await client.resumeSession(sessionID: "sess-001")
        XCTAssertEqual(session.sessionID, "sess-001")
        XCTAssertEqual(session.storedSessionID, "stored-001")
        XCTAssertEqual(session.messageCount, 1)
        XCTAssertEqual(session.messages[0].text, "hello")
        XCTAssertEqual(captured.sessionID, "sess-001")
    }

    func testResumeSessionNotFoundMaps4007() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "session.resume" {
                    // session.resume reports an unknown stored session with 4007
                    // (methods_session.py:543) — NOT 4001, which is the
                    // `_sess_nowait` code for prompt.submit / session.interrupt.
                    return [Self.errorFrame(id: id, code: 4007, message: "session not found")]
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

        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.resumeSession(sessionID: "stale")
            XCTFail("expected sessionNotFound")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .sessionNotFound("session not found"))
        } catch {
            XCTFail("unexpected error \\(error)")
        }
    }

    func testResumeSessionMissingIDMapsInvalidRequest() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "session.resume" {
                    return [Self.errorFrame(id: id, code: 4006, message: "session_id required")]
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

        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            // A safe, non-empty id passes the M9 client guard and reaches the
            // gateway, which answers 4006 "session_id required" → mapped to
            // .invalidRequest. (An EMPTY id is now rejected client-side by the
            // M9 guard before any RPC — see testResumeSessionRejectsEmptyKey.)
            _ = try await client.resumeSession(sessionID: "missing")
            XCTFail("expected invalidRequest")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .invalidRequest("session_id required"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: prompt.submit

    func testSubmitPromptSendsSessionAndTextAndDecodesStreaming() async throws {
        let captured = ConversationParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, params) = Self.extractRequest(frame) else { return [] }
                if method == "prompt.submit" {
                    captured.record(params)
                    return [Self.responseFrame(id: id, result: ["status": "streaming"])]
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

        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let submission = try await client.submitPrompt(sessionID: "sess-001", text: "summarize the plan")
        XCTAssertTrue(submission.isStreaming)
        XCTAssertEqual(captured.sessionID, "sess-001")
        XCTAssertEqual(captured.text, "summarize the plan")
    }

    func testSubmitPromptSessionNotFoundMaps4001() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "prompt.submit" {
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

        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.submitPrompt(sessionID: "gone", text: "hi")
            XCTFail("expected sessionNotFound")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .sessionNotFound("session not found"))
        } catch {
            XCTFail("unexpected error \\(error)")
        }
    }

    // MARK: session.interrupt

    func testInterruptSendsSessionIDAndDecodes() async throws {
        let captured = ConversationParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, params) = Self.extractRequest(frame) else { return [] }
                if method == "session.interrupt" {
                    captured.record(params)
                    return [Self.responseFrame(id: id, result: ["status": "interrupted"])]
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

        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let result = try await client.interrupt(sessionID: "sess-001")
        XCTAssertTrue(result.isInterrupted)
        XCTAssertNil(result.turnIsolation)
        XCTAssertEqual(captured.sessionID, "sess-001")
    }

    // MARK: not connected

    func testAllConversationRPCRsNotConnectedWhenTransportNotConnected() async {
        let transport = makeTransport(serverPort: 1) // never connected
        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)

        let calls: [() async throws -> Void] = [
            { _ = try await client.createSession(title: nil, profile: nil, model: nil, provider: nil, cols: nil) },
            { _ = try await client.resumeSession(sessionID: "s") },
            { _ = try await client.submitPrompt(sessionID: "s", text: "hi") },
            { _ = try await client.interrupt(sessionID: "s") },
        ]
        for call in calls {
            do {
                _ = try await call()
                XCTFail("expected notConnected")
            } catch let error as ConversationError {
                XCTAssertEqual(error, .notConnected)
            } catch {
                XCTFail("unexpected error \\(error)")
            }
        }
    }

    // MARK: streaming — spec §31 "assistant output streams" + "basic tool/status events render"

    /// A full scripted turn: message.start → message.delta ×2 → status.update
    /// → thinking.delta → reasoning.delta → tool.start → tool.complete →
    /// message.complete. The client's `events` stream must surface these as
    /// typed `ConversationEvent`s in order.
    func testStreamsFullTurnEventsInOrder() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "prompt.submit" {
                    return [
                        Self.responseFrame(id: id, result: ["status": "streaming"]),
                        Self.eventFrame(type: "message.start", sessionID: "sess-001"),
                        Self.eventFrame(type: "message.delta", sessionID: "sess-001", payload: ["text": "The "]),
                        Self.eventFrame(type: "message.delta", sessionID: "sess-001", payload: ["text": "plan is:"]),
                        Self.eventFrame(type: "status.update", sessionID: "sess-001", payload: ["kind": "process", "text": "thinking…"]),
                        Self.eventFrame(type: "thinking.delta", sessionID: "sess-001", payload: ["text": "hmm"]),
                        Self.eventFrame(type: "reasoning.delta", sessionID: "sess-001", payload: ["text": "deep"]),
                        Self.eventFrame(type: "tool.start", sessionID: "sess-001", payload: ["tool_id": "t1", "name": "web_search", "context": "search(x)"]),
                        Self.eventFrame(type: "tool.complete", sessionID: "sess-001", payload: ["tool_id": "t1", "name": "web_search", "summary": "3 results"]),
                        Self.eventFrame(type: "message.complete", sessionID: "sess-001", payload: ["text": "The plan is: search."]),
                    ]
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

        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)

        // Subscribe BEFORE submitting so no streamed event is missed.
        let collector = EventCollector()
        let subscription = Task {
            for await event in client.events {
                collector.append(event)
            }
        }

        let submission = try await client.submitPrompt(sessionID: "sess-001", text: "make a plan")
        XCTAssertTrue(submission.isStreaming)

        // Wait for message.complete (the turn terminal frame).
        let terminal = await collector.waitForTerminal(timeout: .seconds(3))
        XCTAssertTrue(terminal, "expected message.complete within timeout; got \\(collector.all)")

        subscription.cancel()

        let events = collector.all
        XCTAssertEqual(events.count, 9)

        guard case .messageStart(let sid, _) = events[0] else { return XCTFail("expected messageStart") }
        XCTAssertEqual(sid, "sess-001")

        guard case .messageDelta(_, let t1, _, _) = events[1] else { return XCTFail("expected messageDelta") }
        XCTAssertEqual(t1, "The ")
        guard case .messageDelta(_, let t2, _, _) = events[2] else { return XCTFail("expected messageDelta") }
        XCTAssertEqual(t2, "plan is:")

        guard case .statusUpdate(_, let kind, let stext, _) = events[3] else { return XCTFail("expected statusUpdate") }
        XCTAssertEqual(kind, "process")
        XCTAssertEqual(stext, "thinking…")

        guard case .thinkingDelta(_, let th, _) = events[4] else { return XCTFail("expected thinkingDelta") }
        XCTAssertEqual(th, "hmm")
        guard case .reasoningDelta(_, let rd, _) = events[5] else { return XCTFail("expected reasoningDelta") }
        XCTAssertEqual(rd, "deep")

        guard case .toolStart(_, let tid, let tname, let ctx, _, _) = events[6] else { return XCTFail("expected toolStart") }
        XCTAssertEqual(tid, "t1")
        XCTAssertEqual(tname, "web_search")
        XCTAssertEqual(ctx, "search(x)")
        guard case .toolComplete(_, let cid, let cname, let summary, _) = events[7] else { return XCTFail("expected toolComplete") }
        XCTAssertEqual(cid, "t1")
        XCTAssertEqual(cname, "web_search")
        XCTAssertEqual(summary, "3 results")

        guard case .messageComplete(_, let finalText, let status, _, _) = events[8] else { return XCTFail("expected messageComplete") }
        XCTAssertEqual(finalText, "The plan is: search.")
        XCTAssertNil(status)
    }

    /// A failed turn ends with `message.complete {status: "error"}` and an
    /// `error` event; both must render (spec §31 basic rendering + §30 errors
    /// answer "what failed").
    func testStreamsFailedTurnErrorComplete() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "prompt.submit" {
                    return [
                        Self.responseFrame(id: id, result: ["status": "streaming"]),
                        Self.eventFrame(type: "message.start", sessionID: "sess-001"),
                        Self.eventFrame(type: "message.complete", sessionID: "sess-001", payload: [
                            "text": "Error: provider rejected", "status": "error", "error": "provider rejected",
                        ]),
                        Self.eventFrame(type: "error", sessionID: "sess-001", payload: ["message": "provider rejected"]),
                    ]
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

        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let collector = EventCollector()
        let subscription = Task {
            for await event in client.events { collector.append(event) }
        }
        _ = try await client.submitPrompt(sessionID: "sess-001", text: "go")
        _ = await collector.waitForTerminal(timeout: .seconds(3))
        subscription.cancel()

        guard case .messageComplete(_, let text, let status, let error, _) = collector.all[1] else {
            return XCTFail("expected messageComplete, got \\(collector.all)")
        }
        XCTAssertEqual(status, "error")
        XCTAssertEqual(error, "provider rejected")
        XCTAssertTrue(text.contains("Error"))
        guard case .error(_, let message, _) = collector.all[2] else {
            return XCTFail("expected error event, got \\(collector.all)")
        }
        XCTAssertEqual(message, "provider rejected")
    }

    /// spec §5.5: an unknown event type must be tolerated (surfaced as
    /// `.unknown`), not fatal.
    func testToleratesUnknownEventType() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "prompt.submit" {
                    return [
                        Self.responseFrame(id: id, result: ["status": "streaming"]),
                        Self.eventFrame(type: "message.start", sessionID: "sess-001"),
                        Self.eventFrame(type: "moa.reference", sessionID: "sess-001", payload: ["text": "ref"]),
                        Self.eventFrame(type: "message.complete", sessionID: "sess-001", payload: ["text": "done"]),
                    ]
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

        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let collector = EventCollector()
        let subscription = Task {
            for await event in client.events { collector.append(event) }
        }
        _ = try await client.submitPrompt(sessionID: "sess-001", text: "go")
        _ = await collector.waitForTerminal(timeout: .seconds(3))
        subscription.cancel()

        XCTAssertEqual(collector.all.count, 3)
        guard case .unknown(_, let rawType, _) = collector.all[1] else {
            return XCTFail("expected unknown event preserved, got \\(collector.all)")
        }
        XCTAssertEqual(rawType, "moa.reference")
    }

    // MARK: conversation-path safety — §5.4 / §36 mutating-only gate

    /// The mutating seam issues ONLY the four deliberate user-action methods,
    /// and the event subscription itself issues ZERO RPCs. This is the §36
    /// "read-only screens do not accidentally issue mutating calls" inverse:
    /// the conversation path never accidentally issues a read-only call either,
    /// and never a privileged/destructive one (session.close/delete/undo/
    /// activate/compress/save/approval…).
    func testConversationPathIssuesOnlyExplicitUserActionMethods() async throws {
        let recorded = RecordedMethods()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                recorded.record(method)
                switch method {
                case "session.create":
                    return [Self.responseFrame(id: id, result: ["session_id": "s1", "stored_session_id": "k1", "message_count": 0, "messages": []])]
                case "session.resume":
                    return [Self.responseFrame(id: id, result: ["session_id": "s1", "message_count": 0, "messages": []])]
                case "prompt.submit":
                    return [Self.responseFrame(id: id, result: ["status": "streaming"])]
                case "session.interrupt":
                    return [Self.responseFrame(id: id, result: ["status": "interrupted"])]
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

        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)

        // Subscribe and iterate the stream concurrently with the RPCs; the
        // subscription itself must not emit any request.
        let collector = EventCollector()
        let subscription = Task {
            for await event in client.events { collector.append(event) }
        }

        _ = try await client.createSession(title: "t", profile: "p", model: nil, provider: nil, cols: nil)
        _ = try await client.resumeSession(sessionID: "s1")
        _ = try await client.submitPrompt(sessionID: "s1", text: "go")
        _ = try await client.interrupt(sessionID: "s1")

        try await Task.sleep(for: .milliseconds(300))
        subscription.cancel()

        let mutatingWhitelist: Set<String> = [
            "session.create", "session.resume", "prompt.submit", "session.interrupt",
        ]
        let allowed = recorded.all
        XCTAssertFalse(allowed.isEmpty, "conversation path should have issued requests")
        let offending = allowed.filter { !mutatingWhitelist.contains($0) }
        XCTAssertTrue(
            offending.isEmpty,
            "conversation path issued non-user-action calls: \\(offending.sorted())"
        )
        XCTAssertEqual(
            Set(allowed), mutatingWhitelist,
            "conversation path should have used exactly the explicit user-action methods"
        )
    }

    // MARK: M9 — session-key / profile traversal guards fail closed

    func testResumeSessionRejectsUnsafeSessionKeyBeforeTransport() async {
        let client = GatewayConversationClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: makeTransport(serverPort: 1))
        do {
            _ = try await client.resumeSession(sessionID: "../x")
            XCTFail("expected invalidSessionKey")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .invalidSessionKey("session_id is not a safe session key: ../x"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testResumeSessionRejectsEmptyKeyBeforeTransport() async {
        let client = GatewayConversationClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: makeTransport(serverPort: 1))
        do {
            _ = try await client.resumeSession(sessionID: "")
            XCTFail("expected invalidSessionKey")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .invalidSessionKey("session_id is not a safe session key: "))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSubmitPromptRejectsUnsafeSessionKeyBeforeTransport() async {
        let client = GatewayConversationClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: makeTransport(serverPort: 1))
        do {
            _ = try await client.submitPrompt(sessionID: "a/b", text: "hi")
            XCTFail("expected invalidSessionKey")
        } catch let error as ConversationError {
            guard case .invalidSessionKey = error else {
                return XCTFail("expected invalidSessionKey, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testInterruptRejectsUnsafeSessionKeyBeforeTransport() async {
        let client = GatewayConversationClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: makeTransport(serverPort: 1))
        do {
            _ = try await client.interrupt(sessionID: "..\\x")
            XCTFail("expected invalidSessionKey")
        } catch let error as ConversationError {
            guard case .invalidSessionKey = error else {
                return XCTFail("expected invalidSessionKey, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCreateSessionRejectsUnsafeProfileBeforeTransport() async {
        let client = GatewayConversationClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: makeTransport(serverPort: 1))
        do {
            _ = try await client.createSession(title: nil, profile: "../x", model: nil, provider: nil, cols: nil)
            XCTFail("expected invalidSessionKey")
        } catch let error as ConversationError {
            guard case .invalidSessionKey = error else {
                return XCTFail("expected invalidSessionKey, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCreateSessionSafeProfileStillChecksConnection() async {
        let client = GatewayConversationClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: makeTransport(serverPort: 1))
        do {
            _ = try await client.createSession(title: nil, profile: "researcher", model: nil, provider: nil, cols: nil)
            XCTFail("expected notConnected")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .notConnected)
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
    func record(_ method: String) { lock.lock(); _all.append(method); lock.unlock() }
}

/// Thread-safe capture of a conversation request's key params.
private final class ConversationParamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _sessionID: String?
    private var _title: String?
    private var _profile: String?
    private var _model: String?
    private var _provider: String?
    private var _cols: Int?
    private var _text: String?

    var sessionID: String? { lock.lock(); defer { lock.unlock() }; return _sessionID }
    var title: String? { lock.lock(); defer { lock.unlock() }; return _title }
    var profile: String? { lock.lock(); defer { lock.unlock() }; return _profile }
    var model: String? { lock.lock(); defer { lock.unlock() }; return _model }
    var provider: String? { lock.lock(); defer { lock.unlock() }; return _provider }
    var cols: Int? { lock.lock(); defer { lock.unlock() }; return _cols }
    var text: String? { lock.lock(); defer { lock.unlock() }; return _text }

    func record(_ params: [String: Any]) {
        lock.lock()
        _sessionID = params["session_id"] as? String
        _title = params["title"] as? String
        _profile = params["profile"] as? String
        _model = params["model"] as? String
        _provider = params["provider"] as? String
        _cols = (params["cols"] as? NSNumber)?.intValue
        _text = params["text"] as? String
        lock.unlock()
    }
}

/// Thread-safe accumulator for streamed conversation events, with a wait for
/// the turn-terminal frame (message.complete or error).
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [ConversationEvent] = []
    private var terminalSeen = false

    var all: [ConversationEvent] { lock.lock(); defer { lock.unlock() }; return _all }

    func append(_ event: ConversationEvent) {
        lock.lock()
        _all.append(event)
        if isTerminal(event) {
            terminalSeen = true
        }
        lock.unlock()
    }

    /// Wait (by polling) until a terminal frame arrives or the timeout passes.
    /// Returns whether the terminal was observed. Timeout-safe: never hangs.
    func waitForTerminal(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if hasSeenTerminal { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return hasSeenTerminal
    }

    private var hasSeenTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalSeen
    }

    private func isTerminal(_ event: ConversationEvent) -> Bool {
        switch event {
        case .messageComplete, .error: return true
        default: return false
        }
    }
}
