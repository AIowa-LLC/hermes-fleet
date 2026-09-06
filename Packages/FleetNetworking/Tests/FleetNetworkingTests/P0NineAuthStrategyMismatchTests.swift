import XCTest
import os
import FleetCore
import FleetNetworking

/// P0-9 (t_635bbf99) — tunnel auth-strategy mismatch classification.
///
/// The QA-verified live-wire defect: the converged tunnel
/// (the HTTPS gateway) authenticates ONLY via the username/password
/// cookie flow. A stored token strategy mints ws-ticket with the
/// `X-Hermes-Session-Token` header, and the tunnel answers
/// HTTP 401 `{"reason":"no_cookie"}`. Before P0-9 that collapsed into
/// `AuthenticationError.httpStatus(401)` → generic "needs you to sign in /
/// Re-authenticate" copy — a strategy mismatch reported as a credential
/// problem, with guidance (re-authenticate with the same token) that can
/// never succeed.
///
/// These tests pin the honest chain:
///   WSTicketClient 401 body {"reason":"no_cookie"}
///     → AuthenticationError.rejected(.noCookie)
///     → TransportError.authStrategyRejected(.noCookie)
///     → GatewayConnectivityError.authStrategyRejected(.noCookie)
///     → GatewayStatus.authenticationRequired
///     → GatewayFailureCopy: "needs username & password sign-in — not a token"
/// plus the working path: the username/password strategy performs
/// password-login → cookie mint → ticket and succeeds against the tunnel.
final class P0NineAuthStrategyMismatchTests: XCTestCase {

    // MARK: - WSTicketClient: the rejection body is parsed, not flattened

