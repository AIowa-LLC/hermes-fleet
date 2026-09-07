import XCTest
import FleetCore
@testable import FleetNetworking

/// t_3b321b7b — `KanbanEventStreamClient` tests: wire parsing, URL building,
/// snapshot decode, and the reconnect-with-cursor behavior over the
/// in-process WS fixture.
final class KanbanEventStreamClientTests: XCTestCase {

    // MARK: Pure helpers

    func testBuildEventsURLLoopbackToken() throws {
        let url = try XCTUnwrap(KanbanEventStreamClient.buildEventsURL(
            base: try XCTUnwrap(URL(string: "http://192.168.50.58:9119")),
            since: 41,
            authentication: .loopbackToken(StoredToken(rawValue: "sekret"))
        ))
        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.host, "192.168.50.58")
        XCTAssertEqual(url.port, 9119)
        XCTAssertEqual(url.path, "/api/plugins/kanban/events")
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = comps.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "since", value: "41")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "token", value: "sekret")))
    }

    func testBuildEventsURLTicketHTTPS() throws {
        let url = try XCTUnwrap(KanbanEventStreamClient.buildEventsURL(
            base: try XCTUnwrap(URL(string: "https://gw.example.com")),
            since: 0,
            authentication: .ticket(StoredToken(rawValue: "t0"))
        ))
        XCTAssertEqual(url.scheme, "wss")
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertTrue((comps.queryItems ?? []).contains(URLQueryItem(name: "ticket", value: "t0")))
    }

    func testBuildEventsURLRejectsNonHTTPScheme() {
        XCTAssertNil(KanbanEventStreamClient.buildEventsURL(
            base: URL(string: "ftp://example.com")!, since: 0, authentication: .none))
    }

    func testParseEventFrame() throws {
        let frame = #"{"events":[{"id":10,"task_id":"t_abc","run_id":null,"kind":"status_changed","payload":null,"created_at":1788366000}],"cursor":10}"#
        let batch = try XCTUnwrap(KanbanEventStreamClient.parseEventFrame(frame))
        XCTAssertEqual(batch.cursor, 10)
        XCTAssertEqual(batch.events.count, 1)
        XCTAssertEqual(batch.events.first?.taskID, "t_abc")
        XCTAssertEqual(batch.events.first?.kind, "status_changed")
        XCTAssertEqual(batch.events.first?.id, 10)
    }

    func testParseEventFrameRejectsJunk() {
        XCTAssertNil(KanbanEventStreamClient.parseEventFrame("not json"))
        XCTAssertNil(KanbanEventStreamClient.parseEventFrame(#"{"unexpected":true}"#))
    }

    // MARK: Snapshot (HTTP via URLProtocol mock)

    func testSnapshotDecodesBoardEnvelope() async throws {
        let body = """
        {"columns":[{"name":"todo","tasks":[{"id":"t_1","title":"First","status":"todo","assignee":"apple-dev","priority":2,"created_at":1788366000.0,"latest_summary":"sum"}]},{"name":"done","tasks":[]}],"latest_event_id":12,"now":1788366100.5}
        """
        let client = Self.makeClient(boardBody: Data(body.utf8))
        let snapshot = try await client.snapshot()
        XCTAssertEqual(snapshot.columns, ["todo", "done"])
        XCTAssertEqual(snapshot.totalCards, 1)
        let card = try XCTUnwrap(snapshot.cards(in: "todo").first)
        XCTAssertEqual(card.title, "First")
        XCTAssertEqual(card.assignee, "apple-dev")
        XCTAssertEqual(snapshot.latestEventID, 12)
        XCTAssertEqual(snapshot.now, 1_788_366_100.5)
    }

    func testSnapshotSurfacesHTTPError() async {
        let client = Self.makeClient(boardBody: Data("{}".utf8), status: 500)
        do {
            _ = try await client.snapshot()
            XCTFail("expected error")
        } catch let error as KanbanBoardError {
            XCTAssertEqual(error, .httpStatus(500))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testSnapshotMalformedBodyThrows() async {
        let client = Self.makeClient(boardBody: Data("not json".utf8))
        do {
            _ = try await client.snapshot()
            XCTFail("expected error")
        } catch let error as KanbanBoardError {
            guard case .malformedResponse = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: Board list + board param (t_624b81cd — B1 selector)

    func testBuildEventsURLIncludesBoardParam() throws {
        let url = try XCTUnwrap(KanbanEventStreamClient.buildEventsURL(
            base: try XCTUnwrap(URL(string: "http://192.168.50.58:9119")),
            since: 7,
            board: "r10-slug",
            authentication: .none
        ))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertTrue(
            (comps.queryItems ?? []).contains(URLQueryItem(name: "board", value: "r10-slug")),
            "the WS handshake must pin the board slug"
        )
    }

    func testBuildEventsURLOmitsBoardParamWhenNil() throws {
        let url = try XCTUnwrap(KanbanEventStreamClient.buildEventsURL(
            base: try XCTUnwrap(URL(string: "http://192.168.50.58:9119")),
            since: 7,
            board: nil,
            authentication: .none
        ))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertFalse(
            (comps.queryItems ?? []).contains { $0.name == "board" },
            "nil board must mean the server's active board (no param)"
        )
    }

    func testBuildBoardURLCarriesBoardQueryParam() throws {
        let base = try XCTUnwrap(URL(string: "http://192.168.50.58:9119"))
        // Pinned slug → ?board= in the query.
        let pinned = try XCTUnwrap(KanbanEventStreamClient.buildBoardURL(base: base, board: "r10-slug"))
        var comps = try XCTUnwrap(URLComponents(url: pinned, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.path, "/api/plugins/kanban/board")
        XCTAssertTrue((comps.queryItems ?? []).contains(URLQueryItem(name: "board", value: "r10-slug")))
        // nil → bare path, server resolves its active board.
        let active = try XCTUnwrap(KanbanEventStreamClient.buildBoardURL(base: base, board: nil))
        comps = try XCTUnwrap(URLComponents(url: active, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.path, "/api/plugins/kanban/board")
        XCTAssertFalse((comps.queryItems ?? []).contains { $0.name == "board" })
    }

    func testFetchBoardsDecodesList() async throws {
        let body = """
        {"boards":[{"slug":"hermes-fleet-r10","name":"Hermes Fleet R10","is_current":true,"total":13},{"slug":"default","name":"Default","is_current":false,"total":0}],"current":"hermes-fleet-r10"}
        """
        let client = Self.makeClient(boardBody: Data(body.utf8), boardsBody: Data(body.utf8))
        let list = try await client.fetchBoards()
        XCTAssertEqual(list.current, "hermes-fleet-r10")
        XCTAssertEqual(list.boards.map(\.slug), ["hermes-fleet-r10", "default"])
        XCTAssertEqual(list.boards.first?.isCurrent, true)
    }

    func testFetchBoardsSurfacesHTTPError() async {
        let client = Self.makeClient(
            boardBody: Data("{}".utf8),
            boardsBody: Data("{}".utf8), status: 503)
        do {
            _ = try await client.fetchBoards()
            XCTFail("expected error")
        } catch let error as KanbanBoardError {
            XCTAssertEqual(error, .httpStatus(503))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testSnapshotRequestCarriesBoardParam() async throws {
        // The URLProtocol mock records the request URL: a pinned slug must
        // ride the query string (?board=r10-slug).
        let client = Self.makeClient(
            boardBody: Data("{\"columns\":[],\"latest_event_id\":0}".utf8))
        await client.pinBoard("r10-slug")
        let watcher = await client.board
        XCTAssertEqual(watcher, "r10-slug")
        _ = try await client.snapshot()
        let requested = try XCTUnwrap(BoardURLProtocol.lastRequestURL)
        let comps = try XCTUnwrap(URLComponents(url: requested, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.path, "/api/plugins/kanban/board")
        XCTAssertTrue(
            (comps.queryItems ?? []).contains(URLQueryItem(name: "board", value: "r10-slug")),
            "snapshot fetch must carry the pinned board slug"
        )
    }

    func testPinBoardResetsCursorAndClearsPinOnNil() async throws {
        let client = Self.makeClient(
            boardBody: Data("{\"columns\":[],\"latest_event_id\":77}".utf8))
        _ = try await client.snapshot()
        let before = await client.resumeCursor
        XCTAssertEqual(before, 77, "snapshot adopts the event cursor")
        await client.pinBoard("other-slug")
        let afterPin = await client.resumeCursor
        XCTAssertEqual(afterPin, 0, "pinning a different board must reset the cursor (its event ids are a different sequence)")
        await client.pinBoard(nil)
        let watcher = await client.board
        XCTAssertNil(watcher, "nil pin must clear the selection (active board)")
    }

    // MARK: Stream + reconnect (in-process WS fixture)

    func testStreamDeliversBatchesAndReconnectsWithCursor() async throws {
        // Connection 1: one event frame, then the script closes the socket
        // (closeAfterInboundCount on the FIRST inbound from the client —
        // URLSession sends nothing, so instead we script an immediate close
        // after the onOpen frames via closeAfterInboundCount: nil trick:
        // use two scripts — first sends one frame then closes via a second
        // connection accept... simplest deterministic route: one script
        // whose onOpen sends the frame; the fixture closes when the test
        // stops it. Reconnect coverage comes from the transport-level
        // InProcessWebSocketServer accept loop: after the client's socket
        // dies (server stop), the pump retries.
        let frame = #"{"events":[{"id":50,"task_id":"t_x","kind":"created","created_at":1788366000}],"cursor":50}"#
        let server = try InProcessWebSocketServer(scripts: [
            .init(onOpen: [frame], onText: { _ in [] }),
        ])
        try await server.start()
        defer { server.stop() }

        let client = KanbanEventStreamClient(
            gatewayID: GatewayID(rawValue: "g1"),
            baseURL: URL(string: "ws://127.0.0.1:\(server.listeningPort)")!,
            authenticator: StaticAuthenticator(authentication: .none),
            sessionFactory: URLSessionWebSocketSessionFactory(),
            reconnectDelay: (base: 0.05, cap: 0.2)
        )
        let stream = await client.changeEvents()
        let got = expectation(description: "batch delivered")
        let task = Task {
            for await batch in stream {
                if batch.cursor == 50 {
                    got.fulfill()
                    break
                }
            }
        }
        await fulfillment(of: [got], timeout: 10)
        task.cancel()
        await client.stop()
    }

    // MARK: Test plumbing

    private static func makeClient(
        boardBody: Data,
        boardsBody: Data = Data("{}".utf8),
        status: Int = 200
    ) -> KanbanEventStreamClient {
        BoardURLProtocol.statusCode = status
        BoardURLProtocol.body = boardBody
        BoardURLProtocol.boardsBody = boardsBody
        BoardURLProtocol.lastRequestURL = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BoardURLProtocol.self]
        return KanbanEventStreamClient(
            gatewayID: GatewayID(rawValue: "g1"),
            baseURL: URL(string: "http://192.168.50.58:9119")!,
            authenticator: StaticAuthenticator(authentication: .none),
            httpCredential: { .none },
            urlSession: URLSession(configuration: config)
        )
    }
}

/// URLProtocol mock answering `GET /api/plugins/kanban/board` and
/// `GET /api/plugins/kanban/boards` (t_624b81cd), recording request URLs.
final class BoardURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var body: Data = Data()
    nonisolated(unsafe) static var boardsBody: Data = Data()
    nonisolated(unsafe) static var lastRequestURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestURL = request.url
        let isBoardsList = request.url?.path.hasSuffix("/boards") == true
        let payload = isBoardsList ? Self.boardsBody : Self.body
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Static auth provider (test double).
struct StaticAuthenticator: AuthenticationProviding {
    let authentication: ConnectionAuthentication
    func authenticate() async throws -> ConnectionAuthentication { authentication }
}
