import XCTest
import FleetCore
import FleetNetworking
import FleetPersistence
import FleetUI

/// U3 fixture full-loop suite — the Conversation screen acceptance, hosted on
/// the iOS simulator against the SHARED in-process gateway fixture
/// (`InProcessWebSocketServer`, compiled into this test bundle from the
/// FleetNetworking test target).
///
/// Drives the REAL `GatewayConversationSession` (connectivity + M5 conversation
/// + M6 replay + M4 history over one transport) through the `ConversationViewModel`
/// for the full loop: session.create → prompt.submit → incremental streaming
/// render → FORCED disconnect mid-stream (server abort) → reconnect →
/// `session.events.since` replay hydration → dedupe visible in the UI
/// transcript (no duplicated assistant rows/text) + replay notice. No live
/// Hermes gateway is touched.
@MainActor
final class ConversationFixtureLoopTests: XCTestCase {

    // MARK: - Fixture frame helpers (mirror the networking test suite)
    // `nonisolated`: these build JSON strings and are called from the
    // in-process server's `@Sendable` onText closures (nonisolated context).

    nonisolated static func readyFrame(epoch: String = "epoch-1") -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true,"heartbeat":false,"replay_epoch":"\#(epoch)"}}}"#
    }

    nonisolated static func extractRequest(_ frame: String) -> (id: String, method: String)? {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String else { return nil }
        return (id, method)
    }

    nonisolated static func responseFrame(id: String, result: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        return String(data: data, encoding: .utf8)!
    }

    /// A server→client event frame carrying a per-session `seq` (the replay
    /// watermark signal stamped by `event_replay.py`).
    nonisolated static func seqEventFrame(
        type: String, sessionID: String, seq: Int, payload: [String: Any]? = nil
    ) -> String {
        var params: [String: Any] = ["type": type, "session_id": sessionID, "seq": seq]
        if let payload { params["payload"] = payload }
        let data = try! JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "method": "event", "params": params])
        return String(data: data, encoding: .utf8)!
    }

    nonisolated static func bareEvent(
        type: String, sessionID: String, seq: Int, payload: [String: Any]? = nil
    ) -> [String: Any] {
        var event: [String: Any] = ["type": type, "session_id": sessionID, "seq": seq]
        if let payload { event["payload"] = payload }
        return event
    }

    nonisolated static func sinceResponse(
        id: String, events: [[String: Any]], latestSeq: Int,
        truncated: Bool = false, epoch: String = "epoch-1"
    ) -> String {
        responseFrame(id: id, result: [
            "events": events, "latest_seq": latestSeq,
            "truncated": truncated, "count": events.count, "epoch": epoch,
        ])
    }

    private func makeTransport(serverPort: UInt16) -> GatewayWebSocketTransport {
        let base = URL(string: "http://127.0.0.1:\(serverPort)")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30), inboundDeadline: .seconds(30),
            connectTimeout: .seconds(10), requestTimeout: .seconds(3)
        )
        return GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: config
        )
    }

    // MARK: - Full loop: create → submit → stream → forced drop → reconnect → replay dedupe

    /// THE U3 acceptance: the conversation screen drives the full loop against
    /// the in-process gateway fixture. Connection 1 streams a partial turn
    /// (message.start + deltas) then the server ABORTS mid-stream; the view
    /// model goes `.disconnected`; `reconnect()` re-opens connection 2, replay
    /// (`session.events.since`) re-injects ONLY the missed tail, and the UI
    /// transcript shows the completed assistant message with NO duplicates.
    func testFullLoopForcedDisconnectReconnectReplayDedupe() async throws {
        let sessionID = "s-1"

        // Connection 1: answers session.create + prompt.submit, streams a
        // partial turn with seq watermarks (message.start seq1, delta seq2,
        // delta seq3) — then the TEST aborts the socket mid-stream.
        let first = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                switch method {
                case "session.create":
                    return [Self.responseFrame(id: id, result: [
                        "session_id": sessionID, "stored_session_id": "k-1",
                        "message_count": 0, "messages": [],
                    ])]
                case "prompt.submit":
                    return [
                        Self.responseFrame(id: id, result: ["status": "streaming"]),
                        Self.seqEventFrame(type: "message.start", sessionID: sessionID, seq: 1),
                        Self.seqEventFrame(type: "message.delta", sessionID: sessionID, seq: 2, payload: ["text": "Hel"]),
                        Self.seqEventFrame(type: "message.delta", sessionID: sessionID, seq: 3, payload: ["text": "lo"]),
                    ]
                default:
                    return []
                }
            }
        )
        // Connection 2 (reconnect): same epoch, answers session.events.since
        // with ONLY the missed tail (seq 4,5) — never the already-rendered
        // prefix. This is where replay dedupe is proven.
        let second = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "session.events.since" {
                    return [Self.sinceResponse(
                        id: id,
                        events: [
                            Self.bareEvent(type: "message.delta", sessionID: sessionID, seq: 4, payload: ["text": " world"]),
                            Self.bareEvent(type: "message.complete", sessionID: sessionID, seq: 5, payload: ["text": "Hello world"]),
                        ],
                        latestSeq: 5)]
                }
                return []
            }
        )

        let server = try InProcessWebSocketServer(scripts: [first, second])
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        let conversationSession = GatewayConversationSession(
            gatewayID: GatewayID(rawValue: "workstation"),
            displayName: "MacBook",
            endpoint: URL(string: "http://127.0.0.1:\(server.listeningPort)")!,
            transport: transport
        )
        let cache = try SwiftDataCacheStore.makeInMemory()
        let viewModel = ConversationViewModel(
            session: conversationSession,
            cache: cache,
            route: Route(
                gatewayID: GatewayID(rawValue: "workstation"),
                profileSlug: ProfileSlug(rawValue: "default")
            ),
            sessionID: nil,
            statusInterval: .milliseconds(25)
        )

        // 1. Open a session (session.create) → ready.
        await viewModel.start()
        XCTAssertEqual(viewModel.phase, .ready, "session.create must leave the screen ready")

        // 2. Send a prompt → the partial turn streams in incrementally.
        await viewModel.send("hi")
        try await waitUntil("partial stream") {
            viewModel.transcript.last?.text == "Hello"
        }
        XCTAssertEqual(viewModel.phase, .streaming)
        XCTAssertTrue(viewModel.isStreaming)
        XCTAssertEqual(viewModel.transcript.filter { $0.kind == .assistant }.count, 1)

        // 3. FORCED disconnect mid-stream: abort the socket before
        // message.complete. The view model's status watcher detects the drop.
        server.abortConnection()
        try await waitUntil(
            "disconnected after abort",
            { viewModel.phase == .disconnected },
            context: viewModelContext(viewModel)
        )
        XCTAssertEqual(viewModel.transcript.filter { $0.kind == .assistant }.count, 1,
                       "partial assistant row is preserved across the drop")
        XCTAssertEqual(viewModel.transcript.last?.text, "Hello")

        // 4. Reconnect → replay hydration via session.events.since. The
        // replayed events (seq 4,5) flow back through the live channel into
        // the conversation stream; seq ≤ watermark (1-3) are dropped.
        await viewModel.reconnect()

        try await waitUntil(
            "replay dedupe final",
            {
                viewModel.phase == .ready
                    && viewModel.transcript.last?.isStreaming == false
                    && viewModel.transcript.last?.text == "Hello world"
            },
            context: viewModelContext(viewModel)
        )
        XCTAssertEqual(viewModel.replayNotice, "Reconnected · replayed 2 missed events",
                       "replay hydration is visible in the UI")

        // 5. DEDUPE: exactly one assistant row, full text, no duplicated prefix.
        let assistantRows = viewModel.transcript.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantRows.count, 1, "replay must not duplicate the assistant row")
        let assistantText = try XCTUnwrap(assistantRows.first?.text)
        XCTAssertEqual(assistantText, "Hello world")
        XCTAssertEqual(assistantText.components(separatedBy: "Hello").count - 1, 1,
                       "'Hello' prefix must appear exactly once (no replay duplication)")
        XCTAssertFalse(assistantRows.first?.isStreaming == true)

        await viewModel.teardown()
    }

    // MARK: - Reconnect without missed events (nothing to replay)

    func testReconnectNothingToReplayShowsCleanNotice() async throws {
        let sessionID = "s-2"
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                switch method {
                case "session.create":
                    return [Self.responseFrame(id: id, result: ["session_id": sessionID, "message_count": 0, "messages": []])]
                case "session.events.since":
                    return [Self.sinceResponse(id: id, events: [], latestSeq: 0)]
                default:
                    return []
                }
            }
        )
        let server = try InProcessWebSocketServer(scripts: [script, script])
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        let conversationSession = GatewayConversationSession(
            gatewayID: GatewayID(rawValue: "workstation"),
            displayName: "MacBook",
            endpoint: URL(string: "http://127.0.0.1:\(server.listeningPort)")!,
            transport: transport
        )
        let viewModel = ConversationViewModel(
            session: conversationSession,
            cache: try SwiftDataCacheStore.makeInMemory(),
            route: Route(
                gatewayID: GatewayID(rawValue: "workstation"),
                profileSlug: ProfileSlug(rawValue: "default")
            ),
            sessionID: nil,
            statusInterval: .milliseconds(25)
        )
        await viewModel.start()
        XCTAssertEqual(viewModel.phase, .ready)

        server.abortConnection()
        try await waitUntil(
            "disconnected after abort (nothing-to-replay)",
            { viewModel.phase == .disconnected },
            context: viewModelContext(viewModel)
        )

        await viewModel.reconnect()
        try await waitUntil(
            "ready after reconnect (nothing-to-replay)",
            { viewModel.phase == .ready },
            context: viewModelContext(viewModel)
        )
        XCTAssertEqual(viewModel.replayNotice, "Reconnected · nothing new")
        await viewModel.teardown()
    }

    // MARK: - P0-7: conversation re-entry over the shared cached session

    /// THE P0-7 acceptance: opening an EXISTING session and sending a message
    /// must work even after the conversation screen was popped and re-entered.
    /// The view model is destroyed on pop while the per-gateway conversation
    /// session (and its transport) stays cached and OPEN — the re-entered view
    /// model re-runs connect() (must be an idempotent no-op, never "connect()
    /// from open"), resumes the session, and its event subscription must be a
    /// FRESH live pipe over the transport's fan-out (not the previous view
    /// model's dead single-subscriber stream).
    func testReenteredConversationSendsAndStreamsOverStillOpenTransport() async throws {
        let sessionID = "s-reentry"

        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                switch method {
                case "session.resume":
                    return [Self.responseFrame(id: id, result: [
                        "session_id": sessionID, "message_count": 0, "messages": [],
                    ])]
                case "prompt.submit":
                    return [
                        Self.responseFrame(id: id, result: ["status": "streaming"]),
                        Self.seqEventFrame(type: "message.start", sessionID: sessionID, seq: 1),
                        Self.seqEventFrame(type: "message.delta", sessionID: sessionID, seq: 2, payload: ["text": "Re "]),
                        Self.seqEventFrame(type: "message.delta", sessionID: sessionID, seq: 3, payload: ["text": "entry OK"]),
                        Self.seqEventFrame(type: "message.complete", sessionID: sessionID, seq: 4, payload: ["text": "Re entry OK"]),
                    ]
                case "session.events.since":
                    return [Self.sinceResponse(id: id, events: [], latestSeq: 0)]
                default:
                    return []
                }
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        // The SHARED per-gateway conversation session, as cached by
        // AppEnvironment.conversationSession(for:) — one transport per gateway.
        let conversationSession = GatewayConversationSession(
            gatewayID: GatewayID(rawValue: "workstation"),
            displayName: "MacBook",
            endpoint: URL(string: "http://127.0.0.1:\(server.listeningPort)")!,
            transport: makeTransport(serverPort: server.listeningPort)
        )
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default")
        )

        func makeVM() -> ConversationViewModel {
            ConversationViewModel(
                session: conversationSession,
                cache: try! SwiftDataCacheStore.makeInMemory(),
                route: route,
                sessionID: sessionID,
                statusInterval: .milliseconds(25)
            )
        }

        // 1. First entry: open the existing session, send, receive the reply.
        //    Scoped so the view model DEALLOCATES on scope exit — exactly what
        //    a navigation pop does to the conversation screen's @State VM.
        weak var weakVM1: ConversationViewModel?
        do {
            let vm1 = makeVM()
            weakVM1 = vm1
            await vm1.start()
            XCTAssertEqual(vm1.phase, .ready, "first open must reach ready")
            await vm1.send("first hello")
            try await waitUntil(
                "vm1 reply streamed",
                { vm1.transcript.last?.text == "Re entry OK" && vm1.phase == .ready },
                context: viewModelContext(vm1)
            )
            XCTAssertEqual(vm1.errorMessage, nil, "no error on first entry")
            await vm1.teardown()
        }
        // Wait for the pop to actually release the view model (its deinit
        // cancels the event subscription task).
        try await waitUntil("vm1 released after pop", { weakVM1 == nil })
        XCTAssertNil(weakVM1, "popped view model must deallocate")

        // 2. The transport stays OPEN on the shared cached session.
        XCTAssertEqual(conversationSession.status, .online,
                       "shared transport must still be open after pop")

        // 3. RE-ENTRY: a brand-new view model over the SAME cached session —
        //    start() re-runs connect (idempotent no-op), resumes, subscribes.
        let vm2 = makeVM()
        await vm2.start()
        XCTAssertEqual(vm2.phase, .ready,
                       "re-entry must reach ready — no 'connect() from open'")
        XCTAssertEqual(vm2.errorMessage, nil)
        XCTAssertEqual(server.connectionCount, 1,
                       "re-entry must NOT open a second gateway connection")

        // 4. Send on the re-entered conversation — the reply must stream into
        //    the NEW view model over the fresh fan-out pipe.
        await vm2.send("second hello")
        try await waitUntil(
            "vm2 reply streamed after re-entry",
            { vm2.transcript.last?.text == "Re entry OK" && vm2.phase == .ready },
            context: viewModelContext(vm2)
        )
        XCTAssertEqual(server.connectionCount, 1,
                       "send after re-entry must not open a second connection")
        XCTAssertEqual(vm2.errorMessage, nil,
                       "no 'connect() from open' may surface in-conversation")

        await vm2.teardown()
        await conversationSession.disconnect()
    }

    // MARK: - Helper

    private func waitUntil(
        _ name: String,
        _ condition: @escaping @MainActor () -> Bool,
        timeout: Duration = .seconds(4),
        context: @escaping @MainActor () async -> String = { "" }
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        let detail = await context()
        XCTFail("\(name): condition not met within \(timeout)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private func viewModelContext(_ viewModel: ConversationViewModel) -> @MainActor () async -> String {
        { "phase=\(viewModel.phase) replayNotice=\(viewModel.replayNotice ?? "nil") rows=\(viewModel.transcript.map { "\($0.kind):\($0.text)\($0.isStreaming ? "*" : "")" })" }
    }
}

/// Minimal ticket minter (no network) for the fixture transport.
private struct StaticTicketMinter: WSTicketMinting {
    let ticket: WSTicket
    func mintTicket() async throws -> WSTicket { ticket }
}
