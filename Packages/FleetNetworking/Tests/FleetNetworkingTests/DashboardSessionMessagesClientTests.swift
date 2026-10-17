import XCTest
import FleetCore
@testable import FleetNetworking

/// #188 — `DashboardSessionMessagesClient` contract tests. Fixtures are
/// SYNTHETIC raw-row payloads shaped after the Hermes 0.22.1 REST route
/// (`GET /api/sessions/{id}/messages`); no live gateway is required.
final class DashboardSessionMessagesClientTests: XCTestCase {

    // MARK: - URL building

    func testMessagesURLCarriesOrderLimitOffsetAndInlineImagesFlag() throws {
        let base = try XCTUnwrap(URL(string: "https://gw.example.invalid:8443"))
        let url = try XCTUnwrap(DashboardSessionMessagesClient.messagesURL(
            base: base, sessionID: "sess.abc_123-4", profile: "default", offset: 200, limit: 200))
        XCTAssertEqual(url.path, "/api/sessions/sess.abc_123-4/messages")
        let items = try queryItems(url)
        XCTAssertEqual(items["order"], "latest")
        XCTAssertEqual(items["limit"], "200")
        XCTAssertEqual(items["offset"], "200")
        XCTAssertEqual(items["inline_images"], "false")
        XCTAssertEqual(items["profile"], "default")
    }

    func testMessagesURLClampsLimitToServerWindowAndOffsetToZero() throws {
        let base = try XCTUnwrap(URL(string: "https://gw.example.invalid"))
        let low = try XCTUnwrap(DashboardSessionMessagesClient.messagesURL(
            base: base, sessionID: "s1", profile: nil, offset: -7, limit: 0))
        XCTAssertEqual(try queryItems(low)["limit"], "1")
        XCTAssertEqual(try queryItems(low)["offset"], "0")
        let high = try XCTUnwrap(DashboardSessionMessagesClient.messagesURL(
            base: base, sessionID: "s1", profile: nil, offset: 0, limit: 900))
        XCTAssertEqual(try queryItems(high)["limit"], "500")
    }

    func testMessagesURLOmitsProfileWhenNilOrBlank() throws {
        let base = try XCTUnwrap(URL(string: "https://gw.example.invalid"))
        for profile in [nil, ""] as [String?] {
            let url = try XCTUnwrap(DashboardSessionMessagesClient.messagesURL(
                base: base, sessionID: "s1", profile: profile, offset: 0, limit: 10))
            XCTAssertNil(try queryItems(url)["profile"], "nil/blank profile must not ride the query")
        }
    }

    func testMessagesURLRejectsUnsafeSessionAndProfile() throws {
        let base = try XCTUnwrap(URL(string: "https://gw.example.invalid"))
        XCTAssertNil(DashboardSessionMessagesClient.messagesURL(
            base: base, sessionID: "../other", profile: nil, offset: 0, limit: 10))
        XCTAssertNil(DashboardSessionMessagesClient.messagesURL(
            base: base, sessionID: "s1", profile: "a/b", offset: 0, limit: 10))
    }

    // MARK: - Row decoding

