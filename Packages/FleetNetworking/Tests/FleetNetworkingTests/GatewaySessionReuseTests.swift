import XCTest
import FleetCore
@testable import FleetNetworking

/// The auth session is shared; the ticket is not. These tests pin the
/// launch-burst fix without persisting or inspecting any secret material.
final class GatewaySessionReuseTests: XCTestCase {
    private final class AuthURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) static var logins = 0
        nonisolated(unsafe) static var mints = 0
        nonisolated(unsafe) static var rejectMint: Int?
        nonisolated(unsafe) static var loginStatus: Int?

        static func reset() {
            lock.lock(); defer { lock.unlock() }
            logins = 0; mints = 0; rejectMint = nil; loginStatus = nil
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let path = request.url?.path else { return }
            switch path {
            case "/api/auth/providers":
                respond(status: 200, json: ["providers": [["name": "basic", "supports_password": true]]])
            case "/auth/password-login":
                Self.lock.lock()
                let status = Self.loginStatus ?? 200
                if status == 200 { Self.logins += 1 }
                let cookie = "session-(Self.logins)"
                Self.lock.unlock()
                if status == 200 {
                    respond(status: 200, json: ["ok": true], headers: ["Set-Cookie": "hermes_session_at=(cookie); Path=/"])
                } else {
                    respond(status: status, json: ["error": "rate limited"])
                }
            case "/api/auth/ws-ticket":
                Self.lock.lock()
                Self.mints += 1
                let index = Self.mints
                let rejected = Self.rejectMint == index
                Self.lock.unlock()
                if rejected {
                    respond(status: 401, json: ["reason": "no_cookie"])
                } else {
                    respond(status: 200, json: ["ticket": "ticket-(index)", "ttl_seconds": 30])
                }
            default:
                respond(status: 404, json: [:])
            }
        }

        override func stopLoading() {}

        private func respond(status: Int, json: [String: Any], headers: [String: String] = [:]) {
            let body = try! JSONSerialization.data(withJSONObject: json)
            var allHeaders = ["Content-Type": "application/json"]
            headers.forEach { allHeaders[$0.key] = $0.value }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: allHeaders)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private final class Credentials: CredentialStoring, @unchecked Sendable {
        private let credential: GatewayCredential
        init(_ credential: GatewayCredential) { self.credential = credential }
        func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {}
        func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? { credential }
        func deleteCredential(for gatewayID: GatewayID) async throws {}
    }

    private let gateway = GatewayID(rawValue: "workstation")
    private let baseURL = URL(string: "https://gateway.example.invalid:9120")!
    private var urlSession: URLSession!

    override func setUp() {
        super.setUp()
        AuthURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthURLProtocol.self]
        urlSession = URLSession(configuration: configuration)
    }

    override func tearDown() {
        urlSession = nil
        super.tearDown()
    }

    private func authenticator(
        gatewayID: GatewayID = GatewayID(rawValue: "workstation"),
        store: GatewaySessionStore?
    ) -> GatewayAuthenticator {
        GatewayAuthenticator(
            gatewayID: gatewayID,
            strategy: .usernamePassword,
            credentialStore: Credentials(GatewayCredential(rawValue: "pw-123", username: "tony")),
            baseURL: baseURL,
            urlSession: urlSession,
            sessionStore: store)
    }

    func testConsumersShareOneLoginButReceiveSeparateSingleUseTickets() async throws {
        let store = GatewaySessionStore()
        for _ in 0..<3 {
            _ = try await authenticator(store: store).authenticate()
        }
        XCTAssertEqual(AuthURLProtocol.logins, 1)
        XCTAssertEqual(AuthURLProtocol.mints, 3)
    }

    func testConcurrentConsumersShareOneInFlightLogin() async throws {
        let store = GatewaySessionStore()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                let auth = authenticator(store: store)
                group.addTask { _ = try await auth.authenticate() }
            }
            for try await _ in group {}
        }
        XCTAssertEqual(AuthURLProtocol.logins, 1)
        XCTAssertEqual(AuthURLProtocol.mints, 8)
    }

    func testSeparateGatewaysKeepSeparateSessions() async throws {
        let store = GatewaySessionStore()
        _ = try await authenticator(gatewayID: gateway, store: store).authenticate()
        _ = try await authenticator(gatewayID: GatewayID(rawValue: "arch"), store: store).authenticate()
        _ = try await authenticator(gatewayID: gateway, store: store).authenticate()
        XCTAssertEqual(AuthURLProtocol.logins, 2)
        XCTAssertEqual(AuthURLProtocol.mints, 3)
    }

    func testCredentialRotationInvalidatesCachedLease() async throws {
        let store = GatewaySessionStore()
        _ = try await authenticator(store: store).authenticate()
        await store.invalidate(gatewayID: gateway)
        _ = try await authenticator(store: store).authenticate()
        XCTAssertEqual(AuthURLProtocol.logins, 2)
    }

    func testRejectedCookieSelfHealsWithOneBoundedRelogin() async throws {
        AuthURLProtocol.rejectMint = 1
        let store = GatewaySessionStore()
        _ = try await authenticator(store: store).authenticate()
        XCTAssertEqual(AuthURLProtocol.logins, 2)
        XCTAssertEqual(AuthURLProtocol.mints, 2)
    }

    func testRateLimitIsTransientAndNotUnsupported() async {
        AuthURLProtocol.loginStatus = 429
        do {
            _ = try await authenticator(store: GatewaySessionStore()).authenticate()
            XCTFail("429 login must surface an auth error")
        } catch let error as AuthenticationError {
            guard case .httpStatus(429) = error else { return XCTFail("unexpected auth error: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(GatewayStatus(connectivityError: .authSurfaceHTTP(429)), .offline)
        XCTAssertNotEqual(GatewayStatus(connectivityError: .authSurfaceHTTP(429)), .unsupported)
    }

    func testNoSecretPersistenceOrPrintableLeak() async {
        let cookie = SessionCookie(name: "hermes_session_at", value: "secret-cookie")
        let store = GatewaySessionStore()
        XCTAssertFalse(cookie.description.contains("secret-cookie"))
        XCTAssertFalse(String(describing: store).contains("secret-cookie"))
        XCTAssertFalse(String(describing: store).contains("pw-123"))
    }
}
