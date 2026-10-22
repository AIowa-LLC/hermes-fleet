import XCTest
import FleetCore
@testable import FleetNetworking

/// P4 (M6) — reconnect + replay suite (spec §36 "Reconnect tests").
///
/// Simulates: socket close, timeout, network switch, duplicate replay, event
/// gap, replay truncation, gateway epoch change — against in-process fixture
/// servers with per-connection scripting (connection 1 streams events, the
/// reconnect connection answers `session.events.since`). No live gateway is
/// touched.
///
/// The first test is the M1 P4 residual regression: the transport was
/// single-shot (ready handshake channel finished at first teardown), so a
/// reconnect after clean disconnect failed readyTimeout. That is now in scope
/// and must pass before any replay can run.
final class ReconnectReplayTests: XCTestCase {

    // MARK: helpers

    private func makeTransport(
        serverPort: UInt16,
        requestTimeout: Duration = .seconds(3),
        connectTimeout: Duration = .seconds(10)
    ) -> GatewayWebSocketTransport {
        let base = URL(string: "http://127.0.0.1:\(serverPort)")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30),
            inboundDeadline: .seconds(30),
            connectTimeout: connectTimeout,
            requestTimeout: requestTimeout
        )
        return GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: config
        )
    }

    private static func readyFrame(epoch: String = "epoch-1") -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true,"heartbeat":false,"replay_epoch":"\#(epoch)"}}}"#
    }

    /// A server→client event frame carrying a per-session `seq` (the replay
    /// watermark signal stamped by `event_replay.py`).
    private static func seqEventFrame(
        type: String, sessionID: String, seq: Int, payload: [String: Any]? = nil
    ) -> String {
        var params: [String: Any] = ["type": type, "session_id": sessionID, "seq": seq]
        if let payload { params["payload"] = payload }
        let data = try! JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "method": "event", "params": params])
        return String(data: data, encoding: .utf8)!
    }

    private static func extractRequest(_ frame: String) -> (id: String, method: String)? {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String else { return nil }
        return (id, method)
    }

    private static func responseFrame(id: String, result: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        return String(data: data, encoding: .utf8)!
    }

    /// A bare replay event object (`session.events.since` returns each frame's
    /// `params` dict — top-level type/session_id/seq/payload).
    private static func bareEvent(
        type: String, sessionID: String, seq: Int, payload: [String: Any]? = nil
    ) -> [String: Any] {
        var event: [String: Any] = ["type": type, "session_id": sessionID, "seq": seq]
        if let payload { event["payload"] = payload }
        return event
    }

    private static func sinceResponse(
        id: String, events: [[String: Any]], latestSeq: Int,
        truncated: Bool = false, epoch: String = "epoch-1"
    ) -> String {
        responseFrame(id: id, result: [
            "events": events, "latest_seq": latestSeq,
            "truncated": truncated, "count": events.count, "epoch": epoch,
        ])
    }

    // MARK: M1 P4 residual — the single-shot ready handshake fix

    /// REGRESSION (M1 P4 residual, now in M6 scope): a reconnect after a clean
    /// disconnect must NOT fail readyTimeout. The transport used to finish the
    /// ready channel at teardown, so the second connect() iterated a finished
    /// stream. Now the channel is re-created per connect.
    func testReconnectAfterCleanDisconnectSucceeds() async throws {
        let server = try InProcessWebSocketServer(script: .init(onOpen: [Self.readyFrame()]))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        await transport.disconnect()
        XCTAssertEqual(transport.state, .disconnected)

        // Reconnect: this used to throw readyTimeout.
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected, "reconnect after clean disconnect must succeed")
        XCTAssertEqual(server.connectionCount, 2, "reconnect must open a fresh connection")
        await transport.disconnect()
    }

    /// The snapshot and hold are one actor operation: once the returned
    /// watermark is 3, a live seq 4 is parked. Replaying seq 4 advances the
    /// watermark first, so flushing the held copy emits it exactly once.
    func testReplayHoldAtomicallySnapshotsAndDedupesConcurrentLiveEvent() async throws {
        let server = try InProcessWebSocketServer(script: .init(onOpen: [
            Self.readyFrame(),
            Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 3),
        ]))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        await waitUntil({ await transport.watermark(for: "s1") == 3 }, timeout: .seconds(3))

        let collector = GatewayEventCollector()
        let eventStream = transport.subscribeToEvents()
        let subscription = Task {
            for await event in eventStream { collector.append(event) }
        }
        let snapshot = await transport.beginReplayHold()
        XCTAssertEqual(snapshot["s1"], 3)

        server.sendText(Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 4))
        await waitUntil({ await transport.replayHoldBufferedBytes > 0 }, timeout: .seconds(3))
        let heldWatermark = await transport.watermark(for: "s1")
        XCTAssertEqual(heldWatermark, 3, "held live frames must not advance the snapshot")

        let replayEvent = GatewayEvent(
            type: .messageDelta, rawType: "message.delta", sessionID: "s1", seq: 4,
            payload: .object(["text": .string("same event")]))
        await transport.injectReplayedEvents([replayEvent])
        await transport.endReplayHold()
        await waitUntil({ collector.all.filter { $0.seq == 4 }.count == 1 }, timeout: .seconds(3))
        XCTAssertEqual(collector.all.filter { $0.seq == 4 }.count, 1)
        let watermark = await transport.watermark(for: "s1")
        XCTAssertEqual(watermark, 4)

        subscription.cancel()
        await transport.disconnect()
    }

    // MARK: socket close / network switch

    /// Spec §36 "socket close" + "network switch": an abnormal drop (no close
    /// frame) maps to `.abnormalClosure`, the policy says reconnect, and the
    /// transport recovers by reconnecting (fresh connection) without crashing.
    func testReconnectAfterAbnormalClosureRecovers() async throws {
        let server = try InProcessWebSocketServer(script: .init(onOpen: [Self.readyFrame()]))
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        // Simulate network loss: server aborts without a close frame.
        server.abortConnection()

        let deadline = Date().addingTimeInterval(3)
        while transport.state == .connected && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .failed(let detail) = transport.state else {
            return XCTFail("expected failed state after abort, got \(transport.state)")
        }
        XCTAssertTrue(detail.contains("abnormal"), "expected abnormal mapping, got \(detail)")
        let reason = await transport.lastDisconnectReason
        XCTAssertEqual(reason, .abnormalClosure)
        XCTAssertEqual(ReconnectPolicy.decision(for: .abnormalClosure), .reconnect)

        // Recover: reconnect from the error state succeeds.
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)
        XCTAssertEqual(server.connectionCount, 2)
        await transport.disconnect()
    }

    /// Spec §36 "timeout": a connect that times out (server never sends
    /// gateway.ready) leaves the transport reconnectable — the retry opens a
    /// fresh connection and succeeds. Also verifies the ready channel was
    /// re-created even after a failed handshake.
    func testReconnectAfterReadyTimeoutRetries() async throws {
        // Connection 1: silent (never sends ready). Connection 2: healthy.
        let silent = InProcessWebSocketServer.Script(onOpen: []) // no ready
        let healthy = InProcessWebSocketServer.Script(onOpen: [Self.readyFrame()])
        let server = try InProcessWebSocketServer(scripts: [silent, healthy])
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(
            serverPort: server.listeningPort, connectTimeout: .milliseconds(400))

        do {
            try await transport.connect()
            XCTFail("expected readyTimeout on silent server")
        } catch let error as TransportError {
            XCTAssertEqual(error, .readyTimeout)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(server.connectionCount, 1)

        // Retry hits connection 2 (healthy) — must succeed.
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)
        XCTAssertEqual(server.connectionCount, 2)
        await transport.disconnect()
    }

    // MARK: ReconnectPolicy (close-code → decision)

    func testReconnectPolicyMapsCloseCodes() {
        XCTAssertEqual(ReconnectPolicy.decision(for: .abnormalClosure), .reconnect)
        XCTAssertEqual(ReconnectPolicy.decision(for: .goingAway), .reconnect)
        XCTAssertEqual(ReconnectPolicy.decision(for: .serverError), .reconnect)
        XCTAssertEqual(ReconnectPolicy.decision(for: .tlsHandshakeFailure), .reconnect)
        XCTAssertEqual(ReconnectPolicy.decision(for: .unknown(code: 1002, detail: "x")), .reconnect)
        // 4401 — NEVER silent retry.
        XCTAssertEqual(ReconnectPolicy.decision(for: .reauthenticationRequired), .reauthenticate)
        // Clean close / unsupported surfaces — do not auto-reconnect.
        XCTAssertEqual(ReconnectPolicy.decision(for: .normalClosure), .doNotReconnect)
        XCTAssertEqual(ReconnectPolicy.decision(for: .invalidChannel), .doNotReconnect)
        XCTAssertEqual(ReconnectPolicy.decision(for: .hostMismatch), .doNotReconnect)
        XCTAssertEqual(ReconnectPolicy.decision(for: .chatDisabled), .doNotReconnect)
        XCTAssertEqual(ReconnectPolicy.decision(for: .peerNotAllowed), .doNotReconnect)
    }

    // MARK: GatewayReplayClient decode

    func testReplayClientDecodesBareEventBatch() throws {
        let result: JSONValue = .object([
            "events": .array([
                .object([
                    "type": .string("message.delta"),
                    "session_id": .string("s1"),
                    "seq": .number(4),
                    "payload": .object(["text": .string("b")]),
                ]),
                .object([
                    "type": .string("message.delta"),
                    "session_id": .string("s1"),
                    "seq": .number(5),
                    "payload": .object(["text": .string("c")]),
                ]),
            ]),
            "latest_seq": .number(5),
            "truncated": .bool(false),
            "count": .number(2),
            "epoch": .string("epoch-1"),
            "open_requests": .array([.object([
                "id": .string("server-request-1"),
                "method": .string("approval.request"),
            ])]),
        ])
        let batch = try GatewayReplayClient.decode(sessionID: "s1", result)
        XCTAssertEqual(batch.sessionID, "s1")
        XCTAssertEqual(batch.latestSeq, 5)
        XCTAssertFalse(batch.truncated)
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(batch.epoch, "epoch-1")
        XCTAssertEqual(batch.events.count, 2)
        XCTAssertEqual(batch.events[0].type, GatewayEvent.EventType.messageDelta)
        XCTAssertEqual(batch.events[0].seq, 4)
        XCTAssertEqual(batch.events[0].sessionID, "s1")
        XCTAssertEqual(batch.events[1].seq, 5)
        XCTAssertEqual(batch.openRequests, result["open_requests"], "preserve open_requests without rewriting it")
    }

    func testReplayClientDecodesTruncatedBatch() throws {
        let result: JSONValue = .object([
            "events": .array([]),
            "latest_seq": .number(50),
            "truncated": .bool(true),
            "count": .number(0),
            "epoch": .string("epoch-1"),
        ])
        let batch = try GatewayReplayClient.decode(sessionID: "s1", result)
        XCTAssertTrue(batch.truncated)
        XCTAssertEqual(batch.latestSeq, 50)
        XCTAssertTrue(batch.events.isEmpty)
    }

    func testReplayClientRejectsMalformedEnvelopesAndEvents() {
        func event(_ sessionID: String = "s1", _ seq: JSONValue = .number(4)) -> JSONValue {
            .object([
                "type": .string("message.delta"),
                "session_id": .string(sessionID),
                "seq": seq,
            ])
        }
        func envelope(
            _ events: JSONValue,
            latest: JSONValue = .number(5),
            truncated: JSONValue = .bool(false),
            count: JSONValue = .number(1)
        ) -> JSONValue {
            .object(["events": events, "latest_seq": latest, "truncated": truncated, "count": count])
        }

        let cases: [(String, JSONValue)] = [
            ("missing events", .object(["latest_seq": .number(5), "truncated": .bool(false), "count": .number(0)])),
            ("events is not an array", envelope(.string("bad"))),
            ("malformed event element", envelope(.array([.string("bad")]))),
            ("foreign session", envelope(.array([event("s2")]))),
            ("negative seq", envelope(.array([event("s1", .number(-1))]))),
            ("fractional seq", envelope(.array([event("s1", .number(4.5))]))),
            ("duplicate seq", envelope(.array([event("s1", .number(4)), event("s1", .number(4))]), latest: .number(4), count: .number(2))),
            ("decreasing seq", envelope(.array([event("s1", .number(5)), event("s1", .number(4))]), latest: .number(5), count: .number(2))),
            ("seq at last_seen", envelope(.array([event("s1", .number(3))]), latest: .number(3))),
            ("count mismatch", envelope(.array([event()]), count: .number(0))),
            ("latest below max seq", envelope(.array([event()]), latest: .number(3))),
            ("latest does not reach complete batch", envelope(.array([event()]), latest: .number(5))),
            ("missing truncation flag", .object(["events": .array([]), "latest_seq": .number(3), "count": .number(0)])),
            ("missing latest_seq", .object(["events": .array([]), "truncated": .bool(false), "count": .number(0)])),
            ("missing count", .object(["events": .array([]), "latest_seq": .number(3), "truncated": .bool(false)])),
            ("fractional latest_seq", envelope(.array([event()]), latest: .number(5.5))),
        ]

        for (name, result) in cases {
            XCTAssertThrowsError(
                try GatewayReplayClient.decode(sessionID: "s1", result, lastSeen: 3),
                "expected rejection for \(name)"
            )
        }
        XCTAssertThrowsError(
            try GatewayReplayClient.decode(
                sessionID: "s1", envelope(.array([]), latest: .number(0), count: .number(0)), lastSeen: -1),
            "negative last_seen must fail before replay"
        )
    }

    func testTruncatedReplayMayCarryPartialEventsAndRetainsOpenRequests() throws {
        let openRequests: JSONValue = .array([.object(["id": .string("opaque-id"), "method": .string("approval.request")])])
        let result: JSONValue = .object([
            "events": .array([.object([
                "type": .string("message.delta"), "session_id": .string("s1"), "seq": .number(4),
            ])]),
            "latest_seq": .number(10),
            "truncated": .bool(true),
            "count": .number(10),
            "open_requests": openRequests,
        ])
        let batch = try GatewayReplayClient.decode(sessionID: "s1", result, lastSeen: 3)
        XCTAssertTrue(batch.truncated)
        XCTAssertEqual(batch.events.count, 1)
        XCTAssertEqual(batch.count, 10)
        XCTAssertEqual(batch.openRequests, openRequests)
    }

    func testReplayClientSendsSessionIDAndLastSeen() async throws {
        let captured = ReplayParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "session.events.since",
                   let data = frame.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    captured.record(obj["params"] as? [String: Any] ?? [:])
                }
                return [Self.responseFrame(id: id, result: [
                    "events": [], "latest_seq": 3, "truncated": false, "count": 0, "epoch": "epoch-1",
                ])]
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayReplayClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        _ = try await client.fetchEventsSince(sessionID: "s1", lastSeen: 3)
        XCTAssertEqual(captured.sessionID, "s1")
        XCTAssertEqual(captured.lastSeen, 3)
    }

    // MARK: full reconnect + replay flow

    /// spec §9.2-§9.4: epoch matches → `session.events.since(lastSeen)`,
    /// dedupe overlap, apply in order. Connection 1 streams events (building
    /// watermarks); the reconnect connection answers since with seq 4,5.
    func testReconnectReplaysEventsSinceWatermarkInOrder() async throws {
        // Connection 1: ready + three streamed events (watermark s1 → 3).
        let first = InProcessWebSocketServer.Script(
            onOpen: [
                Self.readyFrame(),
                Self.seqEventFrame(type: "message.start", sessionID: "s1", seq: 1),
                Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 2, payload: ["text": "a"]),
                Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 3, payload: ["text": "b"]),
            ],
            onText: { frame in
                if frame.contains("gateway.ping") {
                    guard let id = Self.extractRequest(frame)?.id else { return [] }
                    return [Self.responseFrame(id: id, result: ["ok": true])]
                }
                return []
            }
        )
        // Connection 2 (reconnect): the live seq 4 races the replay response,
        // which also contains seq 4. The hold must forward exactly one copy.
        let second = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "session.events.since" {
                    return [Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 4), Self.sinceResponse(
                        id: id,
                        events: [
                            Self.bareEvent(type: "message.delta", sessionID: "s1", seq: 4, payload: ["text": "c"]),
                            Self.bareEvent(type: "message.delta", sessionID: "s1", seq: 5, payload: ["text": "d"]),
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
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        // Wait for the streamed events to advance the watermark.
        await waitUntil({ await transport.watermark(for: "s1") == 3 }, timeout: .seconds(3))
        let wmBefore = await transport.watermark(for: "s1")
        XCTAssertEqual(wmBefore, 3)

        let engine = GatewayReplayEngine(
            gatewayID: GatewayID(rawValue: "workstation"),
            transport: transport,
            history: StubHistoryProvider()
        )
        // First connect: adopt epoch, nothing to replay yet.
        let firstOutcomes = try await engine.replayAfterReconnect()
        XCTAssertEqual(firstOutcomes, [.nothingToReplay])

        // Subscribe to the live event channel to observe replayed injection.
        let collector = GatewayEventCollector()
        // Registration is synchronous, so create the bounded fan-out stream
        // before replay can inject. Starting the task alone does not guarantee
        // it has run far enough to register the subscription.
        let eventStream = transport.subscribeToEvents()
        let subscription = Task {
            for await event in eventStream {
                collector.append(event)
            }
        }

        // Drop, reconnect, replay.
        server.abortConnection()
        await waitUntil({ transport.state != .connected }, timeout: .seconds(3))
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)

        let outcomes = try await engine.replayAfterReconnect()
        XCTAssertEqual(outcomes, [.replayed(sessionID: "s1", count: 2)])

        // Watermark advanced to latest_seq.
        let wmAfter = await transport.watermark(for: "s1")
        XCTAssertEqual(wmAfter, 5)

        // Cancellation finishes the bounded queue and discards any unread
        // backlog. Wait until the collector has consumed both replay events
        // before cancelling, so this assertion tests replay rather than task
        // scheduling.
        await waitUntil({ collector.all.filter { ($0.seq ?? 0) > 3 }.count == 2 }, timeout: .seconds(3))
        subscription.cancel()

        // The two replayed events reached the live channel, in order. P0-7
        // fan-out semantics: the channel delivers to LIVE subscribers only —
        // seq 1-3 were streamed before this subscription attached, so they
        // must be entirely absent (and the replay injection must not
        // re-deliver them either).
        let replayed = collector.all.filter { $0.seq ?? 0 > 3 }
        XCTAssertEqual(replayed.map(\.seq), [4, 5])
        let seq1to3 = collector.all.filter { ($0.seq ?? 0) >= 1 && ($0.seq ?? 0) <= 3 }
        XCTAssertEqual(seq1to3.count, 0,
                       "pre-subscription events must not be re-delivered (replay never duplicates)")

        await transport.disconnect()
    }

    func testCancellingReplayEndsHoldAndForwardsSubsequentLiveEvent() async throws {
        let first = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame(), Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 3)]
        )
        let captured = ReplayParamCapture()
        let second = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (_, method) = Self.extractRequest(frame), method == "session.events.since",
                      let data = frame.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return [] }
                captured.record(object["params"] as? [String: Any] ?? [:])
                return [] // hold the RPC open until the replay task is cancelled
            }
        )
        let server = try InProcessWebSocketServer(scripts: [first, second])
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        await waitUntil({ await transport.watermark(for: "s1") == 3 }, timeout: .seconds(3))
        let engine = GatewayReplayEngine(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport, history: StubHistoryProvider())
        _ = try await engine.replayAfterReconnect()

        server.abortConnection()
        await waitUntil({ transport.state != .connected }, timeout: .seconds(3))
        try await transport.connect()

        let collector = GatewayEventCollector()
        let eventStream = transport.subscribeToEvents()
        let subscription = Task {
            for await event in eventStream { collector.append(event) }
        }
        let replay = Task { try await engine.replayAfterReconnect() }
        await waitUntil({ captured.sessionID == "s1" }, timeout: .seconds(3))
        replay.cancel()
        do {
            _ = try await replay.value
            XCTFail("cancelling an in-flight replay should propagate cancellation")
        } catch is CancellationError {
            // Expected: cancellation removes the pending RPC and releases the hold.
        }

        server.sendText(Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 4))
        await waitUntil({ collector.all.filter { $0.seq == 4 }.count == 1 }, timeout: .seconds(3))
        XCTAssertEqual(collector.all.filter { $0.seq == 4 }.count, 1)
        let finalWatermark = await transport.watermark(for: "s1")
        XCTAssertEqual(finalWatermark, 4)
        subscription.cancel()
        await transport.disconnect()
    }

    /// Strict replay rejects an overlapping batch as a whole, refetches
    /// authoritative history, and neither injects the partial batch nor
    /// advances its watermark.
    func testInvalidReplayOverlapRefetchesHistoryWithoutAdvancingWatermark() async throws {
        let first = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame(), Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 1)]
        )
        // since returns seq 1 at/below the watermark plus seq 2. It is not a
        // coherent complete batch, so neither event may be injected.
        let second = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "session.events.since" {
                    return [Self.sinceResponse(
                        id: id,
                        events: [
                            Self.bareEvent(type: "message.delta", sessionID: "s1", seq: 1),
                            Self.bareEvent(type: "message.delta", sessionID: "s1", seq: 2),
                        ],
                        latestSeq: 2)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(scripts: [first, second])
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        await waitUntil({ await transport.watermark(for: "s1") == 1 }, timeout: .seconds(3))

        let historyStub = StubHistoryProvider()
        let engine = GatewayReplayEngine(
            gatewayID: GatewayID(rawValue: "workstation"),
            transport: transport,
            history: historyStub
        )
        _ = try await engine.replayAfterReconnect() // first connect: adopt

        server.abortConnection()
        await waitUntil({ transport.state != .connected }, timeout: .seconds(3))
        try await transport.connect()

        let collector = GatewayEventCollector()
        let eventStream = transport.subscribeToEvents()
        let subscription = Task {
            for await event in eventStream { collector.append(event) }
        }
        let outcomes = try await engine.replayAfterReconnect()
        guard case .failed(let failedSession, let detail)? = outcomes.first else {
            return XCTFail("malformed overlap must surface an explicit failed outcome: \(outcomes)")
        }
        XCTAssertEqual(failedSession, "s1")
        XCTAssertTrue(detail.contains("malformed replay payload"))
        XCTAssertTrue(historyStub.historyRequestedForS1, "invalid batches must trigger authoritative history refetch")
        subscription.cancel()

        XCTAssertTrue(collector.all.filter { $0.seq != nil }.isEmpty, "invalid replay events must not be forwarded")
        let watermark = await transport.watermark(for: "s1")
        XCTAssertEqual(watermark, 1, "validation failure must not advance the watermark")

        await transport.disconnect()
    }

    /// spec §9.5 + §36 "replay truncation": when the ring reports `truncated`,
    /// the engine refetches authoritative `session.history` instead of trusting
    /// a gap — and never invents the missing events.
    func testReplayTruncationRefetchesHistory() async throws {
        let first = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame(), Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 3)]
        )
        let historyStub = StubHistoryProvider()
        let second = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                switch method {
                case "session.events.since":
                    return [Self.sinceResponse(
                        id: id, events: [], latestSeq: 40, truncated: true)]
                case "session.history":
                    historyStub.noteHistoryRequested(sessionID: "s1")
                    return [Self.responseFrame(id: id, result: ["count": 2, "messages": [
                        ["role": "user", "text": "hi"], ["role": "assistant", "text": "hello"]]])]
                default:
                    return []
                }
            }
        )
        let server = try InProcessWebSocketServer(scripts: [first, second])
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        await waitUntil({ await transport.watermark(for: "s1") == 3 }, timeout: .seconds(3))

        let engine = GatewayReplayEngine(
            gatewayID: GatewayID(rawValue: "workstation"),
            transport: transport,
            history: historyStub
        )
        _ = try await engine.replayAfterReconnect() // first connect: adopt

        server.abortConnection()
        await waitUntil({ transport.state != .connected }, timeout: .seconds(3))
        try await transport.connect()

        let outcomes = try await engine.replayAfterReconnect()
        XCTAssertEqual(outcomes, [.truncated(sessionID: "s1")])
        XCTAssertTrue(historyStub.historyRequestedForS1, "truncation must trigger session.history refetch")
        // Watermark advanced to latest_seq so the next replay doesn't re-request the gap.
        let wmTrunc = await transport.watermark(for: "s1")
        XCTAssertEqual(wmTrunc, 40)

        await transport.disconnect()
    }

    /// A replay response larger than the client's bound is NOT injected: it is
    /// treated like a truncated ring (history refetch), so a runaway or hostile
    /// `session.events.since` cannot force unbounded client work.
    func testOversizedReplayBatchIsTreatedAsTruncated() async throws {
        let first = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame(), Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 3)]
        )
        let historyStub = StubHistoryProvider()
        let oversizedEvents = (0...GatewayReplayEngine.maxReplayBatchEvents).map {
            Self.bareEvent(type: "message.delta", sessionID: "s1", seq: 4 + $0)
        }
        // Pre-rendered (id-less) body: the closure may only capture Sendable values.
        let oversizedBody = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: [
                "events": oversizedEvents, "latest_seq": 5_004,
                "truncated": false, "count": oversizedEvents.count, "epoch": "epoch-1",
            ]), encoding: .utf8))
        let second = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                switch method {
                case "session.events.since":
                    return [#"{"jsonrpc":"2.0","id":"\#(id)","result":\#(oversizedBody)}"#]
                case "session.history":
                    historyStub.noteHistoryRequested(sessionID: "s1")
                    return [Self.responseFrame(id: id, result: ["count": 0, "messages": []])]
                default:
                    return []
                }
            }
        )
        let server = try InProcessWebSocketServer(scripts: [first, second])
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        await waitUntil({ await transport.watermark(for: "s1") == 3 }, timeout: .seconds(3))
        let engine = GatewayReplayEngine(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport, history: historyStub)
        _ = try await engine.replayAfterReconnect()

        server.abortConnection()
        await waitUntil({ transport.state != .connected }, timeout: .seconds(3))
        try await transport.connect()

        let outcomes = try await engine.replayAfterReconnect()
        XCTAssertEqual(outcomes, [.truncated(sessionID: "s1")])
        XCTAssertTrue(historyStub.historyRequestedForS1)
        await transport.disconnect()
    }

    /// spec §9.6 + §36 "gateway epoch change": a changed replay_epoch means the
    /// gateway restarted — stale seq assumptions are discarded and watermarks
    /// cleared (rehydrate from server state).
    func testReplayEpochChangeClearsWatermarks() async throws {
        let first = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame(epoch: "epoch-A"), Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 7)]
        )
        // Reconnect: NEW epoch (gateway restarted).
        let second = InProcessWebSocketServer.Script(onOpen: [Self.readyFrame(epoch: "epoch-B")])
        let server = try InProcessWebSocketServer(scripts: [first, second])
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        await waitUntil({ await transport.watermark(for: "s1") == 7 }, timeout: .seconds(3))

        let engine = GatewayReplayEngine(
            gatewayID: GatewayID(rawValue: "workstation"),
            transport: transport,
            history: StubHistoryProvider()
        )
        _ = try await engine.replayAfterReconnect() // adopt epoch-A

        server.abortConnection()
        await waitUntil({ transport.state != .connected }, timeout: .seconds(3))
        try await transport.connect()

        let outcomes = try await engine.replayAfterReconnect()
        XCTAssertEqual(outcomes, [.epochChanged(from: "epoch-A", to: "epoch-B")])
        let wmAfterEpoch = await transport.allWatermarks()
        XCTAssertTrue(wmAfterEpoch.isEmpty,
                      "epoch change must discard stale seq assumptions (clear watermarks)")
        await transport.disconnect()
    }

    /// spec §9 "never invent missing events": if since returns a gap (seq 5,7
    /// with 6 missing, truncated=false — a partial-server edge), the client
    /// applies exactly what it received in order and never fabricates 6.
    func testReplayNeverInventsMissingEvents() async throws {
        let first = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame(), Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 3)]
        )
        let second = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "session.events.since" {
                    return [Self.sinceResponse(
                        id: id,
                        events: [
                            Self.bareEvent(type: "message.delta", sessionID: "s1", seq: 5),
                            Self.bareEvent(type: "message.delta", sessionID: "s1", seq: 7),
                        ],
                        latestSeq: 7)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(scripts: [first, second])
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        await waitUntil({ await transport.watermark(for: "s1") == 3 }, timeout: .seconds(3))

        let engine = GatewayReplayEngine(
            gatewayID: GatewayID(rawValue: "workstation"),
            transport: transport,
            history: StubHistoryProvider()
        )
        _ = try await engine.replayAfterReconnect() // adopt

        server.abortConnection()
        await waitUntil({ transport.state != .connected }, timeout: .seconds(3))
        try await transport.connect()

        let collector = GatewayEventCollector()
        let eventStream = transport.subscribeToEvents()
        let subscription = Task {
            for await event in eventStream { collector.append(event) }
        }
        let outcomes = try await engine.replayAfterReconnect()
        XCTAssertEqual(outcomes, [.replayed(sessionID: "s1", count: 2)])
        await waitUntil({ collector.all.filter { ($0.seq ?? 0) > 3 }.count == 2 }, timeout: .seconds(3))
        subscription.cancel()

        let replayed = collector.all.filter { ($0.seq ?? 0) > 3 }
        XCTAssertEqual(replayed.map(\.seq), [5, 7], "apply exactly what was returned, in order — no invented 6")
        let finalWatermark = await transport.watermark(for: "s1")
        XCTAssertEqual(finalWatermark, 7)

        await transport.disconnect()
    }

    // MARK: not connected

    func testReplayAfterReconnectNotConnectedThrows() async {
        let transport = makeTransport(serverPort: 1) // never connected
        let engine = GatewayReplayEngine(
            gatewayID: GatewayID(rawValue: "workstation"),
            transport: transport,
            history: StubHistoryProvider()
        )
        do {
            _ = try await engine.replayAfterReconnect()
            XCTFail("expected notConnected")
        } catch let error as ReplayError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: helpers

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool,
        timeout: Duration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition not met within \(timeout)", file: file, line: line)
    }
}

