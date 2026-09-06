import XCTest
import os
import FleetCore
import FleetNetworking

/// URLProtocol mock that routes by path to answer the three endpoints of the
/// P3 username/password flow hermetically (no network):
/// - `GET  /api/auth/providers`   → providers envelope
/// - `POST /auth/password-login`  → session Set-Cookie + {"ok":true}
/// - `POST /api/auth/ws-ticket`   → ticket envelope
/// Captures every request for assertions.
final class PasswordFlowURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) static var providersBody = Data(
        #"{"providers":[{"name":"basic","display_name":"Username & Password","supports_password":true}]}"#.utf8)
    nonisolated(unsafe) static var loginStatus: Int = 200
    nonisolated(unsafe) static var ticketBody = Data(#"{"ticket":"tkt-abc","ttl_seconds":30}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        let path = request.url?.path ?? ""
        let headers: [String: String]
        let body: Data
        let status: Int
        switch path {
        case "/api/auth/providers":
            headers = ["Content-Type": "application/json"]
            body = Self.providersBody
            status = 200
        case "/auth/password-login":
            headers = [
                "Content-Type": "application/json",
                // Over plain HTTP the gateway issues the bare access-token cookie.
                "Set-Cookie": "hermes_session_at=at-123; Max-Age=3600; Path=/",
            ]
            body = Data(#"{"ok":true,"next":"/"}"#.utf8)
            status = Self.loginStatus
        case "/api/auth/ws-ticket":
            headers = ["Content-Type": "application/json"]
            body = Self.ticketBody
            status = 200
        default:
            headers = [:]
            body = Data()
            status = 404
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PasswordLoginClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PasswordFlowURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        PasswordFlowURLProtocol.capturedRequests = []
        session = nil
        super.tearDown()
    }

    func testLoginDiscoversProviderThenCapturesSessionCookie() async throws {
        let client = PasswordLoginClient(
            baseURL: URL(string: "http://192.168.50.37:9120")!,
            urlSession: session)

        let cookie = try await client.login(username: "tony", password: "pw-123")

        // Session cookie captured (name matches the gateway's plain-HTTP name).
        XCTAssertEqual(cookie.name, "hermes_session_at")
        XCTAssertEqual(cookie.value, "at-123")
        XCTAssertEqual(cookie.headerValue, "hermes_session_at=at-123")

        // Providers request went out first (GET), then password-login (POST).
        let requests = PasswordFlowURLProtocol.capturedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/api/auth/providers")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].url?.path, "/auth/password-login")

        // The login body carries the provider + credentials (never echoed to
        // logs, but the request itself must contain them to authenticate).
        let bodyData = try XCTUnwrap(Self.body(of: requests[1]))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: String])
        XCTAssertEqual(json["provider"], "basic")
        XCTAssertEqual(json["username"], "tony")
        XCTAssertEqual(json["password"], "pw-123")
    }

    /// URLSession may carry the request body as an `httpBodyStream` rather
    /// than `httpBody`; read whichever is populated.
    private static func body(of request: URLRequest) -> Data? {
        if let httpBody = request.httpBody { return httpBody }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    func testLoginFailsOnBadCredentialsStatus() async {
        PasswordFlowURLProtocol.loginStatus = 401
        defer { PasswordFlowURLProtocol.loginStatus = 200 }
        let client = PasswordLoginClient(
            baseURL: URL(string: "http://192.168.50.37:9120")!,
            urlSession: session)
        do {
            _ = try await client.login(username: "tony", password: "wrong")
            XCTFail("expected login failure")
        } catch let error as AuthenticationError {
            // F1: HTTP statuses surface as the typed auth error (401 →
            // re-auth classification, not "unreachable").
            XCTAssertEqual(error, .httpStatus(401))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSessionCookiePrintableIsRedacted() {
        let cookie = SessionCookie(name: "hermes_session_at", value: "super-secret")
        XCTAssertEqual(cookie.description, "[REDACTED]")
        XCTAssertEqual(cookie.debugDescription, "SessionCookie(redacted)")
        XCTAssertFalse("\(cookie)".contains("super-secret"))
    }
}

final class PasswordFlowAuthenticatorTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PasswordFlowURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        PasswordFlowURLProtocol.capturedRequests = []
        session = nil
        super.tearDown()
    }

    private final class StubCredentialStore: CredentialStoring, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[String: GatewayCredential]>(initialState: [:])
        func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
            lock.withLock { $0[gatewayID.rawValue] = credential }
        }
        func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
            lock.withLock { $0[gatewayID.rawValue] }
        }
        func deleteCredential(for gatewayID: GatewayID) async throws {
            _ = lock.withLock { $0.removeValue(forKey: gatewayID.rawValue) }
        }
    }

    /// The .usernamePassword strategy on the real authenticator: loads the
    /// stored username+password, exchanges for a session cookie, mints a WS
    /// ticket, and returns `.ticket` → `?ticket=`.
    func testAuthenticatorUsernamePasswordPathMintsTicket() async throws {
        let store = StubCredentialStore()
        try await store.saveCredential(
            GatewayCredential(rawValue: "pw-123", username: "tony"),
            for: GatewayID(rawValue: "lan-gateway"))

        let auth = GatewayAuthenticator(
            gatewayID: GatewayID(rawValue: "lan-gateway"),
            strategy: .usernamePassword,
            credentialStore: store,
            baseURL: URL(string: "http://192.168.50.37:9120")!,
            urlSession: session)

        let result = try await auth.authenticate()
        guard case .ticket(let token) = result else {
            return XCTFail("expected ticket auth, got \(result)")
        }
        XCTAssertEqual(token.rawValue, "tkt-abc")

        // The ticket mint carried the session cookie (not the token header).
        let requests = PasswordFlowURLProtocol.capturedRequests
        XCTAssertEqual(requests.count, 3)
        let mint = requests.last!
        XCTAssertEqual(mint.url?.path, "/api/auth/ws-ticket")
        XCTAssertEqual(mint.value(forHTTPHeaderField: "Cookie"), "hermes_session_at=at-123")
        XCTAssertNil(mint.value(forHTTPHeaderField: "X-Hermes-Session-Token"))
    }

    func testAuthenticatorUsernamePasswordMissingUsernameThrows() async throws {
        // A token-only credential stored under a .usernamePassword gateway is
        // a config error: no username half to log in with.
        let store = StubCredentialStore()
        try await store.saveCredential(
            GatewayCredential(rawValue: "just-a-token"),
            for: GatewayID(rawValue: "lan-gateway"))
        let auth = GatewayAuthenticator(
            gatewayID: GatewayID(rawValue: "lan-gateway"),
            strategy: .usernamePassword,
            credentialStore: store,
            baseURL: URL(string: "http://192.168.50.37:9120")!)
        do {
            _ = try await auth.authenticate()
            XCTFail("expected missingUsername")
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .missingUsername)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
