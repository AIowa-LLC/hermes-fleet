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

    func testCronURLsKeepPrefixAndEncodeIdsInsideIt() throws {
        for base in [scoped, scopedSlash] {
            XCTAssertEqual(try XCTUnwrap(DashboardCronClient.jobsURL(base: base, profile: "p")).path, "/gw/api/cron/jobs")
            XCTAssertEqual(try XCTUnwrap(DashboardCronClient.jobURL(base: base, id: "j1", profile: nil)).path, "/gw/api/cron/jobs/j1")
            XCTAssertEqual(try XCTUnwrap(DashboardCronClient.jobActionURL(base: base, id: "j1", action: "pause", profile: nil)).path,
                           "/gw/api/cron/jobs/j1/pause")
            XCTAssertEqual(try XCTUnwrap(DashboardCronClient.runsURL(base: base, id: "j1", profile: nil, limit: 5)).path,
                           "/gw/api/cron/jobs/j1/runs")
            XCTAssertEqual(try XCTUnwrap(DashboardCronClient.deliveryTargetsURL(base: base)).path, "/gw/api/cron/delivery-targets")
        }
        // An id containing a slash must stay ONE segment under the prefix.
        let encoded = try XCTUnwrap(DashboardCronClient.jobURL(base: scoped, id: "a/../b", profile: nil))
        XCTAssertTrue(encoded.absoluteString.hasPrefix("https://example.test/gw/api/cron/jobs/"))
        // Raw (undecoded) path: the id adds exactly ONE segment under the prefix.
        let rawSegments = encoded.absoluteString.dropFirst("https://example.test".count).split(separator: "/", omittingEmptySubsequences: false)
        XCTAssertEqual(rawSegments.count, 6, "\(encoded.absoluteString)") // "", gw, api, cron, jobs, <id>
        XCTAssertFalse(encoded.path.hasPrefix("/api/"), "never escapes to the origin root")
        XCTAssertEqual(encoded.host, "example.test")
    }
}
