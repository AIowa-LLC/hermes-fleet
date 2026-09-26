import XCTest
@testable import HermesFleetApp
import FleetNetworking
import FleetCore

/// Hosted Groups provider integration tests over the shared in-process WebSocket
/// gateway fixture. These cover provider-level pagination, including a retained
/// disband tombstone and a nonadvancing cursor guard.
final class HostedRoomProviderTests: XCTestCase {
    private func readyFrame() -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true,"heartbeat":false,"replay_epoch":"epoch-1"}}}"#
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
            ticketMinter: HostedTestTicketMinter(
                ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: configuration)
    }

    func testRoomsDrainsPagesAndRetainsDisbandTombstoneWithNonadvancingCursor() async throws {
        let listOffsets = LockedInts()
        let script = InProcessWebSocketServer.Script(
            onOpen: [readyFrame()],
            onText: { frame in
                guard let data = frame.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = object["id"] as? String,
                      let method = object["method"] as? String else { return [] }

                switch method {
                case "groups.capabilities":
                    return [#"{"jsonrpc":"2.0","id":"\#(id)","result":{"protocol_version":2,"driver":true,"persistent_process":true,"authority_gateway_id":"install:test","room_link":{"enabled":false},"features":[],"methods":["groups.capabilities","groups.list"],"max_log_limit":500}}"#]
                case "groups.list":
                    let params = object["params"] as? [String: Any]
                    let offset = (params?["offset"] as? NSNumber)?.intValue ?? 0
                    listOffsets.append(offset)
                    if offset == 0 {
                        return [#"{"jsonrpc":"2.0","id":"\#(id)","result":{"rooms":[{"room_id":"room-live","name":"Live","members":[],"authority_gateway_id":"install:test","authority_epoch":1,"revision":1,"created_at":1,"updated_at":2,"latest_seq":1}],"next_offset":200}}"#]
                    }
                    // The repeated cursor must terminate the provider loop,
                    // while this page's tombstone must remain in the result.
                    return [#"{"jsonrpc":"2.0","id":"\#(id)","result":{"rooms":[{"room_id":"room-gone","name":"Gone","members":[],"authority_gateway_id":"install:test","authority_epoch":1,"revision":2,"created_at":1,"updated_at":3,"disbanded_at":4,"latest_seq":2}],"next_offset":200}}"#]
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
        let gatewayID = GatewayID(rawValue: "test-gateway")
        let client = GatewayGroupsClient(gatewayID: gatewayID, transport: transport)
        let provider = HostedRoomProvider(gatewayID: gatewayID, client: client)

        let rooms = try await provider.rooms()

        XCTAssertEqual(rooms.map(\.id.key), ["room-live", "room-gone"])
        XCTAssertEqual(rooms.first(where: { $0.id.key == "room-gone" })?.isDeleted, true)
        XCTAssertEqual(listOffsets.values, [0, 200])
    }

    /// A gateway whose `groups.list` cursor ALWAYS advances (empty pages,
    /// `next_offset = offset + 200`) must not wedge the room-load path in
    /// unbounded requests: the provider's page cap terminates the drain.
    func testRoomsStopsAtThePageCapWhenTheCursorNeverStopsAdvancing() async throws {
        let listOffsets = LockedInts()
        let script = InProcessWebSocketServer.Script(
            onOpen: [readyFrame()],
            onText: { frame in
                guard let data = frame.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = object["id"] as? String,
                      let method = object["method"] as? String else { return [] }

                switch method {
                case "groups.capabilities":
                    return [#"{"jsonrpc":"2.0","id":"\#(id)","result":{"protocol_version":2,"driver":true,"persistent_process":true,"authority_gateway_id":"install:test","room_link":{"enabled":false},"features":[],"methods":["groups.capabilities","groups.list"],"max_log_limit":500}}"#]
                case "groups.list":
                    let params = object["params"] as? [String: Any]
                    let offset = (params?["offset"] as? NSNumber)?.intValue ?? 0
                    listOffsets.append(offset)
                    return [#"{"jsonrpc":"2.0","id":"\#(id)","result":{"rooms":[],"next_offset":\#(offset + 200)}}"#]
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
        let gatewayID = GatewayID(rawValue: "test-gateway")
        let client = GatewayGroupsClient(gatewayID: gatewayID, transport: transport)
        let provider = HostedRoomProvider(gatewayID: gatewayID, client: client)

        let rooms = try await provider.rooms()

        XCTAssertTrue(rooms.isEmpty)
        XCTAssertEqual(listOffsets.values.count, HostedRoomProvider.maxRoomListPages,
                       "the drain stops at the page cap instead of following the cursor forever")
        XCTAssertEqual(listOffsets.values.first, 0)
        XCTAssertEqual(listOffsets.values.last, (HostedRoomProvider.maxRoomListPages - 1) * 200)
        XCTAssertEqual(listOffsets.values, listOffsets.values.sorted(),
                       "offsets follow the advancing cursor")
    }
}

private final class LockedInts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    func append(_ value: Int) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct HostedTestTicketMinter: WSTicketMinting {
    let ticket: WSTicket
    func mintTicket() async throws -> WSTicket { ticket }
}