    func testMintTicket401NoCookieBodyThrowsRejectedNoCookie() async {
        // The exact tunnel response (QA live-wire evidence): HTTP 401 with a
        // JSON body naming the cause. It must surface as the TYPED rejection,
        // not the bare httpStatus(401) a body-less rejection yields.
        TicketMintURLProtocol.statusCode = 401
        TicketMintURLProtocol.body = Data(#"{"reason":"no_cookie"}"#.utf8)
        TicketMintURLProtocol.capturedRequests = []
        defer { TicketMintURLProtocol.capturedRequests = [] }

        let client = WSTicketClient(
            baseURL: URL(string: "https://fleet.example.dev")!,
            sessionToken: "a-session-token",
            urlSession: stubbedSession()
        )
        do {
            _ = try await client.mintTicket()
            XCTFail("expected rejected(noCookie)")
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .rejected(reason: .noCookie),
                           "401 with a named reason must carry the cause, not flatten to httpStatus(401)")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMintTicket401EmptyBodyStillSurfacesHTTPStatus() async {
        // Backward-compatible fallback: a rejection the server did NOT
        // explain keeps the F1 bare-status classification.
        TicketMintURLProtocol.statusCode = 401
        TicketMintURLProtocol.body = Data()
        TicketMintURLProtocol.capturedRequests = []
        defer { TicketMintURLProtocol.capturedRequests = [] }

        let client = WSTicketClient(
            baseURL: URL(string: "https://fleet.example.dev")!,
            sessionToken: "a-session-token",
            urlSession: stubbedSession()
        )
        do {
            _ = try await client.mintTicket()
            XCTFail("expected httpStatus(401)")
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .httpStatus(401))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRejectionReasonParsingNeverCarriesSecrets() {
        // The parsed reason is a server-echoed classification word. Known
        // words decode; unknown words become .unknown; garbage/nil bodies
        // fall back to nil (bare status).
        XCTAssertEqual(WSTicketClient.rejectionReason(in: Data(#"{"reason":"no_cookie"}"#.utf8)), .noCookie)
        XCTAssertEqual(WSTicketClient.rejectionReason(in: Data(#"{"reason":"server_on_fire"}"#.utf8)), .unknown)
        XCTAssertNil(WSTicketClient.rejectionReason(in: Data("not json".utf8)))
        XCTAssertNil(WSTicketClient.rejectionReason(in: nil))
        XCTAssertNil(WSTicketClient.rejectionReason(in: Data(#"{"reason":""}"#.utf8)))
    }

    // MARK: - Transport + connection: the full classification chain

    func testTransportConnectClassifiesStrategyRejection() async throws {
        // A session-token gateway whose mint is rejected "no_cookie" must
        // classify as the typed strategy rejection end-to-end through
        // connect() — the exact defect path (GatewayAuthenticator →
        // WSTicketClient → transport → SingleGatewayConnection).
        TicketMintURLProtocol.statusCode = 401
        TicketMintURLProtocol.body = Data(#"{"reason":"no_cookie"}"#.utf8)
        TicketMintURLProtocol.capturedRequests = []
        defer { TicketMintURLProtocol.capturedRequests = [] }

        let store = StubCredentialStore()
        try await store.saveCredential(
            GatewayCredential(rawValue: "a-session-token"),
            for: GatewayID(rawValue: "tunnel")
        )
        let authenticator = GatewayAuthenticator(
            gatewayID: GatewayID(rawValue: "tunnel"),
            strategy: .sessionToken,
            credentialStore: store,
            baseURL: URL(string: "https://fleet.example.dev")!,
            urlSession: stubbedSession()
        )
        let transport = GatewayWebSocketTransport(
            baseURL: URL(string: "https://fleet.example.dev")!,
            authentication: authenticator,
            configuration: TransportConfiguration(
                pingInterval: .seconds(30),
                inboundDeadline: .seconds(30),
                connectTimeout: .seconds(2),
                requestTimeout: .seconds(2))
        )
        let connection = SingleGatewayConnection(
            gatewayID: GatewayID(rawValue: "tunnel"),
            displayName: "Tunnel",
            endpoint: URL(string: "https://fleet.example.dev")!,
            transport: transport
        )
        do {
            try await connection.connect()
            XCTFail("expected authStrategyRejected(.noCookie)")
        } catch let error as GatewayConnectivityError {
            XCTAssertEqual(error, .authStrategyRejected(.noCookie),
                           "the transport must wrap the typed rejection, not flatten it to authSurfaceHTTP(401)")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testStrategyRejectionClassifiesAuthenticationRequired() {
        // The STATUS stays auth-required (the user must fix auth), but the
        // cause-specific guidance lives in the detail + failure copy.
        XCTAssertEqual(
            GatewayStatus(connectivityError: .authStrategyRejected(.noCookie)),
            .authenticationRequired)
    }

    // MARK: - The working path: username/password against the cookie-only tunnel

    func testUsernamePasswordStrategyIsTheTunnelsWorkingPath() async throws {
        // QA live-wire evidence: against the cookie-only tunnel the ONLY
        // working sequence is POST /auth/password-login → session cookie →
        // POST /api/auth/ws-ticket (cookie, NO token header) → ticket. This
        // scripts that exact two-rest-call sequence and asserts the strategy
        // performs it in order.
        TicketSequenceURLProtocol.responses = [
            // GET /api/auth/providers → password-capable provider "basic"
            .init(status: 200, body: Data(#"{"providers":[{"name":"basic","supports_password":true}]}"#.utf8)),
            // POST /auth/password-login → 200 + session cookie
            .init(status: 200, body: Data(#"{"ok":true,"next":"/"}"#.utf8), setCookie: "hermes_session_at=sekrit-session"),
            // POST /api/auth/ws-ticket (with cookie) → ticket
            .init(status: 200, body: Data(#"{"ticket":"tkt-789","ttl_seconds":30}"#.utf8)),
        ]
        TicketSequenceURLProtocol.capturedRequests = []
        defer {
            TicketSequenceURLProtocol.responses = []
            TicketSequenceURLProtocol.capturedRequests = []
        }

        let store = StubCredentialStore()
        try await store.saveCredential(
            GatewayCredential(rawValue: "correct-password", username: "hermes-fleet"),
            for: GatewayID(rawValue: "tunnel")
        )
        let authenticator = GatewayAuthenticator(
            gatewayID: GatewayID(rawValue: "tunnel"),
            strategy: .usernamePassword,
            credentialStore: store,
            baseURL: URL(string: "https://fleet.example.dev")!,
            urlSession: stubbedSession(protocol: TicketSequenceURLProtocol.self)
        )
        let result = try await authenticator.authenticate()
        guard case .ticket(let token) = result else {
            return XCTFail("expected ticket auth, got \(result)")
        }
        XCTAssertEqual(token.rawValue, "tkt-789")

        let requests = TicketSequenceURLProtocol.capturedRequests
        XCTAssertEqual(requests.count, 3, "providers → password-login → ws-ticket, in order")
        XCTAssertEqual(requests[0].url?.path, "/api/auth/providers")
        XCTAssertEqual(requests[1].url?.path, "/auth/password-login")
        XCTAssertEqual(requests[2].url?.path, "/api/auth/ws-ticket")
        // The mint must replay the login session cookie and NOT send the
        // token header (the header path is exactly what 401s "no_cookie").
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "Cookie"),
            "hermes_session_at=sekrit-session",
            "the ws-ticket mint must carry the password-login session cookie")
        XCTAssertNil(
            requests[2].value(forHTTPHeaderField: "X-Hermes-Session-Token"),
            "the username/password path must NOT send the token header")
    }

    // MARK: - F2 endpoint migration: strategy alignment

    func testEndpointMigrationAlignsLoopbackStrategyOntoTunnel() {
        // F2 re-points loopback/LAN rows onto the public tunnel but (before
        // P0-9) PRESERVED the strategy — stranding a loopbackToken row on a
        // cookie-only tunnel that rejects ?token= with 403 (QA-verified).
        // The migration now aligns that strategy to usernamePassword.
        let record = StoredGatewayRecord(
            id: "arch",
            displayName: "Lab Node",
            endpoint: "http://127.0.0.1:8642",
            authConfiguration: GatewayAuthConfiguration(strategy: .loopbackToken, credentialStored: true),
            authConfigured: true
        )
        let migrated = EndpointMigration.migrateEndpoints(
            in: [record], defaultEndpoint: "https://fleet.example.dev")
        XCTAssertEqual(migrated[0].endpoint, "https://fleet.example.dev")
        XCTAssertEqual(migrated[0].authConfiguration.strategy, .usernamePassword,
                       "a loopbackToken row re-pointed to the cookie-only tunnel must not keep a strategy the tunnel rejects")
    }

    func testEndpointMigrationLeavesTokenStrategiesAndOtherRowsAlone() {
        // sessionToken rows keep their strategy (honest cause-specific copy
        // now covers the failure); rows already on the default endpoint and
        // unknown rows are untouched (idempotence + other-gateway safety).
        let tokenRow = StoredGatewayRecord(
            id: "tok", displayName: "Tok", endpoint: "http://192.168.50.20:8642",
            authConfiguration: GatewayAuthConfiguration(strategy: .sessionToken, credentialStored: true))
        let currentRow = StoredGatewayRecord(
            id: "cur", displayName: "Cur", endpoint: "https://fleet.example.dev",
            authConfiguration: GatewayAuthConfiguration(strategy: .loopbackToken, credentialStored: true))
        let strangerRow = StoredGatewayRecord(
            id: "other", displayName: "Other", endpoint: "https://other-gateway.example.net:9120",
            authConfiguration: GatewayAuthConfiguration(strategy: .loopbackToken, credentialStored: true))
        let migrated = EndpointMigration.migrateEndpoints(
            in: [tokenRow, currentRow, strangerRow],
            defaultEndpoint: "https://fleet.example.dev")
        XCTAssertEqual(migrated[0].authConfiguration.strategy, .sessionToken,
                       "token strategies are NOT force-migrated — a future gateway may accept them")
        XCTAssertEqual(migrated[1].authConfiguration.strategy, .loopbackToken,
                       "a row already on the default endpoint is a no-op (idempotence)")
        XCTAssertEqual(migrated[2].authConfiguration.strategy, .loopbackToken,
                       "unknown rows survive verbatim (other gateways)")
    }

    // MARK: - Redaction guard

    func testStrategyRejectionErrorsNeverCarryCredentials() {
        // Non-secret by construction: only the server-echoed reason word.
        let errors: [Error & LocalizedError] = [
            AuthenticationError.rejected(reason: .noCookie),
            TransportError.authStrategyRejected(.noCookie),
            GatewayConnectivityError.authStrategyRejected(.noCookie),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.lowercased().contains("password"), text)
            XCTAssertFalse(text.lowercased().contains("token="), text)
            XCTAssertTrue(text.contains("no_cookie"), "the cause word must surface: \(text)")
        }
    }

    // MARK: - helpers

    /// Local in-memory `CredentialStoring` stub that preserves the FULL
    /// credential (password + username half) — the username/password
    /// strategy needs both (FleetNetworking tests carry no FleetSecurity
    /// dependency; local-copy pattern per PasswordLoginClientTests).
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

    private func stubbedSession(
        protocol urlProtocol: AnyClass = TicketMintURLProtocol.self
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [urlProtocol]
        return URLSession(configuration: config)
    }
}

/// Sequence-scripted URLProtocol: answers each request in order from
/// `responses`, capturing requests for assertions. Used to script the
/// tunnel's working three-call auth sequence.
final class TicketSequenceURLProtocol: URLProtocol, @unchecked Sendable {
    struct ScriptedResponse {
        var status: Int
        var body: Data
        var setCookie: String?
    }
    nonisolated(unsafe) static var responses: [ScriptedResponse] = []
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    /// Serializes request-start across concurrent tests of this class.
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let scripted = Self.responses.isEmpty
            ? ScriptedResponse(status: 500, body: Data("{\"reason\":\"no_script\"}".utf8))
            : Self.responses.removeFirst()
        Self.lock.unlock()

        var headers = ["Content-Type": "application/json"]
        if let setCookie = scripted.setCookie {
            headers["Set-Cookie"] = setCookie
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: scripted.status,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: scripted.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
