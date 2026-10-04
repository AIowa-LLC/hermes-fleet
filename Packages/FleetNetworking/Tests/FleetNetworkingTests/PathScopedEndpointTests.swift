import XCTest
import Foundation
import FleetCore
@testable import FleetNetworking

/// A path-scoped gateway (`https://host/gw`) must keep its prefix on every
/// request that carries its credential; none may fall back to the origin root.
final class PathScopedEndpointTests: XCTestCase {
    private let scoped = URL(string: "https://example.test/gw")!
    private let scopedSlash = URL(string: "https://example.test/gw/")!
    private let root = URL(string: "https://example.test")!

    func testJoinKeepsPrefix() {
        XCTAssertEqual(GatewayEndpoint.path(joining: "/api/x", onto: scoped), "/gw/api/x")
        XCTAssertEqual(GatewayEndpoint.path(joining: "/api/x", onto: scopedSlash), "/gw/api/x")
        XCTAssertEqual(GatewayEndpoint.path(joining: "api/x", onto: root), "/api/x")
        XCTAssertEqual(GatewayEndpoint.path(joining: "/api/x", onto: root), "/api/x")
    }

    func testWebSocketURLKeepsPrefix() throws {
        let url = try XCTUnwrap(GatewayWebSocketTransport.buildWebSocketURL(
            base: scoped, path: "/api/ws", authentication: .none))
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "example.test")
        XCTAssertEqual(url.path, "/gw/api/ws")
    }

    func testKanbanURLsKeepPrefix() throws {
        XCTAssertEqual(
            try XCTUnwrap(KanbanEventStreamClient.buildBoardURL(base: scoped, board: nil)).path,
            "/gw/api/plugins/kanban/board")
        XCTAssertEqual(
            KanbanEventStreamClient.buildBoardsListURL(base: scoped).path,
            "/gw/api/plugins/kanban/boards")
        XCTAssertEqual(
            try XCTUnwrap(KanbanEventStreamClient.buildEventsURL(
                base: scoped, since: 0, authentication: .none)).path,
            "/gw/api/plugins/kanban/events")
    }
}
