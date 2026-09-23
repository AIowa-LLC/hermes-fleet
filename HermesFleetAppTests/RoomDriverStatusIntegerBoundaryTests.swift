import XCTest
@testable import HermesFleetApp
import FleetCore
import FleetNetworking

/// t_d8f69400 — the APP-target tail of the 2^63 `Int(Double)` trap class
/// closed for FleetNetworking (a71f5eb) and FleetCore (249b080).
///
/// `GatewayRoomDriverStatusAdapter.driverStatus` reads two integer members of
/// the gateway's `groups.state` → `driver_status` payload: each approval
/// action's `execution_generation` and every value of the `counts` map.
/// `Int(_:)` on a `Double` TRAPS outside `Int`'s range, and the top of the
/// range is a trap door because `Double(Int.max)` rounds UP to exactly 2^63 —
/// so the bound must be 2^63-EXCLUSIVE, which is exactly what
/// `JSONValue.intValue` (`boundedInt`) already encodes. Both reads now use it.
///
/// Every assertion here runs through the REAL path — the in-process WebSocket
/// gateway fixture → `GatewayWebSocketTransport` → the adapter's own
/// `groups.state` request → `JSONRPCCodec` — so a hostile
/// `"execution_generation": 9223372036854775808` or an unrepresentable count
/// degrades to that site's OWN missing-value shape (`?? 0`, never a clamped or
/// invented generation/count), while 2^63-1024 = 9223372036854774784 (the
/// largest Double below 2^63) still converts exactly.
final class RoomDriverStatusIntegerBoundaryTests: XCTestCase {

    /// 2^63 — the first Double that is NOT representable in `Int`.
    private static let twoPow63 = 9_223_372_036_854_775_808.0
    /// The largest Double below 2^63 (the ulp at this magnitude is 1024).
    private static let largestSafe = 9_223_372_036_854_775_808.0 - 1_024.0

