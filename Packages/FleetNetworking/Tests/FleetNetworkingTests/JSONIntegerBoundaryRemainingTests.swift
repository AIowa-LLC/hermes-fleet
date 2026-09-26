import XCTest
import FleetCore
@testable import FleetNetworking

/// t_621c1ac6 — the REST of the 2^63 `Int(Double)` trap class, closed for the
/// gateway-JSON integer reads still unguarded in 13 FleetNetworking clients
/// (follow-up to t_0b22f9e5 / commit 266c771).
///
/// `Int(_:)` on a Double outside `Int`'s range TRAPS the process (Trace/BPT,
/// exit 133), and `Double(Int.max)` rounds UP to exactly 2^63 — so the upper
/// bound must be 2^63-EXCLUSIVE. That bound lives in ONE place
/// (`JSONValue.boundedInt`, exposed as `JSONValue.intValue`); every conversion
/// in these files now reads through it.
///
/// Every out-of-range degradation is pinned here through the REAL decode path
/// of each file (its own `decode*` function, or — where the only read is
/// inline in an async transport-backed method — the in-process WebSocket
/// fixture): 2^63 degrades to that site's OWN missing-value shape (`?? 0`, an
/// optional's nil, a dropped map/array entry, or the function's typed
/// malformed error), never a clamped or invented value, and the largest safe
/// Double below 2^63 (2^63-1024) still converts exactly.
final class JSONIntegerBoundaryRemainingTests: XCTestCase {

    /// 2^63 — the first Double that is NOT representable in `Int`.
    private static let twoPow63 = 9_223_372_036_854_775_808.0
    /// The largest Double below 2^63 (the ulp at this magnitude is 1024).
    private static let largestSafe = 9_223_372_036_854_775_808.0 - 1_024.0