    func testStringContentDecodesWithRowIDAndTimestamp() throws {
        let messages = DashboardSessionMessagesClient.decodeRows([
            row(["id": 41, "role": "user", "content": "hello there", "timestamp": 1_700_000_000.5]),
        ])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].text, "hello there")
        XCTAssertEqual(messages[0].rowID, "41")
        XCTAssertEqual(messages[0].timestamp, 1_700_000_000.5)
    }

    func testDisplayContentIsPreferredOverContent() throws {
        let messages = DashboardSessionMessagesClient.decodeRows([
            row(["id": 2, "role": "assistant", "content": "raw", "display_content": "shown"]),
            row(["id": 3, "role": "assistant", "content": "fallback", "display_content": ""]),
        ])
        XCTAssertEqual(messages.map(\.text), ["shown", "fallback"])
    }

    func testPartsJoinTextAndMarkImages() throws {
        let messages = DashboardSessionMessagesClient.decodeRows([
            row(["id": 5, "role": "user", "content": [
                ["type": "text", "text": "part one"],
                ["type": "image_url", "image_url": ["url": "data:redacted"]],
                ["type": "text", "text": "part two"],
            ]]),
        ])
        XCTAssertEqual(messages.first?.text, "part one\n[image]\npart two")
    }

    func testHiddenAndContentlessRowsAreSkipped() throws {
        let messages = DashboardSessionMessagesClient.decodeRows([
            row(["id": 1, "role": "system", "content": "internal", "display_kind": "hidden"]),
            row(["id": 2, "role": "user", "content": ""]),
            row(["id": 3, "role": "assistant", "content": "kept"]),
        ])
        XCTAssertEqual(messages.map(\.rowID), ["3"])
    }

    func testToolRowsResolveNameFromSamePageToolCalls() throws {
        let messages = DashboardSessionMessagesClient.decodeRows([
            row(["id": 10, "role": "assistant", "content": "", "tool_calls": [
                ["id": "call_a", "function": ["name": "terminal", "arguments": "{}"]],
            ]]),
            row(["id": 11, "role": "tool", "tool_call_id": "call_a", "content": "out"]),
            row(["id": 12, "role": "tool", "tool_name": "read_file", "content": "x"]),
            row(["id": 13, "role": "tool", "tool_call_id": "call_unknown", "content": "y"]),
        ])
        XCTAssertEqual(messages.map(\.toolName), ["terminal", "read_file", "tool"])
        XCTAssertEqual(messages.map(\.role), [.tool, .tool, .tool])
    }

    func testReactionsAndReasoningFallbacksDecode() throws {
        let messages = DashboardSessionMessagesClient.decodeRows([
            row([
                "id": 20, "role": "assistant", "content": "answer",
                "reasoning_content": "thinking it through",
                "display_metadata": ["reactions": [
                    ["emoji": "👍", "author": "user", "at": 12.0],
                ]],
            ]),
        ])
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(message.reasoning, "thinking it through")
        XCTAssertEqual(message.reactions?.map(\.emoji), ["👍"])
    }

    // MARK: - Page decode

    func testPageReturnedIsRawCountNotDecodedCount() throws {
        let body = try pageBody(rows: [
            row(["id": 1, "role": "user", "content": "a"]),
            row(["id": 2, "role": "system", "content": "b", "display_kind": "hidden"]),
            row(["id": 3, "role": "user", "content": ""]),
        ], returned: 3)
        let page = try DashboardSessionMessagesClient.decodePage(body, offset: 0, limit: 3)
        XCTAssertEqual(page.returned, 3, "returned counts raw rows before client filtering")
        XCTAssertEqual(page.messages.count, 1)
        XCTAssertTrue(page.hasOlder, "a full raw page means older rows may exist")
    }

    func testShortPageHasNoOlder() throws {
        let body = try pageBody(rows: [row(["id": 1, "role": "user", "content": "a"])], returned: 1)
        let page = try DashboardSessionMessagesClient.decodePage(body, offset: 0, limit: 200)
        XCTAssertFalse(page.hasOlder)
    }

    func testMalformedPageBodyThrowsMalformed() {
        XCTAssertThrowsError(try DashboardSessionMessagesClient.decodePage(Data("[]".utf8), offset: 0, limit: 1)) { error in
            guard case SessionHistoryPagingError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    // MARK: - Status mapping

    func testStatusMapping() {
        let notFoundRoute = Data(#"{"detail":"Not Found"}"#.utf8)
        let unknownSession = Data(#"{"detail":"unknown session"}"#.utf8)
        XCTAssertEqual(DashboardSessionMessagesClient.mapStatus(404, body: notFoundRoute), .unsupported("this gateway has no paged history route"))
        XCTAssertEqual(DashboardSessionMessagesClient.mapStatus(404, body: Data()), .unsupported("this gateway has no paged history route"))
        XCTAssertEqual(DashboardSessionMessagesClient.mapStatus(404, body: unknownSession), .sessionNotFound("the gateway does not know this session"))
        XCTAssertEqual(DashboardSessionMessagesClient.mapStatus(405, body: Data()), .unsupported("this gateway does not support paged history"))
        XCTAssertEqual(DashboardSessionMessagesClient.mapStatus(501, body: Data()), .unsupported("this gateway does not support paged history"))
        XCTAssertEqual(DashboardSessionMessagesClient.mapStatus(401, body: Data()), .unauthorized)
        XCTAssertEqual(DashboardSessionMessagesClient.mapStatus(403, body: Data()), .unauthorized)
        XCTAssertEqual(DashboardSessionMessagesClient.mapStatus(400, body: Data()), .malformed("the gateway rejected the page request"))
        XCTAssertEqual(DashboardSessionMessagesClient.mapStatus(500, body: Data()), .transport("the gateway answered HTTP 500"))
    }

    // MARK: - End to end through URLProtocol

    func testFetchLatestPageSendsAuthenticatedGETAndDecodes() async throws {
        let body = try pageBody(rows: [
            row(["id": 7, "role": "user", "content": "newest"]),
        ], returned: 1)
        SessionMessagesURLProtocol.lastRequest = nil
        SessionMessagesURLProtocol.handler = { _ in (200, body) }
        defer { SessionMessagesURLProtocol.handler = nil }
        let client = try makeClient(credential: .sessionTokenHeader("synthetic-token"))

        let page = try await client.fetchLatestPage(sessionID: "sess.live", profile: "default", offset: 0, limit: 200)

        XCTAssertEqual(page.messages.map(\.text), ["newest"])
        XCTAssertEqual(page.returned, 1)
        let request = try XCTUnwrap(SessionMessagesURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/sessions/sess.live/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "synthetic-token")
    }

    func testFetchLatestPageMapsUnsupportedRouteWithoutLeakingBody() async throws {
        SessionMessagesURLProtocol.handler = { _ in (404, Data(#"{"detail":"Not Found"}"#.utf8)) }
        defer { SessionMessagesURLProtocol.handler = nil }
        let client = try makeClient(credential: .none)
        do {
            _ = try await client.fetchLatestPage(sessionID: "sess.live", profile: nil, offset: 0, limit: 200)
            XCTFail("expected unsupported")
        } catch SessionHistoryPagingError.unsupported {
            // expected
        }
    }

    func testFetchRejectsUnsafeSessionBeforeAnyRequest() async throws {
        SessionMessagesURLProtocol.lastRequest = nil
        SessionMessagesURLProtocol.handler = { _ in (200, Data("{}".utf8)) }
        defer { SessionMessagesURLProtocol.handler = nil }
        let client = try makeClient(credential: .none)
        do {
            _ = try await client.fetchLatestPage(sessionID: "../escape", profile: nil, offset: 0, limit: 10)
            XCTFail("expected sessionNotFound")
        } catch SessionHistoryPagingError.sessionNotFound {
            XCTAssertNil(SessionMessagesURLProtocol.lastRequest, "no request may be sent for an unsafe key")
        }
    }

    // MARK: - Helpers

    private func makeClient(credential: KanbanEventStreamClient.HTTPCredential) throws -> DashboardSessionMessagesClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionMessagesURLProtocol.self]
        return DashboardSessionMessagesClient(
            gatewayID: GatewayID(rawValue: "workstation"),
            baseURL: try XCTUnwrap(URL(string: "https://gw.example.invalid:8443")),
            httpCredential: { credential },
            urlSession: URLSession(configuration: config))
    }

    private func row(_ object: [String: Any]) -> JSONValue {
        JSONValue(object)
    }

    private func pageBody(rows: [JSONValue], returned: Int) throws -> Data {
        let body: [String: Any] = [
            "session_id": "sess.live",
            "profile": "default",
            "messages": rows.map(rowObject),
            "pagination": ["limit": 200, "offset": 0, "order": "latest", "returned": returned],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func rowObject(_ value: JSONValue) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) ?? [:]
    }

    private func queryItems(_ url: URL) throws -> [String: String] {
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var result: [String: String] = [:]
        for item in comps.queryItems ?? [] { result[item.name] = item.value }
        return result
    }
}

/// URLProtocol mock for the paged-history REST route. Synthetic responses only.
final class SessionMessagesURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
