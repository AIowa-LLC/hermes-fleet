import XCTest
import os
import FleetCore
@testable import FleetNetworking

/// The `.deviceCredential` strategy: a paired phone exchanges its device credential for a
/// short-lived session cookie at `POST /auth/device-login`, then mints a single-use WebSocket
/// ticket with it - the same shape as the password flow, but the long-lived secret is the
/// per-device credential, never a username or password. HTTP is stubbed; the response shapes
/// (including the `__Host-` cookie name over HTTPS) were captured from the real gateway.
final class DeviceCredentialAuthTests: XCTestCase {
    private let credentialValue = "hfd1." + String(repeating: "0123abcd", count: 4) + "." + String(repeating: "S", count: 43)
    private let baseURL = URL(string: "https://gateway.example.test")!
    private let gatewayID = GatewayID(rawValue: "gw-" + String(repeating: "ab12cd34", count: 4))

    private final class Stub: URLProtocol, @unchecked Sendable {
        struct State {
            var requests: [URLRequest] = []
            var bodies: [String] = []
            var loginStatus = 200
            var logins = 0
            var mints = 0
            /// Mint attempts (1-based) answered with the gateway's expired-session 401.
            var rejectMints: Set<Int> = []
            var cookieValue = "hfa1.session.one"
        }
        nonisolated(unsafe) static var state = OSAllocatedUnfairLock(initialState: State())
        static func reset() { state = OSAllocatedUnfairLock(initialState: State()) }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let body = Self.bodyData(of: request)
            let path = request.url?.path ?? ""
            let (status, headers, payload): (Int, [String: String], Data) = Self.state.withLock { s in
                s.requests.append(request)
                s.bodies.append(String(data: body, encoding: .utf8) ?? "")
                switch path {
                case "/auth/device-login":
                    s.logins += 1
                    guard s.loginStatus == 200 else {
                        return (s.loginStatus, ["Content-Type": "application/json"],
                                Data(#"{"error":"invalid_credential"}"#.utf8))
                    }
                    // Exactly what the real gateway sends over HTTPS (captured from a live run).
                    let value = "\(s.cookieValue).\(s.logins)"
                    return (200, [
                        "Content-Type": "application/json",
                        "Set-Cookie": "__Host-hermes_session_at=\(value); HttpOnly; Max-Age=3600; Path=/; SameSite=lax; Secure, __Host-hermes_session_provider=fleet-device; HttpOnly; Max-Age=2592000; Path=/; SameSite=lax; Secure",
                    ], Data(#"{"ok":true,"device_id":"x","expires_at":1}"#.utf8))
                case "/api/auth/ws-ticket":
                    s.mints += 1
                    if s.rejectMints.contains(s.mints) {
                        return (401, ["Content-Type": "application/json"],
                                Data(#"{"error":"session_expired","reason":"invalid_or_expired_session"}"#.utf8))
                    }
                    return (200, ["Content-Type": "application/json"],
                            Data(#"{"ticket":"tkt-\#(s.mints)","ttl_seconds":30}"#.utf8))
                default:
                    return (404, [:], Data())
                }
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        private static func bodyData(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }
    }

    private final class Credentials: CredentialStoring, @unchecked Sendable {
        let value: GatewayCredential?
        init(_ value: GatewayCredential?) { self.value = value }
        func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {}
        func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? { value }
        func deleteCredential(for gatewayID: GatewayID) async throws {}
    }

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        Stub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        session = URLSession(configuration: config)
    }

    private func authenticator(
        credential: GatewayCredential?, sessionStore: GatewaySessionStore? = nil
    ) -> GatewayAuthenticator {
        GatewayAuthenticator(
            gatewayID: gatewayID, strategy: .deviceCredential,
            credentialStore: Credentials(credential), baseURL: baseURL,
            urlSession: session, sessionStore: sessionStore)
    }

    private var requests: [URLRequest] { Stub.state.withLock { $0.requests } }

    // MARK: login client

    func testLoginSendsTheCredentialOnlyInTheBodyAndCapturesTheHostCookie() async throws {
        let client = DeviceLoginClient(baseURL: baseURL, urlSession: session)
        let cookie = try await client.login(credential: credentialValue)

        XCTAssertEqual(cookie.name, "__Host-hermes_session_at", "the real HTTPS cookie name is captured")
        XCTAssertTrue(cookie.value.hasPrefix("hfa1.session.one"))
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/auth/device-login")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.url?.query)
        XCTAssertFalse(request.url?.absoluteString.contains(credentialValue) ?? true)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        for (_, value) in request.allHTTPHeaderFields ?? [:] { XCTAssertFalse(value.contains(credentialValue)) }
        let body = Stub.state.withLock { $0.bodies.first } ?? ""
        XCTAssertEqual(body, #"{"device_credential":"\#(credentialValue)"}"#)
    }

    func testARevokedOrUnknownDeviceIsRejectedNotSilentlyIgnored() async throws {
        Stub.state.withLock { $0.loginStatus = 401 }
        let client = DeviceLoginClient(baseURL: baseURL, urlSession: session)
        do {
            _ = try await client.login(credential: credentialValue)
            XCTFail("a 401 must surface")
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .httpStatus(401))
        }
    }

    func testAGatewayWithoutPairingSupportIsReportedByStatus() async {
        for status in [404, 409] {
            Stub.state.withLock { $0.loginStatus = status }
            do {
                _ = try await DeviceLoginClient(baseURL: baseURL, urlSession: session).login(credential: credentialValue)
                XCTFail()
            } catch let error as AuthenticationError {
                XCTAssertEqual(error, .httpStatus(status))
            } catch { XCTFail("\(error)") }
        }
    }

    func testClientDescriptionNeverShowsTheCredential() {
        let client = DeviceLoginClient(baseURL: baseURL, urlSession: session)
        XCTAssertFalse("\(client)".contains(credentialValue))
        XCTAssertFalse(String(reflecting: client).contains(credentialValue))
    }

    // MARK: authenticator

    func testAuthenticatorLogsInThenMintsATicketWithTheSessionCookie() async throws {
        let auth = authenticator(credential: GatewayCredential(rawValue: credentialValue))
        let result = try await auth.authenticate()

        guard case .ticket(let token) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(token.rawValue, "tkt-1")
        XCTAssertEqual(requests.map { $0.url?.path }, ["/auth/device-login", "/api/auth/ws-ticket"])
        let mint = try XCTUnwrap(requests.last)
        let cookie = try XCTUnwrap(mint.value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(cookie.hasPrefix("__Host-hermes_session_at=hfa1.session.one"))
        XCTAssertNil(mint.value(forHTTPHeaderField: "X-Hermes-Session-Token"))
        XCTAssertFalse(cookie.contains(credentialValue), "the long-lived credential never rides the cookie")
        XCTAssertFalse(mint.url?.absoluteString.contains(credentialValue) ?? true)
    }

    func testAMissingStoredCredentialFailsClosedBeforeAnyRequest() async {
        let auth = authenticator(credential: nil)
        do {
            _ = try await auth.authenticate()
            XCTFail()
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .missingLoopbackToken)
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(requests.isEmpty)
    }

    func testARevokedDeviceNeverMintsATicket() async {
        Stub.state.withLock { $0.loginStatus = 401 }
        let auth = authenticator(credential: GatewayCredential(rawValue: credentialValue))
        do {
            _ = try await auth.authenticate()
            XCTFail()
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .httpStatus(401))
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(requests.map { $0.url?.path }, ["/auth/device-login"], "no ticket request after a rejected login")
    }

    func testASharedSessionIsReusedAndAnExpiredOneIsReplacedExactlyOnce() async throws {
        let store = GatewaySessionStore()
        let auth = authenticator(
            credential: GatewayCredential(rawValue: credentialValue), sessionStore: store)

        _ = try await auth.authenticate()
        _ = try await auth.authenticate()
        XCTAssertEqual(Stub.state.withLock { $0.logins }, 1, "the session is leased, not re-created per connect")
        XCTAssertEqual(Stub.state.withLock { $0.mints }, 2)

        // The gateway expires the session: the next mint is answered with a 401.
        Stub.state.withLock { $0.rejectMints = [3] }
        let recovered = try await auth.authenticate()
        guard case .ticket = recovered else { return XCTFail() }
        XCTAssertEqual(Stub.state.withLock { $0.logins }, 2, "one fresh login after the rejection")
        XCTAssertEqual(Stub.state.withLock { $0.mints }, 4)
    }

    func testASecondRejectionIsSurfacedNotLooped() async {
        let store = GatewaySessionStore()
        Stub.state.withLock { $0.rejectMints = [1, 2, 3, 4] }
        let auth = authenticator(
            credential: GatewayCredential(rawValue: credentialValue), sessionStore: store)
        do {
            _ = try await auth.authenticate()
            XCTFail("a persistent rejection must surface")
        } catch let error as AuthenticationError {
            guard case .rejected = error else { return XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(Stub.state.withLock { $0.logins }, 2, "exactly one retry, never a loop")
    }

    func testTheCredentialNeverAppearsInAnyRequestUrlHeaderOrAuthenticationErrorText() async {
        Stub.state.withLock { $0.rejectMints = [1, 2] }
        let auth = authenticator(
            credential: GatewayCredential(rawValue: credentialValue), sessionStore: GatewaySessionStore())
        var errorText = ""
        do { _ = try await auth.authenticate() } catch { errorText = "\(error) \(error.localizedDescription)" }
        XCTAssertFalse(errorText.contains(credentialValue))
        for request in requests {
            XCTAssertFalse(request.url?.absoluteString.contains(credentialValue) ?? true)
            for (_, value) in request.allHTTPHeaderFields ?? [:] { XCTAssertFalse(value.contains(credentialValue)) }
        }
    }
}