/// Thread-safe capture of a `session.events.since` request's params.
private final class ReplayParamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _sessionID: String?
    private var _lastSeen: Int?

    var sessionID: String? { lock.lock(); defer { lock.unlock() }; return _sessionID }
    var lastSeen: Int? { lock.lock(); defer { lock.unlock() }; return _lastSeen }

    func record(_ params: [String: Any]) {
        lock.lock()
        _sessionID = params["session_id"] as? String
        _lastSeen = (params["last_seen"] as? NSNumber)?.intValue
        lock.unlock()
    }
}

/// Thread-safe accumulator for `GatewayEvent`s observed on the live channel.
private final class GatewayEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [GatewayEvent] = []
    var all: [GatewayEvent] { lock.lock(); defer { lock.unlock() }; return _all }
    func append(_ event: GatewayEvent) { lock.lock(); _all.append(event); lock.unlock() }
}

/// Minimal `SessionHistoryProviding` stub for replay tests (records history
/// refetch triggers; never touches the network itself).
private final class StubHistoryProvider: SessionHistoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _historyRequested = false

    var historyRequestedForS1: Bool {
        lock.lock(); defer { lock.unlock() }; return _historyRequested
    }

    func noteHistoryRequested(sessionID: String) {
        lock.lock()
        if sessionID == "s1" { _historyRequested = true }
        lock.unlock()
    }

    func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
        noteHistoryRequested(sessionID: sessionID)
        return SessionHistory(sessionID: sessionID, count: 0, messages: [])
    }

    func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
        SessionStatus.parse(output: "Hermes TUI Status\nSession ID: \(sessionID)\nAgent Running: No")
    }
}