    /// Decode through the SAME Foundation decoder the wire path uses, so the
    /// hostile literal really arrives as a `Double` (asserted per test).
    private static func json(_ raw: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    // MARK: - GatewayEvent.swift (`seq`)

    func testGatewayEventSeqAtTheBoundaryReadsAsAbsent() throws {
        let hostile = try Self.json(#"{"type":"session.info","session_id":"s-1","seq":9223372036854775808}"#)
        XCTAssertEqual(hostile["seq"]?.numberValue, Self.twoPow63,
                       "precondition: the literal really is the trapping Double")
        XCTAssertNil(GatewayEvent(replayParams: hostile)?.seq,
                     "an unrepresentable seq reads as absent, like a missing key")

        let safe = try Self.json(#"{"type":"session.info","session_id":"s-1","seq":9223372036854774784}"#)
        let event = try XCTUnwrap(GatewayEvent(event: JSONRPCEvent(method: "event", params: safe)))
        XCTAssertEqual(event.seq, Int(Self.largestSafe),
                       "the largest safe Double below 2^63 still converts exactly")
    }

    // MARK: - GatewayReactionClient.swift (`row_id`)

    func testGatewayReactionClientRowIDAtTheBoundaryFailsTyped() throws {
        let hostile = try Self.json(#"{"row_id":9223372036854775808,"reactions":[]}"#)
        XCTAssertEqual(hostile["row_id"]?.numberValue, Self.twoPow63)
        XCTAssertThrowsError(try GatewayReactionClient.decodeResult(hostile)) { error in
            guard let reactionError = error as? ReactionError,
                  case .malformedResponse = reactionError else {
                return XCTFail("expected ReactionError.malformedResponse, got \(error)")
            }
        }

        let safe = try Self.json(#"{"row_id":9223372036854774784,"reactions":[]}"#)
        XCTAssertEqual(try GatewayReactionClient.decodeResult(safe).rowID, String(Int(Self.largestSafe)))
    }

    // MARK: - GatewaySessionHistoryClient.swift (`count`, `row_id`)

    func testGatewaySessionHistoryCountAndRowIDAtTheBoundaryDegrade() throws {
        let hostile = try Self.json(
            #"{"count":9223372036854775808,"messages":[{"role":"user","text":"hi","row_id":9223372036854775808}]}"#)
        XCTAssertEqual(hostile["count"]?.numberValue, Self.twoPow63)
        let history = try GatewaySessionHistoryClient.decodeHistory(sessionID: "s-1", hostile)
        XCTAssertEqual(history.count, history.messages.count,
                       "an unrepresentable count degrades to the decoded message count")
        XCTAssertEqual(history.count, 1)
        XCTAssertNil(history.messages.first?.rowID,
                     "an unrepresentable row_id falls through to the string form and then to nil")
        XCTAssertEqual(history.messages.first?.text, "hi", "the row itself still decodes")

        let safe = try Self.json(
            #"{"count":9223372036854774784,"messages":[{"role":"user","text":"hi","row_id":9223372036854774784}]}"#)
        let safeHistory = try GatewaySessionHistoryClient.decodeHistory(sessionID: "s-1", safe)
        XCTAssertEqual(safeHistory.count, Int(Self.largestSafe))
        XCTAssertEqual(safeHistory.messages.first?.rowID, String(Int(Self.largestSafe)))

        // The string row_id branch is untouched by the bound.
        let stringRow = try Self.json(#"{"messages":[{"role":"user","text":"hi","row_id":"durable-9"}]}"#)
        XCTAssertEqual(
            try GatewaySessionHistoryClient.decodeHistory(sessionID: "s-1", stringRow).messages.first?.rowID,
            "durable-9")
    }

    // MARK: - GatewayReplayClient.swift (`latest_seq`, `count`)

    func testGatewayReplayClientLatestSeqAndCountAtTheBoundaryDegrade() throws {
        let hostile = try Self.json(
            #"{"events":[{"type":"session.info","session_id":"s-1","seq":1}],"latest_seq":9223372036854775808,"count":9223372036854775808}"#)
        XCTAssertEqual(hostile["latest_seq"]?.numberValue, Self.twoPow63)
        let batch = try GatewayReplayClient.decode(sessionID: "s-1", hostile)
        XCTAssertEqual(batch.latestSeq, 0, "an unrepresentable watermark degrades to this site's default")
        XCTAssertEqual(batch.count, batch.events.count, "an unrepresentable count degrades to the decoded event count")
        XCTAssertEqual(batch.events.count, 1)

        let safe = try Self.json(#"{"latest_seq":9223372036854774784,"count":9223372036854774784}"#)
        let safeBatch = try GatewayReplayClient.decode(sessionID: "s-1", safe)
        XCTAssertEqual(safeBatch.latestSeq, Int(Self.largestSafe))
        XCTAssertEqual(safeBatch.count, Int(Self.largestSafe))
    }

    // MARK: - GatewayLearningClient.swift (`index`, `count`)

    func testGatewayLearningClientBucketIndexAndTotalCountAtTheBoundaryDegrade() throws {
        let hostile = try Self.json(
            #"{"buckets":[{"index":9223372036854775808,"label":"b0"},{"index":9223372036854774784,"label":"b1"}],"count":9223372036854775808}"#)
        XCTAssertEqual(hostile["count"]?.numberValue, Self.twoPow63)
        let graph = try GatewayLearningClient.decodeGraph(hostile)
        XCTAssertEqual(graph.buckets.map(\.index), [0, Int(Self.largestSafe)],
                       "an unrepresentable index degrades to the entry's position; the safe one is exact")
        XCTAssertEqual(graph.summary.totalCount, graph.buckets.count,
                       "an unrepresentable total count degrades to the decoded bucket count")
    }

    // MARK: - GatewayRosterClient.swift (`skill_count`, `message_count`)

    func testGatewayRosterClientCountsAtTheBoundaryDegrade() throws {
        let hostileProfile = try Self.json(#"{"name":"researcher","skill_count":9223372036854775808}"#)
        XCTAssertEqual(hostileProfile["skill_count"]?.numberValue, Self.twoPow63)
        let profile = try XCTUnwrap(GatewayRosterClient.decodeProfile(hostileProfile))
        XCTAssertEqual(profile.skillCount, 0)

        let safeProfile = try XCTUnwrap(GatewayRosterClient.decodeProfile(
            try Self.json(#"{"name":"researcher","skill_count":9223372036854774784}"#)))
        XCTAssertEqual(safeProfile.skillCount, Int(Self.largestSafe))

        let session = try XCTUnwrap(GatewayRosterClient.decodeSession(
            try Self.json(#"{"id":"s-1","message_count":9223372036854775808}"#)))
        XCTAssertEqual(session.messageCount, 0)
        let safeSession = try XCTUnwrap(GatewayRosterClient.decodeSession(
            try Self.json(#"{"id":"s-1","message_count":9223372036854774784}"#)))
        XCTAssertEqual(safeSession.messageCount, Int(Self.largestSafe))
    }

    // MARK: - GatewayConversationClient.swift (`message_count`)

    func testGatewayConversationClientMessageCountAtTheBoundaryDegrades() throws {
        let hostile = try Self.json(
            #"{"session_id":"s-1","messages":[{"role":"user","text":"hi"}],"message_count":9223372036854775808}"#)
        XCTAssertEqual(hostile["message_count"]?.numberValue, Self.twoPow63)
        let session = try GatewayConversationClient.decodeSession(hostile)
        XCTAssertEqual(session.messageCount, session.messages.count,
                       "an unrepresentable count degrades to the decoded message count")
        XCTAssertEqual(session.messageCount, 1)

        let safe = try Self.json(#"{"session_id":"s-1","message_count":9223372036854774784}"#)
        XCTAssertEqual(try GatewayConversationClient.decodeSession(safe).messageCount, Int(Self.largestSafe))
    }

    // MARK: - GatewayConversationToolingClient.swift (`session.usage`, breakdown)

    func testGatewayConversationToolingUsageAndBreakdownAtTheBoundaryDegrade() throws {
        let usageJSON = try Self.json(
            #"{"input":9223372036854775808,"total":9223372036854774784,"context_used":9223372036854775808,"context_max":9223372036854774784}"#)
        XCTAssertEqual(usageJSON["input"]?.numberValue, Self.twoPow63)
        let usage = GatewayConversationToolingClient.decodeUsage(usageJSON)
        XCTAssertEqual(usage.input, 0)
        XCTAssertNil(usage.contextUsed,
                     "an unrepresentable optional reads as unknown (nil), never a fabricated 0")
        XCTAssertEqual(usage.total, Int(Self.largestSafe))
        XCTAssertEqual(usage.contextMax, Int(Self.largestSafe))

        let breakdownJSON = try Self.json(
            #"{"categories":[{"id":"c1","tokens":9223372036854775808},{"id":"c2","tokens":7}],"context_max":9223372036854775808,"estimated_total":9223372036854774784}"#)
        let breakdown = GatewayConversationToolingClient.decodeBreakdown(breakdownJSON)
        XCTAssertEqual(breakdown.categories.map(\.tokens), [0, 7])
        XCTAssertEqual(breakdown.contextMax, 0)
        XCTAssertEqual(breakdown.estimatedTotal, Int(Self.largestSafe))
    }

    // MARK: - GatewayProjectsClient.swift (project + session-row counters)

    func testGatewayProjectsClientCountersAtTheBoundaryDegrade() throws {
        let projectJSON = try Self.json(
            #"{"id":"p-1","repos":[{"id":"r-1","sessionCount":3}],"sessionCount":9223372036854775808,"totalTokens":9223372036854774784}"#)
        XCTAssertEqual(projectJSON["sessionCount"]?.numberValue, Self.twoPow63)
        let project = try XCTUnwrap(GatewayProjectsClient.decodeProject(projectJSON))
        XCTAssertEqual(project.sessionCount, 3,
                       "an unrepresentable session count degrades to the repos' own count")
        XCTAssertEqual(project.totalTokens, Int(Self.largestSafe))

        let rowJSON = try Self.json(
            #"{"id":"s-1","message_count":9223372036854775808,"tool_call_count":9223372036854774784,"input_tokens":9223372036854775808,"output_tokens":5}"#)
        let row = try XCTUnwrap(GatewayProjectsClient.decodeSession(rowJSON))
        XCTAssertEqual(row.messageCount, 0)
        XCTAssertEqual(row.toolCallCount, Int(Self.largestSafe))
        XCTAssertEqual(row.inputTokens, 0)
        XCTAssertEqual(row.outputTokens, 5)
    }

    // MARK: - GatewayGroupsClient.swift (capabilities, room, log page, event)

    func testGatewayGroupsClientSeqsEpochsAndVersionsAtTheBoundaryDegrade() throws {
        let capsJSON = try Self.json(#"{"protocol_version":9223372036854775808,"max_log_limit":9223372036854774784}"#)
        XCTAssertEqual(capsJSON["protocol_version"]?.numberValue, Self.twoPow63)
        let caps = GatewayGroupsClient.decodeCapabilities(capsJSON)
        XCTAssertEqual(caps.protocolVersion, 0)
        XCTAssertEqual(caps.maxLogLimit, Int(Self.largestSafe))

        let roomJSON = try Self.json(
            #"{"room_id":"r-1","authority_epoch":9223372036854775808,"revision":9223372036854774784,"latest_seq":9223372036854775808}"#)
        let room = try GatewayGroupsClient.decodeRoom(roomJSON)
        XCTAssertEqual(room.authorityEpoch, 0)
        XCTAssertEqual(room.revision, Int(Self.largestSafe))
        XCTAssertNil(room.latestSeq, "an unrepresentable optional seq stays absent")

        let pageJSON = try Self.json(
            #"{"events":[],"cursor":9223372036854775808,"latest_seq":9223372036854774784,"authority":{"gateway_id":"g-1","epoch":9223372036854775808}}"#)
        let page = try GatewayGroupsClient.decodeLogPage(pageJSON)
        XCTAssertEqual(page.cursor, 0)
        XCTAssertEqual(page.latestSeq, Int(Self.largestSafe))
        XCTAssertEqual(page.authority.epoch, 0)

        let eventJSON = try Self.json(#"{"event_id":"e-1","kind":"message","seq":9223372036854775808}"#)
        let event = try XCTUnwrap(GatewayGroupsClient.decodeEvent(eventJSON))
        XCTAssertEqual(event.seq, 0)
    }

    // MARK: - GatewayRoomLinkClient.swift (protocol versions, execution policy)

    func testGatewayRoomLinkClientProtocolVersionsAndPolicyAtTheBoundaryDegrade() throws {
        let hostile = try Self.json(
            #"{"room_link":{"enabled":true,"catalog":{"protocol_versions":[2,9223372036854775808,9223372036854774784],"execution_policy":{"version":9223372036854775808,"max_iterations":9223372036854774784}}}}"#)
        XCTAssertEqual(hostile["room_link"]?["catalog"]?["protocol_versions"]?.arrayValue?[1].numberValue,
                       Self.twoPow63, "precondition: the hostile entry really is the trapping Double")
        let negotiation = GatewayRoomLinkClient.decodeNegotiation(hostile)
        XCTAssertEqual(negotiation.protocolVersions, [2, Int(Self.largestSafe)],
                       "an unrepresentable protocol version drops out; the readable ones survive")
        XCTAssertEqual(negotiation.executionPolicy?.version, 0)
        XCTAssertEqual(negotiation.executionPolicy?.maxIterations, Int(Self.largestSafe))
    }

    // MARK: - GatewayApprovalClient.swift (`approval.respond` → `resolved`)

    /// The only read in this file is inline in the transport-backed
    /// `respond`, so the boundary is driven over the in-process WebSocket
    /// fixture — the real socket path, not a mirror of the conversion.
    func testGatewayApprovalClientResolvedAtTheBoundaryDegradesOverTheWire() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText),
                      method == "approval.respond" else { return [] }
                let hostile = (params["request_id"] as? String) == "hostile"
                return [Self.rawTextResponseFrame(
                    id: id,
                    resultJSON: hostile ? #"{"resolved":9223372036854775808}"# : #"{"resolved":9223372036854774784}"#)]
            })
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayApprovalClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)

        // 2^63 used to reach `Int(_:)` and kill the process; it now degrades to
        // this site's existing missing-value default.
        let resolved = try await client.respond(
            sessionID: "s-1", requestID: "hostile", choice: .once, all: false)
        XCTAssertEqual(resolved, 0)

        // 2^63-1024 still converts exactly.
        let safe = try await client.respond(
            sessionID: "s-1", requestID: "safe", choice: .once, all: false)
        XCTAssertEqual(safe, Int(Self.largestSafe))
    }

    // MARK: - GatewayAttachmentClient.swift (counts)

    /// Same seam: the reads live inside the transport-backed methods, so the
    /// boundary goes over the fixture — including the typed degradation for a
    /// mandatory count (`image.attach_bytes`) and the exact conversion for
    /// `image.detach`'s count.
    func testGatewayAttachmentClientCountsAtTheBoundaryDegradeOverTheWire() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                switch method {
                case "image.attach_bytes":
                    return [Self.rawTextResponseFrame(
                        id: id,
                        resultJSON: #"{"attached":true,"path":"/synthetic/attachments/a.png","count":9223372036854775808,"bytes":9223372036854774784}"#)]
                case "image.detach":
                    return [Self.rawTextResponseFrame(
                        id: id, resultJSON: #"{"detached":true,"count":9223372036854774784}"#)]
                default:
                    return []
                }
            })
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let client = GatewayAttachmentClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)

        // A mandatory count at 2^63 must fail with the function's own typed
        // missing-value shape, never trap.
        do {
            _ = try await client.attachImageBytes(
                sessionID: "s-1", filename: "a.png", dataURL: "data:image/png;base64,AAAA")
            XCTFail("expected malformedResponse for an unrepresentable count")
        } catch let error as AttachmentStagingError {
            guard case .malformedResponse = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
        }

        let detached = try await client.detachImage(
            sessionID: "s-1", path: "/synthetic/attachments/a.png")
        XCTAssertEqual(detached.count, Int(Self.largestSafe))
        XCTAssertTrue(detached.detached)
    }

    // MARK: - fixture plumbing (mirrors the client suites' own helpers)

    private func makeTransport(serverPort: UInt16) -> GatewayWebSocketTransport {
        let base = URL(string: "http://127.0.0.1:\(serverPort)")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30),
            inboundDeadline: .seconds(30),
            connectTimeout: .seconds(10),
            requestTimeout: .seconds(2)
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

    private static func extractRequest(_ frameText: String) -> (id: String, method: String, params: [String: Any])? {
        guard let data = frameText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String else { return nil }
        return (id, method, obj["params"] as? [String: Any] ?? [:])
    }

    /// Emits the result object VERBATIM: `9223372036854775808` has no `Int`
    /// literal and would not survive a `JSONSerialization` round trip, so the
    /// hostile frame is assembled as text exactly as a buggy gateway would
    /// send it.
    private static func rawTextResponseFrame(id: String, resultJSON: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","result":\#(resultJSON)}"#
    }
}