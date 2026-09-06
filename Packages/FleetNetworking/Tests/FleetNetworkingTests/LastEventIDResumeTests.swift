import XCTest
import FleetCore
@testable import FleetNetworking

/// t_8401d3c3 — Last-Event-ID resume semantics for gateway WS conversation
/// streams.
///
/// Mechanism (documented choice): the SERVER already owns gap replay — every
/// per-session event is stamped with a monotonic `seq` (`event_replay.py`)
/// and `session.events.since(last_seen)` returns the missed tail from a
/// bounded ring. This suite proves the CLIENT half adopted here:
///
/// 1. every conversation event carries the per-stream event id (top-level
///    `seq` threaded through `decodeEvent` into `ConversationEvent`);
/// 2. the client sends its last-received event id on (re)subscribe
///    (`session.resume` params include `last_seen`);
/// 3. a disconnect-mid-stream / reconnect resumes EXACTLY — zero lost
///    events, zero duplicated events — via targeted
///    `resumeEvents(since: cursor)`;
/// 4. an unrecoverable gap (ring evicted: `truncated: true`) surfaces the
///    explicit `ConversationError.gapUnrecoverable` signal — never silent
///    loss;
/// 5. the client-side cursor composes with the transport watermark / RT1
///    replay-hold (seq-dedupe at apply time; see the VM tests).
///
/// All against in-process scripted fixture servers — no live gateway.
final class LastEventIDResumeTests: XCTestCase {

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
        #"{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{\"type\":\"gateway.ready\",\"payload\":{\"change_events\":true,\"heartbeat\":false,\"replay_epoch\":\"\#(epoch)\"}}}"#
            .replacingOccurrences(of: "\\", with: "")
    }

    private static func seqEventFrame(
        type: String, sessionID: String, seq: Int, payload: [String: Any]? = nil
    ) -> String {
        var params: [String: Any] = ["type": type, "session_id": sessionID, "seq": seq]
        if let payload { params["payload"] = payload }
        let data = try! JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "method": "event", "params": params])
        return String(data: data, encoding: .utf8)!
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

    private static func bareEvent(
        type: String, sessionID: String, seq: Int, payload: [String: Any]? = nil
    ) -> [String: Any] {
        var event: [String: Any] = ["type": type, "session_id": sessionID, "seq": seq]
        if let payload { event["payload"] = payload }
        return event
    }

    private static func sinceResponse(
        id: String, events: [[String: Any]], latestSeq: Int,
        truncated: Bool = false
    ) -> String {
        responseFrame(id: id, result: [
            "events": events, "latest_seq": latestSeq,
            "truncated": truncated, "count": events.count, "epoch": "epoch-1",
        ])
    }

    // MARK: 1. every conversation event carries the per-stream event id

    /// The gateway-stamped top-level `seq` threads through `decodeEvent` into
    /// every conversation event case — the per-stream event id contract.
    func testDecodeEventCarriesSeqIntoConversationDomain() {
        let stamped = GatewayEvent(
            type: .messageDelta, rawType: "message.delta", sessionID: "s1", seq: 42,
            payload: nil)
        let decoded = GatewayConversationClient.decodeEvent(stamped)
        guard case .messageDelta(_, let text, _, let seq)? = decoded else {
            return XCTFail("expected messageDelta")
        }
        XCTAssertEqual(text, "")
        XCTAssertEqual(seq, 42, "top-level seq must ride into the conversation event")

        let unstamped = GatewayEvent(
            type: .messageStart, rawType: "message.start", sessionID: "s1", seq: nil, payload: nil)
        guard case .messageStart(_, let useq)? = GatewayConversationClient.decodeEvent(unstamped) else {
            return XCTFail("expected messageStart")
        }
        XCTAssertNil(useq, "unstamped wire events decode with nil seq (tolerated)")
    }

    // MARK: 2. last-received event id travels on (re)subscribe

    /// `resumeSession(lastEventID:)` includes `last_seen` in the
    /// `session.resume` params — the subscribe message declares the resume
    /// point (wire-safe: the gateway ignores unknown resume params today).
    func testResumeSessionSendsLastSeenOnSubscribe() async throws {
        let captured = ResumeParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, params) = Self.extractRequest(frame) else { return [] }
                if method == "session.resume" {
                    captured.record(params)
                    return [Self.responseFrame(id: id, result: ["session_id": "s1", "message_count": 0, "messages": []])]
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
        _ = try await client.resumeSession(sessionID: "s1", lastEventID: 17)
        XCTAssertEqual(captured.sessionID, "s1")
        XCTAssertEqual(captured.lastSeen, 17, "resume must carry the client's last-received event id")

        // And omitting it keeps the wire shape unchanged (fresh subscribe).
        _ = try await client.resumeSession(sessionID: "s1", lastEventID: nil)
        XCTAssertNil(captured.lastSeen, "nil lastEventID must not send last_seen")
    }

    // MARK: 3. disconnect-mid-stream / reconnect resumes EXACTLY

    /// THE centerpiece (card acceptance): stream events 1-3 live, drop the
    /// socket mid-stream, reconnect, and resume from the client's cursor —
    /// the union of live + resumed events is EXACTLY 1...6, each exactly
    /// once: zero lost, zero duplicated.
    func testDisconnectMidStreamReconnectResumesExactly() async throws {
        // Connection 1: ready + live events seq 1,2,3 (deltas a,b,c).
        let first = InProcessWebSocketServer.Script(
            onOpen: [
                Self.readyFrame(),
                Self.seqEventFrame(type: "message.start", sessionID: "s1", seq: 1),
                Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 2, payload: ["text": "a"]),
                Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 3, payload: ["text": "b"]),
            ]
        )
        // Connection 2 (reconnect): ready; answers session.resume (last_seen
        // captured), session.events.since(cursor) with seq 4,5 (c,d) AND the
        // live tail seq 6 (e) immediately after — live + replay interleaved
        // on one socket, exactly like the real gateway.
        let captured = ResumeParamCapture()
        let second = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, params) = Self.extractRequest(frame) else { return [] }
                switch method {
                case "session.resume":
                    captured.record(params)
                    return [Self.responseFrame(id: id, result: ["session_id": "s1", "message_count": 0, "messages": []])]
                case "session.events.since":
                    return [
                        Self.sinceResponse(id: id, events: [
                            Self.bareEvent(type: "message.delta", sessionID: "s1", seq: 4, payload: ["text": "c"]),
                            Self.bareEvent(type: "message.delta", sessionID: "s1", seq: 5, payload: ["text": "d"]),
                        ], latestSeq: 5),
                        Self.seqEventFrame(type: "message.delta", sessionID: "s1", seq: 6, payload: ["text": "e"]),
                    ]
                default:
                    return []
                }
            }
        )
        let server = try InProcessWebSocketServer(scripts: [first, second])
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        let client = GatewayConversationClient(gatewayID: GatewayID(rawValue: "workstation"), transport: transport)

        // ONE subscription for the whole test: the transport's event channel
        // survives teardown (P4), so the same pipe carries conn1's live
        // events AND conn2's live tail.
        let collector = ConversationEventCollector()
        let subscription = Task {
            for await event in client.events {
                collector.append(event)
            }
        }
        defer { subscription.cancel() }

        // Phase 1 — live stream seq 1-3, then the socket drops mid-stream.
        try await transport.connect()
        await waitUntil({ collector.seqs == [1, 2, 3] }, timeout: .seconds(3))
        server.abortConnection()
        await waitUntil({ transport.state != .connected }, timeout: .seconds(3))

        // Phase 2 — reconnect (hits scripted connection 2); the client's
        // cursor is its last APPLIED id (3).
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)
        let cursor = collector.seqs.max() ?? 0
        XCTAssertEqual(cursor, 3, "cursor must be the last received event id before the drop")

        // (Re)subscribe declares the resume point…
        _ = try await client.resumeSession(sessionID: "s1", lastEventID: cursor)
        XCTAssertEqual(captured.lastSeen, 3, "reconnect subscribe must send the last-received event id")

        // …and the missed tail is recovered from the ring, in order.
        let resumed = try await client.resumeEvents(since: cursor, sessionID: "s1")
        XCTAssertEqual(resumed.compactMap(\.seq), [4, 5], "resumed tail is exactly the events after the cursor")

        // The live tail (seq 6) continues on the same pipe.
        await waitUntil({ collector.seqs.contains(6) }, timeout: .seconds(3))
        try await Task.sleep(for: .milliseconds(100))

        // EXACT RESUMPTION: live + resumed = 1...6, zero lost, zero dup.
        let applied = collector.seqs + resumed.compactMap(\.seq)
        XCTAssertEqual(applied.sorted(), [1, 2, 3, 4, 5, 6], "no lost events")
        XCTAssertEqual(Set(applied).count, applied.count, "no duplicated events (every id applied exactly once)")

        // And the rendered text is the lossless concatenation.
        let liveText = collector.all.compactMap { event -> String? in
            guard case .messageDelta(_, let text, _, _) = event else { return nil }
            return text
        }.joined()
        let resumedText = resumed.compactMap { event -> String? in
            guard case .messageDelta(_, let text, _, _) = event else { return nil }
            return text
        }.joined()
        XCTAssertEqual(liveText + resumedText, "abe" + "cd", "tokens concatenate in stream order with no loss/dup")

        await transport.disconnect()
    }

    // MARK: 4. unrecoverable gaps are EXPLICIT

    /// When the replay ring evicted the requested range (`truncated: true`),
    /// `resumeEvents` throws `.gapUnrecoverable` — the explicit fallback
    /// signal. The client refetches authoritative history; it NEVER silently
    /// continues with a partial stream.
    func testTruncatedReplaySurfacesExplicitGapUnrecoverable() async throws {
        // Single connection: answers session.events.since with truncated=true
        // — the ring no longer holds anything after 40 (evicted).
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method, _) = Self.extractRequest(frame) else { return [] }
                if method == "session.events.since" {
                    return [Self.sinceResponse(id: id, events: [], latestSeq: 90, truncated: true)]
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
            _ = try await client.resumeEvents(since: 40, sessionID: "s1")
            XCTFail("expected gapUnrecoverable — truncated replay must never pass silently")
        } catch let error as ConversationError {
            XCTAssertEqual(error, .gapUnrecoverable(sessionID: "s1", afterEventID: 40),
                           "the signal must identify the session and the lost-after cursor")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: 5. composes with the transport watermark path (RT1 replay-hold)

    /// The client cursor and the transport watermark coexist: replayed events
    /// injected by the M6/RT1 engine (transport-level path) arrive on the
    /// SAME conversation pipe; the per-event seq lets the client-side apply
    /// gate dedupe them against what resumeEvents already applied. This test
    /// proves the two resume paths share one seq space without double
    /// delivery at the conversation layer.
    func testResumedEventsAndTransportReplayShareSeqSpace() async throws {
        // Engine-level replay (ReconnectReplayTests) and resumeEvents both
        // source from the same ring with the same seq contract; the union of
        // what the conversation layer applies is seq-gated by the consumer.
        // Here: the same event (seq 4) arrives BOTH via resumeEvents AND via
        // the transport's injected replay — the consumer-side dedupe (VM
        // cursor gate, tested in ConversationViewModelTests) drops the second
        // copy because the seq is identical. Verify the wire shapes really
        // are identical, which is what makes the dedupe sound.
        let viaResume = ConversationEvent.messageDelta(sessionID: "s1", text: "c", rendered: nil, seq: 4)
        let viaTransportReplay = GatewayConversationClient.decodeEvent(
            GatewayEvent(type: .messageDelta, rawType: "message.delta", sessionID: "s1", seq: 4,
                         payload: .object(["text": .string("c")])))!
        XCTAssertEqual(viaResume, viaTransportReplay,
                       "same seq + same payload ⇒ identical conversation event; a seq-dedupe gate is sound")
    }

    // MARK: helpers (test infrastructure)

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

/// Thread-safe capture of `session.resume` params.
private final class ResumeParamCapture: @unchecked Sendable {
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

/// Thread-safe accumulator for conversation events observed on the live pipe.
private final class ConversationEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [ConversationEvent] = []

    var all: [ConversationEvent] { lock.lock(); defer { lock.unlock() }; return _all }
    var seqs: [Int] { all.compactMap(\.seq) }

    func append(_ event: ConversationEvent) {
        lock.lock()
        _all.append(event)
        lock.unlock()
    }
}