    private static let gatewayReadyFrame =
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true,"heartbeat":false,"replay_epoch":"epoch-1"}}}"#

    /// A gateway that reports an unrepresentable `execution_generation` on its
    /// single approval and unrepresentable `retry`/`approval` counts — plus
    /// representable neighbours that must survive untouched.
    private static let hostileDriverStatus = #"{"working":true,"blocked":true,"counts":{"retry":9223372036854775808,"approval":9223372036854775808,"log":3},"pending_actions":[{"kind":"approval","task_id":"task-1","member_id":"researcher","execution_generation":9223372036854775808,"run_id":"run-1","session_id":"session-1","request_id":"req-1","approval":{"prompt":"Approve the deploy?","choices":["once","deny"]}},{"kind":"retry","task_id":"task-2"}]}"#

    /// The largest Double below 2^63 — in range, so it must convert exactly.
    private static let largestSafeDriverStatus = #"{"counts":{"retry":9223372036854774784,"approval":9223372036854774784},"pending_actions":[{"kind":"approval","task_id":"task-1","member_id":"researcher","execution_generation":9223372036854774784,"approval":{"prompt":"Approve?"}}]}"#

    /// Non-numeric / absent members: the pre-existing missing-value shape.
    private static let absentShapedDriverStatus = #"{"counts":{"retry":"3","approval":null,"log":7},"pending_actions":[{"kind":"approval","task_id":"task-1","member_id":"researcher","approval":{"prompt":"Approve?"}}]}"#

    // MARK: - Drive the real adapter

    private struct Observed {
        let status: RoomDriverStatus
        /// Exact frames the fixture served, in order (the precondition decodes
        /// these, not a hand-built value).
        let servedFrames: [String]
        /// Exact request frames the adapter sent, in order.
        let requestFrames: [String]
    }

    /// Serve one scripted `groups.state` result over the shared in-process
    /// gateway fixture and drive the REAL adapter through it.
    private func observedDriverStatus(
        driverStatusLiteral: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Observed {
        let served = LockedStrings()
        let requests = LockedStrings()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.gatewayReadyFrame],
            onText: { frame in
                requests.append(frame)
                guard let object = Self.jsonObject(frame),
                      let id = object["id"] as? String,
                      let method = object["method"] as? String,
                      method == "groups.state" else { return [] }
                let reply = #"{"jsonrpc":"2.0","id":"\#(id)","result":{"driver_status":\#(driverStatusLiteral)}}"#
                served.append(reply)
                return [reply]
            })
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }

        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let adapter = GatewayRoomDriverStatusAdapter(
            gatewayID: GatewayID(rawValue: "test-gateway"),
            transport: transport)
        let status = try await adapter.driverStatus(roomID: "room-1")

        return Observed(
            status: try XCTUnwrap(status, "the adapter returned no driver status", file: file, line: line),
            servedFrames: served.values,
            requestFrames: requests.values)
    }

    private func makeTransport(serverPort: UInt16) -> GatewayWebSocketTransport {
        let base = URL(string: "http://127.0.0.1:\(serverPort)")!
        let configuration = TransportConfiguration(
            pingInterval: .seconds(30),
            inboundDeadline: .seconds(30),
            connectTimeout: .seconds(10),
            requestTimeout: .seconds(2))
        return GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: DriverStatusTestTicketMinter(
                ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: configuration)
    }

    // MARK: - Boundary tests

    /// 2^63 on the approval's `execution_generation` and on two `counts`
    /// values must degrade to `0` (each site's missing-value shape) without
    /// trapping `Int(_:)`, and must not disturb the rest of the payload.
    func testHostileTwoToTheSixtyThreeGenerationAndCountsDegradeWithoutTrap() async throws {
        let observed = try await observedDriverStatus(driverStatusLiteral: Self.hostileDriverStatus)

        // Precondition, decoded with the SAME codec the transport uses, on the
        // exact frame the fixture served: the literal really arrives as the
        // trapping Double (not a string, not a decode failure).
        let servedFrame = try XCTUnwrap(observed.servedFrames.first)
        let servedResult = try Self.wireResult(servedFrame)
        let servedApproval = try XCTUnwrap(
            servedResult["driver_status"]?["pending_actions"]?.arrayValue?.first)
        XCTAssertEqual(servedApproval["execution_generation"]?.numberValue, Self.twoPow63,
                       "precondition: the served execution_generation really is 2^63")
        XCTAssertEqual(servedResult["driver_status"]?["counts"]?["retry"]?.numberValue, Self.twoPow63,
                       "precondition: the served retry count really is 2^63")

        // The real path: one `groups.state` request for the requested room.
        let requestFrame = try XCTUnwrap(observed.requestFrames.first)
        let request = try Self.wireRequest(requestFrame)
        XCTAssertEqual(request.method, "groups.state")
        XCTAssertEqual(request.params?["room_id"], .string("room-1"))

        // Degradation, never a clamp and never an invented generation.
        XCTAssertEqual(observed.status.pendingApprovals.count, 1)
        let approval = try XCTUnwrap(observed.status.pendingApprovals.first)
        XCTAssertEqual(approval.executionGeneration, 0,
                       "an unrepresentable generation degrades to this site's `?? 0`")
        XCTAssertEqual(observed.status.counts["retry"], 0)
        XCTAssertEqual(observed.status.counts["approval"], 0)
        XCTAssertEqual(observed.status.counts["log"], 3,
                       "the representable neighbour count is untouched")

        // Only the unrepresentable integers degraded.
        XCTAssertEqual(approval.memberID, "researcher")
        XCTAssertEqual(approval.taskID, "task-1")
        XCTAssertEqual(approval.runID, "run-1")
        XCTAssertEqual(approval.sessionID, "session-1")
        XCTAssertEqual(approval.requestID, "req-1")
        XCTAssertEqual(approval.approval["prompt"], .string("Approve the deploy?"))
        XCTAssertEqual(observed.status.pendingRetries.map(\.taskID), ["task-2"])
        XCTAssertTrue(observed.status.working)
        XCTAssertTrue(observed.status.blocked)
    }

    /// 2^63-1024 = 9223372036854774784 — the largest Double below 2^63 — is in
    /// range and must convert exactly at both sites.
    func testLargestSafeDoubleBelowTwoToTheSixtyThreeConvertsExactly() async throws {
        let observed = try await observedDriverStatus(driverStatusLiteral: Self.largestSafeDriverStatus)

        let servedFrame = try XCTUnwrap(observed.servedFrames.first)
        let servedResult = try Self.wireResult(servedFrame)
        let servedApproval = try XCTUnwrap(
            servedResult["driver_status"]?["pending_actions"]?.arrayValue?.first)
        XCTAssertEqual(servedApproval["execution_generation"]?.numberValue, Self.largestSafe,
                       "precondition: the served execution_generation really is 2^63-1024")

        let approval = try XCTUnwrap(observed.status.pendingApprovals.first)
        XCTAssertEqual(approval.executionGeneration, 9_223_372_036_854_774_784)
        XCTAssertEqual(approval.executionGeneration, Int(Self.largestSafe))
        XCTAssertEqual(observed.status.counts["retry"], 9_223_372_036_854_774_784)
        XCTAssertEqual(observed.status.counts["approval"], Int(Self.largestSafe))
    }

    /// Non-numeric and absent members keep the shape they had before the
    /// bound: an absent/non-numeric `execution_generation` reads as `0`, and a
    /// non-numeric count reads as that key's `0` — while `log: 7` survives.
    func testNonNumericGenerationAndCountsKeepTheExistingMissingValueShape() async throws {
        let observed = try await observedDriverStatus(driverStatusLiteral: Self.absentShapedDriverStatus)

        let approval = try XCTUnwrap(observed.status.pendingApprovals.first)
        XCTAssertEqual(approval.executionGeneration, 0,
                       "a missing/non-numeric generation still reads as 0")
        XCTAssertEqual(observed.status.counts, ["retry": 0, "approval": 0, "log": 7])
    }

    // MARK: - Wire helpers (same codec the transport uses)

    private static func wireResult(_ frame: String) throws -> JSONValue {
        guard case .response(let response) = try JSONRPCCodec.decode(frame) else {
            throw WireError.notAResponse(frame)
        }
        return try XCTUnwrap(response.result)
    }

    private static func wireRequest(_ frame: String) throws -> JSONRPCRequest {
        guard case .request(let request) = try JSONRPCCodec.decode(frame) else {
            throw WireError.notARequest(frame)
        }
        return request
    }

    private static func jsonObject(_ frame: String) -> [String: Any]? {
        guard let data = frame.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private enum WireError: Error {
        case notAResponse(String)
        case notARequest(String)
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct DriverStatusTestTicketMinter: WSTicketMinting {
    let ticket: WSTicket
    func mintTicket() async throws -> WSTicket { ticket }
}