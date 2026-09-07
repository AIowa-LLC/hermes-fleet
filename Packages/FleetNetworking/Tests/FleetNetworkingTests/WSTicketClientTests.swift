import XCTest
import FleetCore
import FleetNetworking

/// URLProtocol mock that answers `POST /api/auth/ws-ticket` from a scripted
/// response, capturing the request for assertions. No network is used.
final class TicketMintURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var body: Data = Data()
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class WSTicketClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TicketMintURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        TicketMintURLProtocol.capturedRequests = []
        session = nil
        super.tearDown()
    }

    func testMintTicketParsesEnvelope() async throws {
        TicketMintURLProtocol.statusCode = 200
        TicketMintURLProtocol.body = Data(#"{"ticket":"abc123","ttl_seconds":30}"#.utf8)

        let client = WSTicketClient(
            baseURL: URL(string: "http://192.168.50.58:9119")!,
            sessionToken: "loopback-token",
            urlSession: session
        )
        let ticket = try await client.mintTicket()

        XCTAssertEqual(ticket.token, "abc123")
        XCTAssertEqual(ticket.ttlSeconds, 30)

        let request = try XCTUnwrap(TicketMintURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "loopback-token")
    }

    func testMintTicketRejectsHTTPError() async {
        TicketMintURLProtocol.statusCode = 401
        TicketMintURLProtocol.body = Data("{}".utf8)

        let client = WSTicketClient(
            baseURL: URL(string: "http://192.168.50.58:9119")!,
            sessionToken: nil,
            urlSession: session
        )
        do {
            _ = try await client.mintTicket()
            XCTFail("expected HTTP error")
        } catch let error as AuthenticationError {
            // F1: HTTP statuses surface as the typed auth error so the
            // transport can classify 401 (re-auth) vs 404 (wrong surface).
            XCTAssertEqual(error, .httpStatus(401))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMintTicketRejectsMissingFields() async {
        TicketMintURLProtocol.statusCode = 200
        TicketMintURLProtocol.body = Data(#"{"ticket":"abc123"}"#.utf8)

        let client = WSTicketClient(
            baseURL: URL(string: "http://192.168.50.58:9119")!,
            sessionToken: nil,
            urlSession: session
        )
        do {
            _ = try await client.mintTicket()
            XCTFail("expected missing-TTL error")
        } catch let error as WSTicketClient.TicketMintError {
            XCTAssertEqual(error, .missingTTL)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMintTicketRejectsMalformedBody() async {
        TicketMintURLProtocol.statusCode = 200
        TicketMintURLProtocol.body = Data("not-json".utf8)

        let client = WSTicketClient(
            baseURL: URL(string: "http://192.168.50.58:9119")!,
            sessionToken: nil,
            urlSession: session
        )
        do {
            _ = try await client.mintTicket()
            XCTFail("expected malformed error")
        } catch let error as WSTicketClient.TicketMintError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAuthQueryItemUsesTicketParam() {
        let ticket = WSTicket(token: "abc123", ttlSeconds: 30)
        XCTAssertEqual(ticket.authQueryItem.name, "ticket")
        XCTAssertEqual(ticket.authQueryItem.value, "abc123")
    }
}
