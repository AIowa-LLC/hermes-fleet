import XCTest
import FleetCore
@testable import FleetNetworking

private final class EnrollmentURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func startLoading() {
        Self.requests.append(request)
        guard let result = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: result.0, httpVersion: "HTTP/1.1",
            headerFields: result.1)!
        if (300..<400).contains(result.0),
           let location = result.1["Location"],
           let destination = URL(string: location, relativeTo: request.url)?.absoluteURL {
            var redirected = URLRequest(url: destination)
            redirected.httpMethod = request.httpMethod
            redirected.httpBody = request.httpBody
            redirected.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.2)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor EnrollmentCredentialStore: CredentialStoring {
    private var values: [GatewayID: GatewayCredential] = [:]
    var failNextSave = false
    private(set) var saveCount = 0
    func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
        saveCount += 1
        if failNextSave { failNextSave = false; throw CredentialStoreError.storeUnavailable("synthetic") }
        values[gatewayID] = credential
    }
    func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? { values[gatewayID] }
    func deleteCredential(for gatewayID: GatewayID) async throws { values[gatewayID] = nil }
    func seed(_ credential: GatewayCredential, for id: GatewayID) { values[id] = credential }
    func failSave() { failNextSave = true }
    func saves() -> Int { saveCount }
}

private actor EnrollmentIdentityStore: OwnerEnrollmentIdentityStoring {
    private var values: [GatewayID: PendingOwnerDeviceIdentity] = [:]
    var failNextDelete = false
    func loadIdentity(for endpointID: GatewayID) async throws -> PendingOwnerDeviceIdentity? { values[endpointID] }
    func saveIdentity(_ identity: PendingOwnerDeviceIdentity, for endpointID: GatewayID) async throws { values[endpointID] = identity }
    func deleteIdentity(for endpointID: GatewayID) async throws {
        if failNextDelete { failNextDelete = false; throw CredentialStoreError.storeUnavailable("synthetic") }
        values[endpointID] = nil
    }
    func failDelete() { failNextDelete = true }
}

private final class EnrollmentRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    func append(_ body: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        bodies.append(body)
        return bodies.count
    }
    func allBodies() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return bodies
    }
}

private final class PinningIDCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GatewayID] = []
    func append(_ id: GatewayID) { lock.lock(); defer { lock.unlock() }; storage.append(id) }
    var ids: [GatewayID] { lock.lock(); defer { lock.unlock() }; return storage }
}

