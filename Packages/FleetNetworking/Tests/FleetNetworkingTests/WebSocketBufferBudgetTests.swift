import XCTest
import Foundation
import FleetCore
@testable import FleetNetworking

/// Every WebSocket buffering path is bounded by count AND bytes, and an
/// overflow is never silent: it publishes an `EventGap`, marks sessions
/// incomplete, and (via the replay engine) turns into an authoritative-history
/// refetch. Network-free tests drive the transport through a scripted socket;
/// loopback tests use the real URLSession path.
final class WebSocketBufferBudgetTests: XCTestCase {

    // MARK: scripted socket

    final class ScriptedSession: WebSocketSession, @unchecked Sendable {
        private let continuation: AsyncStream<WebSocketMessage>.Continuation
        private let iteratorBox: IteratorBox
        final class IteratorBox: @unchecked Sendable {
            var iterator: AsyncStream<WebSocketMessage>.Iterator
            init(_ i: AsyncStream<WebSocketMessage>.Iterator) { iterator = i }
        }
        var lastCloseCode: Int? { nil }

        init() {
            let (stream, continuation) = AsyncStream<WebSocketMessage>.makeStream()
            self.continuation = continuation
            self.iteratorBox = IteratorBox(stream.makeAsyncIterator())
        }
        func push(_ text: String) { continuation.yield(.text(text)) }
        func open() async throws {}
        func receive() async throws -> WebSocketMessage {
            guard let next = await iteratorBox.iterator.next() else { throw CancellationError() }
            return next
        }
        func send(_ message: WebSocketMessage) async throws {}
        func close(code: Int, reason: String?) async { continuation.finish() }
    }

    struct ScriptedFactory: WebSocketSessionFactory {
        let session: ScriptedSession
        func makeSession(url: URL) -> any WebSocketSession { session }
    }

    private func makeTransport(_ session: ScriptedSession) -> GatewayWebSocketTransport {
        GatewayWebSocketTransport(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            sessionFactory: ScriptedFactory(session: session),
            configuration: TransportConfiguration(
                pingInterval: .seconds(30), inboundDeadline: .seconds(30),
                connectTimeout: .seconds(5), requestTimeout: .seconds(3)))
    }

