import Foundation
import XCTest
import FleetCore
@testable import FleetNetworking

private final class DeviceAuthURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Reply)?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    static func reset(handler newHandler: (@Sendable (URLRequest) -> Reply)? = nil) {
        lock.lock(); defer { lock.unlock() }
        captured = []
        handler = newHandler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let reply = handler?(request), let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if (300..<400).contains(reply.status), let location = reply.headers["Location"],
           let target = URL(string: location, relativeTo: url)?.absoluteURL {
            var redirect = URLRequest(url: target)
            redirect.httpMethod = request.httpMethod
            redirect.httpBody = request.httpBody
            redirect.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: redirect, redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor DeviceAuthCredentialStore: CredentialStoring {
    private let credential: GatewayCredential

    init(_ credential: GatewayCredential) { self.credential = credential }
    func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {}
    func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? { credential }
    func deleteCredential(for gatewayID: GatewayID) async throws {}
}

private final class DeviceAuthScript: @unchecked Sendable {
    private let lock = NSLock()
    private var loginCount = 0
    private var mintCount = 0
    private let rejectedMints: Set<Int>

    init(rejectedMints: Set<Int> = []) { self.rejectedMints = rejectedMints }

    func reply(to request: URLRequest) -> DeviceAuthURLProtocol.Reply {
        lock.lock(); defer { lock.unlock() }
        switch request.url?.path {
        case "/auth/device-login":
            loginCount += 1
            let body = Data(#"{"ok":true,"expires_at":"2035-01-02T03:04:05Z"}"#.utf8)
            return .init(status: 200, headers: ["Set-Cookie": "hermes_session_at=cookie-\(loginCount); Path=/; HttpOnly"], body: body)
        case "/api/auth/ws-ticket":
            mintCount += 1
            if rejectedMints.contains(mintCount) {
                return .init(status: 401, headers: ["Content-Type": "application/json"], body: Data(#"{"reason":"no_cookie"}"#.utf8))
            }
            let body = Data(#"{"ticket":"transient-ticket","ttl_seconds":30}"#.utf8)
            return .init(status: 200, headers: ["Content-Type": "application/json"], body: body)
        default:
            return .init(status: 404, body: Data())
        }
    }

    var counts: (logins: Int, mints: Int) {
        lock.lock(); defer { lock.unlock() }
        return (loginCount, mintCount)
    }
}

final class DeviceLoginClientTests: XCTestCase {
    private let baseURL = URL(string: "https://fleet-gateway.example.invalid:9443")!
    private let credential = "hfd1.0123456789abcdef0123456789abcdef.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    private let gatewayID = GatewayID(rawValue: "fleet-gateway-instance")
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceAuthURLProtocol.self]
        session = URLSession(configuration: configuration)
        DeviceAuthURLProtocol.reset()
    }

    override func tearDown() {
        DeviceAuthURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    private func authenticator(store: GatewaySessionStore) -> GatewayAuthenticator {
        GatewayAuthenticator(
            gatewayID: gatewayID,
            strategy: .deviceCredential,
            credentialStore: DeviceAuthCredentialStore(GatewayCredential(rawValue: credential)),
            baseURL: baseURL,
            urlSession: session,
            sessionStore: store)
    }

    func testDeviceLoginRequiresHTTPSAndKeepsCredentialOutOfURL() async throws {
        let insecure = DeviceLoginClient(
            baseURL: URL(string: "http://fleet-gateway.example.invalid")!,
            deviceCredential: credential,
            urlSession: session)
        do {
            _ = try await insecure.login()
            XCTFail("device credentials must never be sent over HTTP")
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .httpStatus(400))
        }
        XCTAssertTrue(DeviceAuthURLProtocol.requests.isEmpty)

        let bodyCapture = DeviceAuthBodyCapture()
        DeviceAuthURLProtocol.reset { request in
            bodyCapture.record(request)
            return .init(
                status: 200,
                headers: ["Set-Cookie": "hermes_session_at=short-cookie; Path=/; HttpOnly"],
                body: Data(#"{"ok":true,"expires_at":"2035-01-02T03:04:05Z"}"#.utf8))
        }
        let cookie = try await DeviceLoginClient(
            baseURL: baseURL, deviceCredential: credential, urlSession: session).login()
        let request = try XCTUnwrap(DeviceAuthURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/auth/device-login")
        XCTAssertFalse(request.url!.absoluteString.contains(credential))
        XCTAssertEqual(bodyCapture.credential, credential)
        XCTAssertEqual(cookie.name, "hermes_session_at")
        XCTAssertEqual(cookie.value, "short-cookie")
        XCTAssertEqual(cookie.expiresAt, ISO8601DateFormatter().date(from: "2035-01-02T03:04:05Z"))
    }

    func testDeviceLoginRejectsHTTPMalformedAndRedirectResponses() async throws {
        DeviceAuthURLProtocol.reset { _ in .init(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8)) }
        do {
            _ = try await DeviceLoginClient(baseURL: baseURL, deviceCredential: credential, urlSession: session).login()
            XCTFail("invalid device credentials must be rejected")
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .httpStatus(401))
        }

        DeviceAuthURLProtocol.reset { _ in .init(status: 200, body: Data(#"{"ok":true}"#.utf8)) }
        do {
            _ = try await DeviceLoginClient(baseURL: baseURL, deviceCredential: credential, urlSession: session).login()
            XCTFail("a successful status without the session cookie is malformed")
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .ticketMintFailed("device login response malformed"))
        }

        DeviceAuthURLProtocol.reset { _ in
            .init(status: 302, headers: ["Location": "https://redirect.example.invalid/collect"], body: Data())
        }
        do {
            _ = try await DeviceLoginClient(baseURL: baseURL, deviceCredential: credential, urlSession: session).login()
            XCTFail("credential-bearing device login redirects must be blocked")
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .ticketMintFailed("device login unavailable"))
        }
        XCTAssertEqual(DeviceAuthURLProtocol.requests.count, 1, "redirect target must not receive the credential")
        XCTAssertEqual(DeviceAuthURLProtocol.requests.first?.url?.host, "fleet-gateway.example.invalid")
    }

    func testDeviceAuthenticatorReusesSessionAndRetriesNoCookieOnlyOnce() async throws {
        let script = DeviceAuthScript(rejectedMints: [1])
        DeviceAuthURLProtocol.reset { script.reply(to: $0) }
        let store = GatewaySessionStore()
        let auth = authenticator(store: store)

        _ = try await auth.authenticate()
        _ = try await auth.authenticate()

        XCTAssertEqual(script.counts.logins, 2, "first no_cookie causes one fresh login, then the lease is reused")
        XCTAssertEqual(script.counts.mints, 3, "tickets remain per-authentication even as the session is reused")
        let loginRequests = DeviceAuthURLProtocol.requests.filter { $0.url?.path == "/auth/device-login" }
        XCTAssertEqual(loginRequests.count, 2)
        XCTAssertTrue(loginRequests.allSatisfy { !$0.url!.absoluteString.contains(credential) })
    }

    func testDeviceAuthenticatorBoundsNoCookieRecoveryToOneRelogin() async throws {
        let script = DeviceAuthScript(rejectedMints: [1, 2, 3])
        DeviceAuthURLProtocol.reset { script.reply(to: $0) }
        let auth = authenticator(store: GatewaySessionStore())

        do {
            _ = try await auth.authenticate()
            XCTFail("second no_cookie should be surfaced")
        } catch let error as AuthenticationError {
            XCTAssertEqual(error, .rejected(reason: .noCookie))
        }
        XCTAssertEqual(script.counts.logins, 2)
        XCTAssertEqual(script.counts.mints, 2, "the failed fresh lease must not trigger an unbounded retry")
    }
}

private final class DeviceAuthBodyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCredential: String?

    func record(_ request: URLRequest) {
        let bodyData: Data?
        if let body = request.httpBody {
            bodyData = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            bodyData = data
        } else {
            bodyData = nil
        }
        let body = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        lock.lock(); defer { lock.unlock() }
        storedCredential = body?["device_credential"]
    }

    var credential: String? {
        lock.lock(); defer { lock.unlock() }
        return storedCredential
    }
}