final class OwnerEnrollmentClientTests: XCTestCase {
    private let address = URL(string: "https://gateway.example.invalid:9443")!
    private let authorization = OwnerAuthorization.sessionCookie(name: "hermes_session_at", value: "synthetic-owner-cookie")
    private var session: URLSession!
    private var credentials: EnrollmentCredentialStore!
    private var identities: EnrollmentIdentityStore!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EnrollmentURLProtocol.self]
        session = URLSession(configuration: configuration)
        credentials = EnrollmentCredentialStore()
        identities = EnrollmentIdentityStore()
        EnrollmentURLProtocol.requests = []
    }

    override func tearDown() {
        EnrollmentURLProtocol.handler = nil
        EnrollmentURLProtocol.requests = []
        session = nil
        credentials = nil
        identities = nil
        super.tearDown()
    }

    private func client(pinStore: InMemoryPinStore? = nil) -> OwnerEnrollmentClient {
        OwnerEnrollmentClient(
            credentialStore: credentials, identityStore: identities,
            pinStore: pinStore, approvalStore: pinStore, urlSession: session)
    }

    private func response(_ status: Int, _ body: String, headers: [String: String] = [:]) -> (Int, [String: String], Data) {
        (status, headers, Data(body.utf8))
    }

    private let connectionJSON = #"{"authenticated":true,"can_enroll":true,"enrollment_version":1,"gateway":{"instance_id":"gw-instance-001","display_name":"Synthetic gateway","origin":"https://gateway.example.invalid:9443"},"scopes":["fleet:operator"]}"#

    func testProviderDiscoveryAndPasswordSignInAreTransient() async throws {
        EnrollmentURLProtocol.handler = { request in
            if request.url?.path == "/api/auth/providers" {
                return (200, [:], Data(#"{"providers":[{"name":"basic","display_name":"Local account","supports_password":true},{"name":"oauth","display_name":"OAuth","supports_password":false}]}"#.utf8))
            }
            if request.url?.path == "/auth/password-login" {
                return (200, ["Set-Cookie": "hermes_session_at=short-session; Path=/"], Data(#"{"ok":true}"#.utf8))
            }
            return (404, [:], Data())
        }
        let providers = try await client().discoverProviders(at: address)
        XCTAssertEqual(providers.map(\.id), ["basic", "oauth"])
        XCTAssertEqual(providers.map(\.supportsPassword), [true, false])

        let auth = try await client().signIn(at: address, providerID: "basic", username: "synthetic-user", password: "synthetic-password")
        XCTAssertEqual(auth.kind, .sessionCookie)
        XCTAssertEqual(auth.cookieName, "hermes_session_at")
        XCTAssertFalse(auth.description.contains("short-session"))
        let body = try XCTUnwrap(EnrollmentURLProtocol.requests.last.flatMap(EnrollmentURLProtocol.bodyData))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["provider"], "basic")
        XCTAssertTrue(json["password"] == "synthetic-password", "password remains in the POST body")
    }

    func testWrongAuthAndOwnerRequiredAreTyped() async throws {
        EnrollmentURLProtocol.handler = { request in
            let body = request.url?.path == "/api/fleet/connection" ? #"{"detail":"owner_required"}"# : "{}"
            return (request.url?.path == "/api/fleet/connection" ? 403 : 401, [:], Data(body.utf8))
        }
        do {
            _ = try await client().inspectConnection(at: address, authorization: authorization)
            XCTFail("expected owner-only rejection")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .ownerRequired)
        }
    }

    func testUnreachableProviderEndpointIsTyped() async throws {
        EnrollmentURLProtocol.handler = nil
        do {
            _ = try await client().discoverProviders(at: address)
            XCTFail("synthetic transport failure must be reported")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .unreachable)
        }
    }

    func testRateLimitAndRedirectFailClosed() async throws {
        EnrollmentURLProtocol.handler = { request in
            if request.url?.path == "/api/auth/providers" {
                return (429, ["Retry-After": "30"], Data("{}".utf8))
            }
            if request.url?.path == "/api/fleet/connection" {
                return (302, ["Location": "https://other.example.invalid/steal"], Data())
            }
            return (404, [:], Data())
        }
        do {
            _ = try await client().discoverProviders(at: address)
            XCTFail("expected rate limit")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .rateLimited(retryAfterSeconds: 30))
        }

        do {
            _ = try await client().inspectConnection(at: address, authorization: authorization)
            XCTFail("owner-authenticated metadata must fail closed on redirect")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .unreachable)
        }
        XCTAssertEqual(EnrollmentURLProtocol.requests.count, 2)
        XCTAssertEqual(EnrollmentURLProtocol.requests.last?.url?.path, "/api/fleet/connection")
        XCTAssertEqual(EnrollmentURLProtocol.requests.last?.url?.host, "gateway.example.invalid")
        XCTAssertEqual(
            EnrollmentURLProtocol.requests.last?.value(forHTTPHeaderField: "Cookie"),
            "hermes_session_at=synthetic-owner-cookie")
    }

    func testInterruptedRequestRetriesSameIdentityAndPersistsCredential() async throws {
        let capture = EnrollmentRequestCapture()
        let connection = connectionJSON
        let pins = InMemoryPinStore()
        let endpointID = GatewayID(endpoint: address)
        let canonicalID = GatewayID(rawValue: "gw-instance-001")
        let reviewedPin = SPKIFingerprint(rawBytes: [UInt8](repeating: 5, count: 32))
        try pins.syncSavePin(reviewedPin, for: endpointID)
        EnrollmentURLProtocol.handler = { request in
            if request.url?.path == "/api/fleet/connection" { return (200, [:], Data(connection.utf8)) }
            if request.url?.path == "/api/fleet/devices/enroll" {
                let requestBody = EnrollmentURLProtocol.bodyData(request) ?? Data()
                let count = capture.append(requestBody)
                if count == 1 { return (503, [:], Data()) }
                let posted = (try? JSONSerialization.jsonObject(with: requestBody)) as? [String: String] ?? [:]
                let id = posted["device_id"] ?? ""
                let secret = posted["device_secret"] ?? ""
                let body = #"{"device":{"id":"\#(id)","label":"This phone"},"device_credential":"hfd1.\#(id).\#(secret)","gateway":{"instance_id":"gw-instance-001","display_name":"Synthetic gateway","origin":"https://gateway.example.invalid:9443"},"scopes":["fleet:operator"]}"#
                return (201, [:], Data(body.utf8))
            }
            return (404, [:], Data())
        }

        do {
            _ = try await client(pinStore: pins).enrollDevice(at: address, authorization: authorization, deviceName: "This phone", deviceModel: "Synthetic phone")
            XCTFail("first POST should be interrupted")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .serverRejected(statusCode: 503))
        }
        let pendingBefore = try await identities.loadIdentity(for: GatewayID(endpoint: address))
        XCTAssertNotNil(pendingBefore)
        XCTAssertEqual(try pins.syncLoadPin(for: endpointID), reviewedPin, "alias remains available for safe retry")
        XCTAssertEqual(try pins.syncLoadPin(for: canonicalID), reviewedPin, "confirmed metadata adopts the reviewed key")

        let enrolled = try await client(pinStore: pins).enrollDevice(at: address, authorization: authorization, deviceName: "This phone", deviceModel: "Synthetic phone")
        let pendingAfter = try await identities.loadIdentity(for: GatewayID(endpoint: address))
        let saved = try await credentials.loadCredential(for: enrolled.gatewayID)
        XCTAssertEqual(enrolled.gatewayID.rawValue, "gw-instance-001")
        XCTAssertNil(pendingAfter)
        XCTAssertNil(try pins.syncLoadPin(for: endpointID), "temporary endpoint alias is retired after commit")
        XCTAssertEqual(try pins.syncLoadPin(for: canonicalID), reviewedPin, "canonical pin survives alias retirement")
        XCTAssertTrue(saved?.rawValue.hasPrefix("hfd1.\(enrolled.deviceID).") == true)
        let enrollBodies = capture.allBodies()
        XCTAssertEqual(enrollBodies.count, 2)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: enrollBodies[0]) as? [String: String])
        let retryPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: enrollBodies[1]) as? [String: String])
        XCTAssertTrue(
            payload["device_id"] == retryPayload["device_id"]
                && payload["device_secret"] == retryPayload["device_secret"],
            "lost responses replay identical ID+secret")
        XCTAssertEqual(payload["device_id"]?.count, 32)
        XCTAssertEqual(payload["device_secret"]?.count, 43)
        XCTAssertEqual(EnrollmentURLProtocol.requests.last?.value(forHTTPHeaderField: "Origin"), "https://gateway.example.invalid:9443")
    }

    func testExplicitDefaultHTTPSPortIsRemovedFromOriginButNondefaultPortRemains() async throws {
        let defaultPortAddress = URL(string: "https://gateway.example.invalid:443")!
        let defaultConnection = #"{"authenticated":true,"can_enroll":true,"enrollment_version":1,"gateway":{"instance_id":"gw-instance-001","display_name":"Synthetic gateway","origin":"https://gateway.example.invalid"},"scopes":["fleet:operator"]}"#
        EnrollmentURLProtocol.handler = { request in
            if request.url?.path == "/api/fleet/connection" { return (200, [:], Data(defaultConnection.utf8)) }
            if request.url?.path == "/api/fleet/devices/enroll" {
                let posted = (try? JSONSerialization.jsonObject(with: EnrollmentURLProtocol.bodyData(request) ?? Data())) as? [String: String] ?? [:]
                let id = posted["device_id"] ?? ""
                let secret = posted["device_secret"] ?? ""
                let body = #"{"device":{"id":"\#(id)","label":"Phone"},"device_credential":"hfd1.\#(id).\#(secret)","gateway":{"instance_id":"gw-instance-001","display_name":"Synthetic gateway","origin":"https://gateway.example.invalid"},"scopes":["fleet:operator"]}"#
                return (201, [:], Data(body.utf8))
            }
            return (404, [:], Data())
        }

        _ = try await client().enrollDevice(at: defaultPortAddress, authorization: authorization, deviceName: nil, deviceModel: nil)
        let enrollRequest = try XCTUnwrap(EnrollmentURLProtocol.requests.first { $0.url?.path == "/api/fleet/devices/enroll" })
        XCTAssertEqual(enrollRequest.value(forHTTPHeaderField: "Origin"), "https://gateway.example.invalid")
        XCTAssertEqual(enrollRequest.url?.port, nil)
    }

    func testConcurrentRecoveryDoesNotResaveOrRevokeCommittedCredential() async throws {
        let connection = connectionJSON
        EnrollmentURLProtocol.handler = { request in
            if request.url?.path == "/api/fleet/connection" { return (200, [:], Data(connection.utf8)) }
            if request.url?.path == "/api/fleet/devices/enroll" {
                let posted = (try? JSONSerialization.jsonObject(with: EnrollmentURLProtocol.bodyData(request) ?? Data())) as? [String: String] ?? [:]
                let id = posted["device_id"] ?? ""
                let secret = posted["device_secret"] ?? ""
                let body = #"{"device":{"id":"\#(id)","label":"Phone"},"device_credential":"hfd1.\#(id).\#(secret)","gateway":{"instance_id":"gw-instance-001","display_name":"Synthetic gateway","origin":"https://gateway.example.invalid:9443"},"scopes":["fleet:operator"]}"#
                return (201, [:], Data(body.utf8))
            }
            if request.httpMethod == "DELETE" { return (200, [:], Data(#"{"ok":true}"#.utf8)) }
            return (404, [:], Data())
        }
        let service = client()
        let initial = try await service.enrollDevice(at: address, authorization: authorization, deviceName: "Phone", deviceModel: nil)
        await credentials.failSave()
        let gatewayAddress = address
        let ownerAuthorization = authorization

        async let recoveredA = service.enrollDevice(at: gatewayAddress, authorization: ownerAuthorization, deviceName: "Phone", deviceModel: nil)
        async let recoveredB = service.enrollDevice(at: gatewayAddress, authorization: ownerAuthorization, deviceName: "Phone", deviceModel: nil)
        let recovered = try await [recoveredA, recoveredB]

        XCTAssertEqual(recovered.map(\.deviceID), [initial.deviceID, initial.deviceID])
        let saveCount = await credentials.saves()
        let savedCredential = try await credentials.loadCredential(for: initial.gatewayID)
        XCTAssertEqual(saveCount, 1)
        XCTAssertTrue(savedCredential?.rawValue.hasPrefix("hfd1.\(initial.deviceID).") == true)
        XCTAssertFalse(EnrollmentURLProtocol.requests.contains { $0.httpMethod == "DELETE" })
    }

    func testDuplicateDoesNotReplaceExistingCredential() async throws {
        await credentials.seed(GatewayCredential(rawValue: "existing-token"), for: GatewayID(rawValue: "gw-instance-001"))
        let connection = connectionJSON
        EnrollmentURLProtocol.handler = { request in
            (200, [:], Data(connection.utf8))
        }
        do {
            _ = try await client().enrollDevice(at: address, authorization: authorization, deviceName: nil, deviceModel: nil)
            XCTFail("duplicate should be stopped")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .gatewayAlreadyRegistered)
        }
        XCTAssertEqual(EnrollmentURLProtocol.requests.count, 1)
        let kept = try await credentials.loadCredential(for: GatewayID(rawValue: "gw-instance-001"))
        XCTAssertEqual(kept?.rawValue, "existing-token")
    }

    func testDeviceCredentialRemovalRevokesRemotelyThenClearsEndpointMaterial() async throws {
        let gatewayID = GatewayID(rawValue: "gw-instance-001")
        let endpointID = GatewayID(endpoint: address)
        let credential = "hfd1.0123456789abcdef0123456789abcdef.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        await credentials.seed(GatewayCredential(rawValue: credential), for: gatewayID)
        let identity = PendingOwnerDeviceIdentity(
            deviceID: "0123456789abcdef0123456789abcdef",
            secret: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        try await identities.saveIdentity(identity, for: endpointID)
        let pins = InMemoryPinStore()
        let capture = PinningIDCapture()
        let canonicalPin = SPKIFingerprint(rawBytes: [UInt8](repeating: 2, count: 32))
        try await pins.savePin(canonicalPin, for: gatewayID)

        EnrollmentURLProtocol.handler = { request in
            if request.url?.path == "/auth/device-revoke" {
                return (200, [:], Data(#"{"ok":true}"#.utf8))
            }
            return (404, [:], Data())
        }
        let client = OwnerEnrollmentClient(
            credentialStore: credentials, identityStore: identities,
            trustHandlerFactory: { id in
                capture.append(id)
                return PinningTrustHandler(gatewayID: id, pinStore: pins, approvalStore: pins)
            },
            pinStore: pins, approvalStore: pins, urlSession: session)
        let gateway = FleetGateway(
            id: gatewayID, displayName: "Synthetic gateway", endpoint: address,
            authConfiguration: GatewayAuthConfiguration(strategy: .deviceCredential, credentialStored: true))

        let revoke = try await client.removeEnrollmentMaterialSchedulingRevoke(for: gateway)
        await revoke?.value

        XCTAssertEqual(EnrollmentURLProtocol.requests.last?.url?.path, "/auth/device-revoke")
        let body = try XCTUnwrap(EnrollmentURLProtocol.requests.last.flatMap(EnrollmentURLProtocol.bodyData))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertTrue(object["device_credential"] == credential, "self-revoke sends the credential only in its HTTPS body")
        XCTAssertEqual(capture.ids, [gatewayID], "self-revoke uses canonical gateway pin after alias retirement")
        let remainingIdentity = try await identities.loadIdentity(for: endpointID)
        let remainingAliasPin = try await pins.loadPin(for: endpointID)
        let remainingCanonicalPin = try await pins.loadPin(for: gatewayID)
        XCTAssertNil(remainingIdentity)
        XCTAssertNil(remainingAliasPin, "a retired endpoint alias stays absent")
        XCTAssertEqual(remainingCanonicalPin, canonicalPin, "canonical pin remains until registry removal")
    }

    func testRemovalCleanupPreservesAdvancedHTTPGatewaySupport() async throws {
        let legacy = FleetGateway(
            id: GatewayID(rawValue: "legacy-loopback"), displayName: "Legacy local",
            endpoint: URL(string: "http://127.0.0.1:8765")!,
            authConfiguration: GatewayAuthConfiguration(strategy: .usernamePassword, credentialStored: true))
        try await client().removeEnrollmentMaterial(for: legacy)
        XCTAssertTrue(EnrollmentURLProtocol.requests.isEmpty, "manual HTTP gateway removal stays local")

        let paired = FleetGateway(
            id: GatewayID(rawValue: "paired-http"), displayName: "Invalid paired gateway",
            endpoint: URL(string: "http://127.0.0.1:8765")!,
            authConfiguration: GatewayAuthConfiguration(strategy: .deviceCredential, credentialStored: true))
        // Removal stays local and succeeds; the credential is never sent
        // over plain HTTP, so no revoke is attempted.
        let revoke = try await client().removeEnrollmentMaterialSchedulingRevoke(for: paired)
        XCTAssertNil(revoke)
        XCTAssertTrue(EnrollmentURLProtocol.requests.isEmpty, "no device credential over HTTP")
    }

    /// #210: an unreachable gateway must not block local removal cleanup.
    func testDeviceCredentialRemovalSucceedsWhenGatewayUnreachable() async throws {
        let gatewayID = GatewayID(rawValue: "gw-instance-001")
        let endpointID = GatewayID(endpoint: address)
        let credential = "hfd1.0123456789abcdef0123456789abcdef.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        await credentials.seed(GatewayCredential(rawValue: credential), for: gatewayID)
        try await identities.saveIdentity(PendingOwnerDeviceIdentity(
            deviceID: "0123456789abcdef0123456789abcdef",
            secret: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), for: endpointID)
        let pins = InMemoryPinStore()
        try await pins.savePin(SPKIFingerprint(rawBytes: [UInt8](repeating: 2, count: 32)), for: gatewayID)
        EnrollmentURLProtocol.handler = nil  // every request fails: cannot connect to host
        let client = OwnerEnrollmentClient(
            credentialStore: credentials, identityStore: identities,
            pinStore: pins, approvalStore: pins, urlSession: session)
        let gateway = FleetGateway(
            id: gatewayID, displayName: "Synthetic gateway", endpoint: address,
            authConfiguration: GatewayAuthConfiguration(strategy: .deviceCredential, credentialStored: true))

        let revoke = try await client.removeEnrollmentMaterialSchedulingRevoke(for: gateway)
        let remainingIdentity = try await identities.loadIdentity(for: endpointID)
        XCTAssertNil(remainingIdentity, "local material is cleared before any network call")
        await revoke?.value  // best-effort revoke fails quietly
    }

    func testTLSReviewPersistsOnlyPresentedFingerprintAndRejectsReplacement() async throws {
        let pins = InMemoryPinStore()
        let reviewed = SPKIFingerprint(rawBytes: [UInt8](repeating: 3, count: 32))
        let changed = SPKIFingerprint(rawBytes: [UInt8](repeating: 4, count: 32))
        let client = OwnerEnrollmentClient(
            credentialStore: credentials, identityStore: identities,
            pinStore: pins, approvalStore: pins, urlSession: session)

        try await client.approveTLSFirstUse(at: address, fingerprint: reviewed)
        XCTAssertEqual(try pins.syncLoadPin(for: GatewayID(endpoint: address)), reviewed)
        do {
            try await client.approveTLSFirstUse(at: address, fingerprint: changed)
            XCTFail("a later certificate must not replace the reviewed key")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .tlsPinMismatch)
        }
    }

    func testCredentialSaveFailureRequiresConfirmedRemoteRollback() async throws {
        await credentials.failSave()
        let connection = connectionJSON
        EnrollmentURLProtocol.handler = { request in
            if request.url?.path == "/api/fleet/connection" { return (200, [:], Data(connection.utf8)) }
            if request.url?.path == "/api/fleet/devices/enroll" {
                let json = (try? JSONSerialization.jsonObject(with: EnrollmentURLProtocol.bodyData(request) ?? Data())) as? [String: String] ?? [:]
                let id = json["device_id"] ?? ""
                let secret = json["device_secret"] ?? ""
                let body = #"{"device":{"id":"\#(id)","label":"This phone"},"device_credential":"hfd1.\#(id).\#(secret)","gateway":{"instance_id":"gw-instance-001","display_name":"Synthetic gateway","origin":"https://gateway.example.invalid:9443"},"scopes":["fleet:operator"]}"#
                return (201, [:], Data(body.utf8))
            }
            if request.url?.path.hasPrefix("/api/fleet/devices/") == true { return (204, [:], Data()) }
            return (404, [:], Data())
        }

        do {
            _ = try await client().enrollDevice(at: address, authorization: authorization, deviceName: nil, deviceModel: nil)
            XCTFail("credential storage failure must be reported")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .credentialStorageFailed)
        }
        XCTAssertTrue(EnrollmentURLProtocol.requests.contains { $0.httpMethod == "DELETE" })
        let pending = try await identities.loadIdentity(for: GatewayID(endpoint: address))
        XCTAssertNil(pending, "confirmed revoke allows the retired identity to be deleted")
    }

    func testFailedRollbackAndPendingDeleteFailureRemainExplicit() async throws {
        await credentials.failSave()
        let connection = connectionJSON
        EnrollmentURLProtocol.handler = { request in
            if request.url?.path == "/api/fleet/connection" { return (200, [:], Data(connection.utf8)) }
            if request.url?.path == "/api/fleet/devices/enroll" {
                let json = (try? JSONSerialization.jsonObject(with: EnrollmentURLProtocol.bodyData(request) ?? Data())) as? [String: String] ?? [:]
                let id = json["device_id"] ?? ""
                let secret = json["device_secret"] ?? ""
                let body = #"{"device":{"id":"\#(id)","label":"This phone"},"device_credential":"hfd1.\#(id).\#(secret)","gateway":{"instance_id":"gw-instance-001","display_name":"Synthetic gateway","origin":"https://gateway.example.invalid:9443"},"scopes":["fleet:operator"]}"#
                return (201, [:], Data(body.utf8))
            }
            if request.url?.path.hasPrefix("/api/fleet/devices/") == true { return (503, [:], Data()) }
            return (404, [:], Data())
        }

        do {
            _ = try await client().enrollDevice(at: address, authorization: authorization, deviceName: nil, deviceModel: nil)
            XCTFail("unconfirmed revoke must be reported")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .rollbackFailed)
        }
        let pending = try await identities.loadIdentity(for: GatewayID(endpoint: address))
        XCTAssertNotNil(pending, "retain the same identity until remote revoke is confirmed")
        let gatewayCredential = try await credentials.loadCredential(for: GatewayID(rawValue: "gw-instance-001"))
        XCTAssertNil(gatewayCredential)
    }

    func testPendingIdentityDeleteFailureAfterConfirmedRevokeIsNotReportedAsRollback() async throws {
        await credentials.failSave()
        await identities.failDelete()
        let connection = connectionJSON
        EnrollmentURLProtocol.handler = { request in
            if request.url?.path == "/api/fleet/connection" { return (200, [:], Data(connection.utf8)) }
            if request.url?.path == "/api/fleet/devices/enroll" {
                let json = (try? JSONSerialization.jsonObject(with: EnrollmentURLProtocol.bodyData(request) ?? Data())) as? [String: String] ?? [:]
                let id = json["device_id"] ?? ""
                let secret = json["device_secret"] ?? ""
                let body = #"{"device":{"id":"\#(id)","label":"This phone"},"device_credential":"hfd1.\#(id).\#(secret)","gateway":{"instance_id":"gw-instance-001","display_name":"Synthetic gateway","origin":"https://gateway.example.invalid:9443"},"scopes":["fleet:operator"]}"#
                return (201, [:], Data(body.utf8))
            }
            if request.url?.path.hasPrefix("/api/fleet/devices/") == true { return (204, [:], Data()) }
            return (404, [:], Data())
        }

        do {
            _ = try await client().enrollDevice(at: address, authorization: authorization, deviceName: nil, deviceModel: nil)
            XCTFail("secure identity cleanup failure must be reported")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .identityStorageFailed)
        }
        XCTAssertTrue(EnrollmentURLProtocol.requests.contains { $0.httpMethod == "DELETE" })
        let pending = try await identities.loadIdentity(for: GatewayID(endpoint: address))
        XCTAssertNotNil(pending, "the unresolved keychain item stays available for explicit recovery")
    }

    func testCommittedCredentialWithPendingCleanupFailureRetriesSameIdentity() async throws {
        await identities.failDelete()
        let connection = connectionJSON
        let requests = EnrollmentRequestCapture()
        EnrollmentURLProtocol.handler = { request in
            if request.url?.path == "/api/fleet/connection" { return (200, [:], Data(connection.utf8)) }
            if request.url?.path == "/api/fleet/devices/enroll" {
                let requestBody = EnrollmentURLProtocol.bodyData(request) ?? Data()
                _ = requests.append(requestBody)
                let json = (try? JSONSerialization.jsonObject(with: requestBody)) as? [String: String] ?? [:]
                let id = json["device_id"] ?? ""
                let secret = json["device_secret"] ?? ""
                let body = #"{"device":{"id":"\#(id)","label":"This phone"},"device_credential":"hfd1.\#(id).\#(secret)","gateway":{"instance_id":"gw-instance-001","display_name":"Synthetic gateway","origin":"https://gateway.example.invalid:9443"},"scopes":["fleet:operator"]}"#
                return (201, [:], Data(body.utf8))
            }
            return (404, [:], Data())
        }

        do {
            _ = try await client().enrollDevice(at: address, authorization: authorization, deviceName: nil, deviceModel: nil)
            XCTFail("pending identity cleanup failure must not be hidden")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .identityStorageFailed)
        }
        let firstPending = try await identities.loadIdentity(for: GatewayID(endpoint: address))
        XCTAssertNotNil(firstPending)

        let retry = try await client().enrollDevice(at: address, authorization: authorization, deviceName: nil, deviceModel: nil)
        let payloads = requests.allBodies().compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        XCTAssertEqual(payloads.count, 2)
        XCTAssertTrue(
            payloads[0]["device_id"] == payloads[1]["device_id"]
                && payloads[0]["device_secret"] == payloads[1]["device_secret"],
            "recovery must reuse the same durable identity")
        XCTAssertEqual(retry.deviceID, firstPending?.deviceID)
        let finalPending = try await identities.loadIdentity(for: GatewayID(endpoint: address))
        XCTAssertNil(finalPending)
    }

    func testRevokedIdentityConflictCleansExactPendingAndNextAttemptUsesFreshID() async throws {
        await credentials.failSave()
        await identities.failDelete()
        let connection = connectionJSON
        let enrollRequests = EnrollmentRequestCapture()
        EnrollmentURLProtocol.handler = { request in
            if request.url?.path == "/api/fleet/connection" { return (200, [:], Data(connection.utf8)) }
            if request.url?.path == "/api/fleet/devices/enroll" {
                let requestBody = EnrollmentURLProtocol.bodyData(request) ?? Data()
                _ = enrollRequests.append(requestBody)
                let json = (try? JSONSerialization.jsonObject(with: requestBody)) as? [String: String] ?? [:]
                let id = json["device_id"] ?? ""
                let secret = json["device_secret"] ?? ""
                if enrollRequests.allBodies().count == 2 {
                    return (409, [:], Data(#"{"error":"enrollment_revoked","detail":"revoked"}"#.utf8))
                }
                let body = #"{"device":{"id":"\#(id)","label":"This phone"},"device_credential":"hfd1.\#(id).\#(secret)","gateway":{"instance_id":"gw-instance-001","display_name":"Synthetic gateway","origin":"https://gateway.example.invalid:9443"},"scopes":["fleet:operator"]}"#
                return (201, [:], Data(body.utf8))
            }
            if request.url?.path.hasPrefix("/api/fleet/devices/") == true { return (204, [:], Data()) }
            return (404, [:], Data())
        }

        do {
            _ = try await client().enrollDevice(at: address, authorization: authorization, deviceName: nil, deviceModel: nil)
            XCTFail("first credential save must fail")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .identityStorageFailed)
        }
        let revokedIdentity = try await identities.loadIdentity(for: GatewayID(endpoint: address))
        XCTAssertNotNil(revokedIdentity)

        do {
            _ = try await client().enrollDevice(at: address, authorization: authorization, deviceName: nil, deviceModel: nil)
            XCTFail("explicit revoked response should request a fresh setup attempt")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .previousEnrollmentRevoked)
        }
        let cleared = try await identities.loadIdentity(for: GatewayID(endpoint: address))
        XCTAssertNil(cleared)

        let retry = try await client().enrollDevice(at: address, authorization: authorization, deviceName: nil, deviceModel: nil)
        XCTAssertNotEqual(retry.deviceID, revokedIdentity?.deviceID)
        let bodies = enrollRequests.allBodies().compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        XCTAssertEqual(bodies.count, 3)
        XCTAssertTrue(bodies[0]["device_id"] == bodies[1]["device_id"], "revoked retry checks the same prior identity")
        XCTAssertTrue(bodies[2]["device_id"] != bodies[0]["device_id"], "the follow-up uses a fresh identity")
    }

    func testGenericEnrollmentConflictDoesNotRotateOrDeletePendingIdentity() async throws {
        let connection = connectionJSON
        EnrollmentURLProtocol.handler = { request in
            if request.url?.path == "/api/fleet/connection" { return (200, [:], Data(connection.utf8)) }
            if request.url?.path == "/api/fleet/devices/enroll" {
                return (409, [:], Data(#"{"error":"enrollment_conflict","detail":"conflict"}"#.utf8))
            }
            return (404, [:], Data())
        }

        do {
            _ = try await client().enrollDevice(at: address, authorization: authorization, deviceName: nil, deviceModel: nil)
            XCTFail("generic conflict must fail closed")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .serverRejected(statusCode: 409))
        }
        let pending = try await identities.loadIdentity(for: GatewayID(endpoint: address))
        XCTAssertNotNil(pending, "only the explicit enrollment_revoked response may rotate local state")
        XCTAssertTrue(EnrollmentURLProtocol.requests.allSatisfy { $0.httpMethod != "DELETE" })
    }
}