    private static let ready = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true,"heartbeat":false,"replay_epoch":"epoch-1"}}}"#

    private static func event(session: String, seq: Int, text: String = "x") -> String {
        let params: [String: Any] = ["type": "message.delta", "session_id": session, "seq": seq,
                                     "payload": ["text": text]]
        let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "event", "params": params])
        return String(data: data, encoding: .utf8)!
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func collectGaps(_ transport: GatewayWebSocketTransport) -> GapCollector {
        let collector = GapCollector()
        let stream = transport.subscribeToGaps()
        collector.task = Task { for await gap in stream { collector.add(gap) } }
        return collector
    }

    final class GapCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var gaps: [EventGap] = []
        var task: Task<Void, Never>?
        func add(_ g: EventGap) { lock.lock(); gaps.append(g); lock.unlock() }
        var all: [EventGap] { lock.lock(); defer { lock.unlock() }; return gaps }
        deinit { task?.cancel() }
    }

    // MARK: queue primitives

    func testCountBoundEvictsOldestAndReportsThem() {
        let queue = BoundedQueue<Int>(maxCount: 3, maxBytes: 1_000)
        var evicted: [Int] = []
        for i in 0..<6 {
            evicted += queue.push(.init(value: i, bytes: 1, sessionID: "s\(i)")).map(\.value)
        }
        XCTAssertEqual(evicted, [0, 1, 2], "oldest first, none silently lost")
        XCTAssertEqual(queue.count, 3)
    }

    func testByteBoundEvictsOldestAndKeepsBytesUnderBudget() {
        let queue = BoundedQueue<Int>(maxCount: 1_000, maxBytes: 100)
        var evicted = 0
        for i in 0..<50 { evicted += queue.push(.init(value: i, bytes: 30, sessionID: nil)).count }
        XCTAssertLessThanOrEqual(queue.byteCount, 100)
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(evicted, 47)
    }

    func testPinnedEntriesAreNeverEvictedForOverflow() async {
        let queue = BoundedQueue<String>(maxCount: 3, maxBytes: 1_000)
        queue.push(.init(value: "approval", bytes: 1, sessionID: "s", pinned: true))
        var evicted: [String] = []
        for i in 0..<10 { evicted += queue.push(.init(value: "e\(i)", bytes: 1, sessionID: "s")).map(\.value) }
        XCTAssertFalse(evicted.contains("approval"))
        let first = await queue.next()
        XCTAssertEqual(first, "approval", "the pinned prompt is still delivered, in order")
    }

    func testOrderIsPreservedAcrossEvictions() async {
        let queue = BoundedQueue<Int>(maxCount: 4, maxBytes: 1_000)
        for i in 0..<10 { queue.push(.init(value: i, bytes: 1, sessionID: nil)) }
        var seen: [Int] = []
        for _ in 0..<4 { if let v = await queue.next() { seen.append(v) } }
        XCTAssertEqual(seen, [6, 7, 8, 9], "newest window, strictly increasing")
    }

    func testWaitingConsumerGetsDirectHandoffAndFinishReleasesIt() async {
        let queue = BoundedQueue<Int>(maxCount: 4, maxBytes: 100)
        let consumer = Task { await queue.next() }
        try? await Task.sleep(for: .milliseconds(50))
        queue.push(.init(value: 7, bytes: 1, sessionID: nil))
        let got = await consumer.value
        XCTAssertEqual(got, 7)
        let waiting = Task { await queue.next() }
        try? await Task.sleep(for: .milliseconds(50))
        queue.finish()
        let released = await waiting.value
        XCTAssertNil(released)
    }

    func testCancellingASubscriberDeregistersAndFreesItsQueue() async {
        let gaps = GapBroadcaster()
        let fanOut = BoundedFanOut<Int>(maxAggregateBytes: 1_000) { gaps.publish($0) }
        let stream = fanOut.makeStream(maxCount: 10, maxBytes: 100)
        let task = Task { for await _ in stream {} }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fanOut.subscriberCount, 1)
        fanOut.yield(1, bytes: 10, sessionID: nil)
        task.cancel()
        let gone = await waitUntil { fanOut.subscriberCount == 0 }
        XCTAssertTrue(gone, "cancellation must deregister the subscriber")
        XCTAssertEqual(fanOut.totalBytes, 0)
    }

    func testAggregateBudgetCapsAllSubscribersTogetherAndReportsGaps() async {
        let collector = GapCollector()
        let gaps = GapBroadcaster()
        let stream = gaps.subscribe()
        collector.task = Task { for await g in stream { collector.add(g) } }
        let fanOut = BoundedFanOut<Int>(maxAggregateBytes: 1_000) { gaps.publish($0) }
        _ = (0..<4).map { _ in fanOut.register(maxCount: 10_000, maxBytes: 10_000) }
        for i in 0..<400 { fanOut.yield(i, bytes: 20, sessionID: "s1") }
        XCTAssertLessThanOrEqual(fanOut.totalBytes, 1_000, "aggregate budget holds across subscribers")
        let reported = await waitUntil { collector.all.contains { $0.reason == .aggregateOverflow && $0.sessionID == "s1" } }
        XCTAssertTrue(reported)
    }

    func testSlowSubscriberNeverBlocksFastOneAndOnlyItBecomesIncomplete() async {
        let gaps = GapBroadcaster()
        let collector = GapCollector()
        let gapStream = gaps.subscribe()
        collector.task = Task { for await g in gapStream { collector.add(g) } }
        let fanOut = BoundedFanOut<Int>(maxAggregateBytes: 1 << 30) { gaps.publish($0) }
        let fast = fanOut.makeStream(maxCount: 100, maxBytes: 10_000)
        let slow = fanOut.makeStream(maxCount: 5, maxBytes: 10_000) // slow: held but never iterated
        defer { withExtendedLifetime(slow) {} }
        let received = Task { () -> [Int] in
            var out: [Int] = []
            for await v in fast { out.append(v); if out.count == 50 { break } }
            return out
        }
        for i in 0..<50 { fanOut.yield(i, bytes: 1, sessionID: "s") ; await Task.yield() }
        let values = await received.value
        XCTAssertEqual(values, Array(0..<50), "the fast subscriber sees everything, in order")
        let reported = await waitUntil { collector.all.filter { $0.reason == .subscriberOverflow }.count >= 45 }
        XCTAssertTrue(reported, "the slow subscriber's evictions are all reported")
    }

    func testGapBroadcasterCollapsesALaggingBacklogIntoOneGlobalGap() async {
        let gaps = GapBroadcaster()
        let stream = gaps.subscribe()
        for i in 0..<(GatewayEventBudget.maxPendingGaps + 20) {
            gaps.publish(EventGap(sessionID: "s\(i)", reason: .subscriberOverflow))
        }
        var received: [EventGap] = []
        for await gap in stream { received.append(gap); if received.count >= GatewayEventBudget.maxPendingGaps { break } }
        XCTAssertLessThanOrEqual(received.count, GatewayEventBudget.maxPendingGaps)
        XCTAssertTrue(received.contains { $0.sessionID == nil && $0.reason == .gapBacklogOverflow },
                      "a lost specific gap is replaced by an 'every session' gap")
    }

    func testEstimatedBytesTracksPayloadSize() {
        let small = GatewayEvent(type: .messageDelta, rawType: "message.delta", sessionID: "s", seq: 1,
                                 payload: .object(["text": .string("hi")]))
        let large = GatewayEvent(type: .messageDelta, rawType: "message.delta", sessionID: "s", seq: 1,
                                 payload: .object(["text": .string(String(repeating: "x", count: 500_000))]))
        XCTAssertGreaterThan(GatewayEventBudget.estimatedBytes(of: large), 500_000)
        XCTAssertLessThan(GatewayEventBudget.estimatedBytes(of: small), 1_000)
    }

    // MARK: transport (scripted socket)

    func testManySmallEventsToANeverReadingSubscriberStayBoundedAndPublishGaps() async throws {
        let socket = ScriptedSession()
        let transport = makeTransport(socket)
        let gaps = collectGaps(transport)
        let slow = transport.subscribeToEvents() // slow consumer: held, never iterated
        defer { withExtendedLifetime(slow) {} }
        socket.push(Self.ready)
        try await transport.connect()
        let total = GatewayEventBudget.maxSubscriberBacklog + 2_500
        for i in 1...total { socket.push(Self.event(session: "s1", seq: i)) }
        let reported = await waitUntil(15) {
            gaps.all.contains { $0.reason == .subscriberOverflow && $0.sessionID == "s1" }
        }
        XCTAssertTrue(reported, "overflow must publish a gap for the affected session")
        // Let the loop drain.
        _ = await waitUntil(15) { await transport.watermark(for: "s1") == total }
        XCTAssertLessThanOrEqual(transport.subscriberBufferedBytes, GatewayEventBudget.maxSubscriberBacklogBytes)
        let watermark = await transport.watermark(for: "s1")
        XCTAssertEqual(watermark, total, "the watermark still advanced: no stall, only a reported gap")
        await transport.disconnect()
        gaps.task?.cancel()
    }

    func testLargeEventsAreCappedByBytesNotJustCount() async throws {
        let socket = ScriptedSession()
        let transport = makeTransport(socket)
        let gaps = collectGaps(transport)
        let slow = transport.subscribeToEvents()
        defer { withExtendedLifetime(slow) {} }
        socket.push(Self.ready)
        try await transport.connect()
        let big = String(repeating: "x", count: 600_000) // under the 1 MiB frame cap
        let frames = 40                                   // ~24 MB ≫ 16 MiB subscriber budget
        for i in 1...frames { socket.push(Self.event(session: "s1", seq: i, text: big)) }
        _ = await waitUntil(20) { await transport.watermark(for: "s1") == frames }
        XCTAssertLessThanOrEqual(transport.subscriberBufferedBytes, GatewayEventBudget.maxSubscriberBacklogBytes)
        XCTAssertTrue(gaps.all.contains { $0.reason == .subscriberOverflow })
        await transport.disconnect()
        gaps.task?.cancel()
    }

    func testOversizedFrameIsRefusedBeforeDecodingAndEverySessionIsMarkedIncomplete() async throws {
        let socket = ScriptedSession()
        let transport = makeTransport(socket)
        let gaps = collectGaps(transport)
        let events = transport.subscribeToEvents()
        let received = Task { () -> Int in var n = 0; for await _ in events { n += 1 }; return n }
        socket.push(Self.ready)
        try await transport.connect()
        socket.push(Self.event(session: "s1", seq: 1, text: String(repeating: "x", count: GatewayEventBudget.maxFrameBytes + 10)))
        socket.push(Self.event(session: "s1", seq: 2))
        let reported = await waitUntil { gaps.all.contains { $0.reason == .oversizedFrame && $0.sessionID == nil } }
        XCTAssertTrue(reported, "a refused frame has an unknown session: the gap must say so")
        let incomplete = await transport.takeIncompleteSessions()
        XCTAssertTrue(incomplete.all, "every session must be treated as possibly incomplete")
        let w = await transport.watermark(for: "s1")
        XCTAssertEqual(w, 2, "the refused event never parsed; later events still flow")
        await transport.disconnect()
        received.cancel()
        gaps.task?.cancel()
    }

    func testReplayHoldIsBoundedByBytesAndOverflowMarksTheSession() async throws {
        let socket = ScriptedSession()
        let transport = makeTransport(socket)
        socket.push(Self.ready)
        try await transport.connect()
        await transport.beginReplayHold()
        let big = String(repeating: "x", count: 900_000)
        for i in 1...20 { socket.push(Self.event(session: "s1", seq: i, text: big)) } // ~18 MB
        _ = await waitUntil(10) { await !transport.takeReplayHoldOverflowSessionsPeek() }
        let held = await transport.replayHoldBufferedBytes
        XCTAssertLessThanOrEqual(held, GatewayEventBudget.maxReplayHoldBytes)
        let overflow = await transport.takeReplayHoldOverflowSessions()
        XCTAssertEqual(overflow, ["s1"], "parked frames lost to the byte budget flag their session")
        await transport.disconnect()
    }

    func testWatermarkTableEvictsTheLeastRecentlyActiveSessionAndMarksItIncomplete() async throws {
        let socket = ScriptedSession()
        let transport = makeTransport(socket)
        let gaps = collectGaps(transport)
        socket.push(Self.ready)
        try await transport.connect()
        let cap = GatewayEventBudget.maxTrackedSessions
        for i in 0..<cap { socket.push(Self.event(session: "s\(i)", seq: 1)) }
        // s0 is the oldest, but touching it again makes s1 the coldest.
        socket.push(Self.event(session: "s0", seq: 2))
        socket.push(Self.event(session: "new", seq: 1))
        let evicted = await waitUntil(15) { gaps.all.contains { $0.reason == .watermarkEvicted } }
        XCTAssertTrue(evicted)
        let marks = await transport.allWatermarks()
        XCTAssertEqual(marks.count, cap, "the table never grows past its bound")
        XCTAssertNotNil(marks["new"], "the session being updated is always tracked")
        XCTAssertNotNil(marks["s0"], "a recently active session keeps its watermark")
        XCTAssertNil(marks["s1"], "the coldest session was evicted")
        let incomplete = await transport.takeIncompleteSessions()
        XCTAssertEqual(incomplete.sessions, ["s1"])
        XCTAssertFalse(incomplete.all)
        await transport.disconnect()
        gaps.task?.cancel()
    }

    func testIncompleteSetCollapsesToAllSessionsRatherThanGrowing() async throws {
        let socket = ScriptedSession()
        let transport = makeTransport(socket)
        socket.push(Self.ready)
        try await transport.connect()
        let cap = GatewayEventBudget.maxTrackedSessions
        // 3x the table size of distinct sessions: evictions exceed the incomplete cap.
        for i in 0..<(cap * 3) { socket.push(Self.event(session: "n\(i)", seq: 1)) }
        _ = await waitUntil(30) { await transport.watermark(for: "n\(cap * 3 - 1)") == 1 }
        let incomplete = await transport.takeIncompleteSessions()
        XCTAssertLessThanOrEqual(incomplete.sessions.count, cap)
        XCTAssertTrue(incomplete.all, "beyond the cap the transport says 'everything', not a bigger set")
        await transport.disconnect()
    }

    func testReplayEngineTurnsIncompleteTrackingIntoVisibleRecoveryOutcomes() async throws {
        let socket = ScriptedSession()
        let transport = makeTransport(socket)
        socket.push(Self.ready)
        try await transport.connect()
        let cap = GatewayEventBudget.maxTrackedSessions
        for i in 0..<cap { socket.push(Self.event(session: "s\(i)", seq: 1)) }
        socket.push(Self.event(session: "new", seq: 1))
        _ = await waitUntil(15) { await transport.watermark(for: "new") == 1 }
        socket.push(Self.event(session: "unknown", seq: 1, text: String(repeating: "x", count: GatewayEventBudget.maxFrameBytes + 1)))
        try await Task.sleep(for: .milliseconds(100))
        let engine = GatewayReplayEngine(gatewayID: GatewayID(rawValue: "fixture"), transport: transport,
                                         history: NoHistory())
        let outcomes = try await engine.replayAfterReconnect()
        XCTAssertTrue(outcomes.contains(.truncated(sessionID: "s0")), "evicted session must refetch: \(outcomes)")
        XCTAssertTrue(outcomes.contains(.historyIncomplete), "an unattributable refused frame forces every open session to refetch")
        // Reported once: the markers were consumed, so a later pass cannot
        // loop on the same incompleteness.
        let leftover = await transport.takeIncompleteSessions()
        XCTAssertTrue(leftover.sessions.isEmpty)
        XCTAssertFalse(leftover.all)
        await transport.disconnect()
    }

    struct NoHistory: SessionHistoryProviding {
        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
            throw ReplayError.rpcFailed("not used")
        }
        func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
            throw ReplayError.rpcFailed("not used")
        }
    }

    func testRepeatedConnectCancelAndDisconnectReleaseSubscribersAndBuffers() async throws {
        let socket = ScriptedSession()
        let transport = makeTransport(socket)
        socket.push(Self.ready)
        try await transport.connect()
        for round in 0..<20 {
            let stream = transport.subscribeToEvents()
            let consumer = Task { for await _ in stream {} }
            socket.push(Self.event(session: "s", seq: round + 1))
            try await Task.sleep(for: .milliseconds(5))
            consumer.cancel()
        }
        let released = await waitUntil { transport.eventSubscriberCount == 0 }
        XCTAssertTrue(released, "cancelled subscribers must not accumulate")
        XCTAssertEqual(transport.subscriberBufferedBytes, 0)
        await transport.disconnect()
    }

    // MARK: transport (real URLSession over loopback)

    /// The platform socket refuses a message above `maxFrameBytes` at the
    /// message boundary: the event is never delivered, the connection fails
    /// (it does not wedge or buffer), and a later explicit reconnect works.
    /// Reconnect pacing/limits are the existing `ConnectionRecoveryTiming`
    /// (exponential, bounded attempts); the transport never retries by itself.
    func testRealSocketRefusesAnOversizedMessageAndRecoversOnReconnect() async throws {
        let huge = Self.event(session: "s1", seq: 1, text: String(repeating: "x", count: GatewayEventBudget.maxFrameBytes * 2))
        let hostile = InProcessWebSocketServer.Script(onOpen: [Self.ready, huge])
        let healthy = InProcessWebSocketServer.Script(onOpen: [Self.ready])
        let server = try InProcessWebSocketServer(scripts: [hostile, healthy])
        try await server.start()
        defer { server.stop() }
        let transport = GatewayWebSocketTransport(
            baseURL: URL(string: "http://127.0.0.1:\(server.listeningPort)")!,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: TransportConfiguration(
                pingInterval: .seconds(30), inboundDeadline: .seconds(30),
                connectTimeout: .seconds(10), requestTimeout: .seconds(3)))
        let gaps = collectGaps(transport)
        let events = transport.subscribeToEvents()
        let delivered = Task { () -> Int in
            var n = 0
            for await event in events where event.type == .messageDelta { n += 1 }
            return n
        }
        try await transport.connect()
        let failed = await waitUntil(10) { transport.state != .connected }
        XCTAssertTrue(failed, "the oversized message must fail the connection, not be buffered")
        XCTAssertEqual(transport.subscriberBufferedBytes, 0, "nothing from the oversized frame was retained")
        let incomplete = await transport.takeIncompleteSessions()
        XCTAssertTrue(incomplete.all, "a refused message of unknown session must mark every session incomplete")
        XCTAssertTrue(gaps.all.contains { $0.reason == .oversizedFrame && $0.sessionID == nil })
        let watermark = await transport.watermark(for: "s1")
        XCTAssertEqual(watermark, 0, "the oversized event was never parsed")
        try await transport.connect()
        XCTAssertEqual(transport.state, .connected)
        XCTAssertEqual(server.connectionCount, 2, "no automatic retry storm: exactly the explicit reconnect")
        await transport.disconnect()
        delivered.cancel()
    }

    // MARK: reviewer-driven regressions

    final class Probe: @unchecked Sendable {
        nonisolated(unsafe) static var live = 0
        init() { Self.live += 1 }
        deinit { Self.live -= 1 }
    }

    func testDrainedEntriesAreReleasedImmediatelyNotAtCompaction() async {
        Probe.live = 0
        let queue = BoundedQueue<Probe>(maxCount: 10_000, maxBytes: 1 << 30)
        for _ in 0..<300 { queue.push(.init(value: Probe(), bytes: 1, sessionID: nil)) }
        for _ in 0..<300 { _ = await queue.next() }
        XCTAssertEqual(queue.byteCount, 0)
        XCTAssertEqual(Probe.live, 0, "dead queue slots must not keep payloads alive")
    }

    func testAForgedPinnedFloodCannotBypassTheByteBudget() async {
        let queue = BoundedQueue<Int>(maxCount: 1_000_000, maxBytes: 4 << 20)
        var evicted = 0
        // The peer chooses event types, so every entry claims to be an approval.
        for i in 0..<2_000 { evicted += queue.push(.init(value: i, bytes: 1 << 20, sessionID: "s", pinned: true)).count }
        XCTAssertLessThanOrEqual(queue.byteCount, 4 << 20 + (1 << 20), "oversized 'pins' are ordinary, evictable entries")
        XCTAssertGreaterThan(evicted, 1_900)
        // Small genuine prompts are still protected, up to the pin cap.
        let small = BoundedQueue<Int>(maxCount: 3, maxBytes: 1 << 20)
        for i in 0..<10 { small.push(.init(value: i, bytes: 100, sessionID: "s", pinned: true)) }
        XCTAssertEqual(small.count, 10, "within the pin cap nothing is evicted")
        let flood = BoundedQueue<Int>(maxCount: 3, maxBytes: 1 << 20)
        for i in 0..<1_000 { flood.push(.init(value: i, bytes: 100, sessionID: "s", pinned: true)) }
        XCTAssertLessThanOrEqual(flood.count, BoundedQueue<Int>.maxPinned + 3, "pins are capped by count too")
    }

    func testForgedApprovalRequestFloodThroughTheTransportStaysBounded() async throws {
        let socket = ScriptedSession()
        let transport = makeTransport(socket)
        let slow = transport.subscribeToEvents()
        defer { withExtendedLifetime(slow) {} }
        socket.push(Self.ready)
        try await transport.connect()
        let big = String(repeating: "x", count: 600_000)
        for i in 1...60 {
            let params: [String: Any] = ["type": "approval.request", "session_id": "s", "seq": i, "payload": ["text": big]]
            let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "event", "params": params])
            socket.push(String(data: data, encoding: .utf8)!)
        }
        _ = await waitUntil(20) { await transport.watermark(for: "s") == 60 }
        XCTAssertLessThanOrEqual(transport.subscriberBufferedBytes,
                                 GatewayEventBudget.maxSubscriberBacklogBytes + (1 << 20))
        await transport.disconnect()
    }

    func testAdmittingAServerRequestIntoAFullQueueReportsTheEvictedEvent() async {
        let collector = GapCollector()
        let gaps = GapBroadcaster()
        let stream = gaps.subscribe()
        collector.task = Task { for await g in stream { collector.add(g) } }
        let box = ServerRequestBox(onGap: { gaps.publish($0) })
        let (_, queue) = box.subscribeConversation(maxCount: 2, maxBytes: 1 << 20)
        queue.push(.init(value: .messageStart(sessionID: "s1"), bytes: 10, sessionID: "s1"))
        queue.push(.init(value: .messageStart(sessionID: "s2"), bytes: 10, sessionID: "s2"))
        let request = ServerRequest(id: "srq-1", sessionID: "s3", kind: .approval(
            ApprovalRequest(requestID: "srq-1", sessionID: "s3", command: "true", choices: ["once", "deny"])))
        _ = box.admit(.init(wireID: .string("srq-1"), request: request))
        let reported = await waitUntil { collector.all.contains { $0.sessionID == "s1" && $0.reason == .subscriberOverflow } }
        XCTAssertTrue(reported, "evicting an ordinary event to admit a prompt must publish a gap")
    }

    func testDroppingAStreamWithoutIteratingItDeregistersTheSubscriber() async {
        let gaps = GapBroadcaster()
        let fanOut = BoundedFanOut<Int>(maxAggregateBytes: 1_000) { gaps.publish($0) }
        do {
            let stream = fanOut.makeStream(maxCount: 10, maxBytes: 100)
            XCTAssertEqual(fanOut.subscriberCount, 1)
            _ = stream
        }
        let released = await waitUntil { fanOut.subscriberCount == 0 }
        XCTAssertTrue(released, "an abandoned, never-iterated stream must not stay registered")
    }

    func testMessageTooLargeDetectionCoversTopLevelAndNestedErrors() {
        XCTAssertTrue(GatewayWebSocketTransport.isMessageTooLarge(NSError(domain: NSPOSIXErrorDomain, code: 40)))
        XCTAssertTrue(GatewayWebSocketTransport.isMessageTooLarge(URLError(.dataLengthExceedsMaximum)))
        let nested = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 40)])
        XCTAssertTrue(GatewayWebSocketTransport.isMessageTooLarge(nested))
        XCTAssertFalse(GatewayWebSocketTransport.isMessageTooLarge(NSError(domain: NSPOSIXErrorDomain, code: 57)))
        XCTAssertFalse(GatewayWebSocketTransport.isMessageTooLarge(URLError(.timedOut)))
    }
}
