import XCTest
import FleetCore
import FleetNetworking

/// Stub `URLProtocol` serving the `/api/media` contract hermetically: capture
/// every request, then answer with a configurable status/headers/body (body
/// optionally delivered in chunks so streaming-cap cancellation is exercised).
final class MediaStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct ResponsePlan {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data()
        /// When set, the body is delivered chunk-by-chunk instead of at once.
        var chunks: [Data]? = nil
        /// Fail the task with this error instead of responding.
        var failure: Error? = nil
    }

    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) static var plan = ResponsePlan()
    nonisolated(unsafe) static var didCancel = false

    private var stopped = false
    private let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        let plan = Self.plan
        if let failure = plan.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: plan.status,
            httpVersion: "HTTP/1.1", headerFields: plan.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let chunks = plan.chunks {
            deliver(chunks, index: 0)
        } else {
            client?.urlProtocol(self, didLoad: plan.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func deliver(_ chunks: [Data], index: Int) {
        guard index < chunks.count else {
            if !isStopped { client?.urlProtocolDidFinishLoading(self) }
            return
        }
        guard !isStopped else { return }
        client?.urlProtocol(self, didLoad: chunks[index])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { [weak self] in
            self?.deliver(chunks, index: index + 1)
        }
    }

    override func stopLoading() {
        lock.lock()
        stopped = true
        Self.didCancel = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

final class GatewayArtifactClientTests: XCTestCase {
    private let gateway = GatewayID(rawValue: "dev-gateway")

    override func setUp() {
        super.setUp()
        MediaStubURLProtocol.capturedRequests = []
        MediaStubURLProtocol.plan = .init()
        MediaStubURLProtocol.didCancel = false
    }

    // MARK: Fixtures

    private static func pngBytes(extra: Int = 64) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(contentsOf: (0..<extra).map { UInt8($0 % 251) })
        return data
    }

    private static func jpegBytes() -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x41, count: 32)
    }

    private static func envelope(_ bytes: Data, mime: String = "image/png") -> Data {
        Data(#"{"data_url":"data:\#(mime);base64,\#(bytes.base64EncodedString())"}"#.utf8)
    }

    private func makeClient(
        limitBytes: Int = 36 * 1024 * 1024,
        decodedLimit: Int = 25 * 1024 * 1024,
        token: String? = "stub-session-token",
        cookie: SessionCookie? = nil
    ) -> GatewayArtifactClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaStubURLProtocol.self]
        let limits = ArtifactTransferLimits(
            maxArtifactBytes: decodedLimit,
            maxEncodedResponseBytes: limitBytes,
            transferTimeoutSeconds: 5)
        return GatewayArtifactClient(
            gatewayID: gateway,
            baseURL: URL(string: "https://gateway.example.invalid:9120")!,
            credential: {
                if let cookie { return .cookie(cookie) }
                if let token { return .sessionTokenHeader(token) }
                return .none
            },
            limits: limits,
            urlSessionConfiguration: config)
    }

    private func reference(
        path: String = "/var/lib/gateway/cache/images/fleet-pin.png",
        mimeType: String? = nil,
        byteCount: Int? = nil
    ) -> ArtifactReference {
        ArtifactReference(
            gatewayID: gateway,
            sessionID: "session-1",
            profile: "default",
            path: path,
            name: "fleet-pin.png",
            mimeType: mimeType,
            byteCount: byteCount)
    }

    // MARK: Real bytes

    func testRetrievesRealBytesThroughAuthenticatedMediaEndpoint() async throws {
        let payload = Self.pngBytes()
        MediaStubURLProtocol.plan.body = Self.envelope(payload)

        let artifact = try await makeClient().retrieve(reference())

        // REAL bytes — byte-identical to what the gateway served.
        XCTAssertEqual(artifact.data, payload)
        XCTAssertEqual(artifact.byteCount, payload.count)
        XCTAssertEqual(artifact.mimeType, "image/png")
        // Provenance travels with the payload.
        XCTAssertEqual(artifact.reference.gatewayID, gateway)
        XCTAssertEqual(artifact.reference.sessionID, "session-1")
        XCTAssertEqual(artifact.reference.profile, "default")

        // The request itself: authenticated GET, path ONLY as a query item.
        let request = try XCTUnwrap(MediaStubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "stub-session-token")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/media")
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "path", value: "/var/lib/gateway/cache/images/fleet-pin.png")])
    }

    func testGatewayPathNeverBecomesAURLPathOrPublicURL() async throws {
        MediaStubURLProtocol.plan.body = Self.envelope(Self.pngBytes())
        let gatewayPath = "/Users/someone/.hermes/cache/images/a b.png"
        _ = try await makeClient().retrieve(reference(path: gatewayPath))

        let url = try XCTUnwrap(MediaStubURLProtocol.capturedRequests.first?.url)
        XCTAssertEqual(url.path, "/api/media")
        XCTAssertEqual(url.scheme, "https")
        // Fully percent-encoded query value; nothing of the path leaks into
        // URL structure and the round-trip still yields the exact gateway path.
        XCTAssertTrue(url.absoluteString.contains(
            "path=%2FUsers%2Fsomeone%2F.hermes%2Fcache%2Fimages%2Fa%20b.png"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "path", value: gatewayPath)])
    }

    func testCookieCredentialRidesTheRequest() async throws {
        MediaStubURLProtocol.plan.body = Self.envelope(Self.pngBytes())
        _ = try await makeClient(token: nil, cookie: SessionCookie(name: "hermes_session_at", value: "at-123"))
            .retrieve(reference())

        let request = try XCTUnwrap(MediaStubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "hermes_session_at=at-123")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"))
    }

    // MARK: Client-side guards (no request at all)

    func testTraversalReferenceIsRefusedBeforeAnyRequest() async {
        await assertRefusedLocally("/etc/../../etc/passwd.png", detailContains: "traversal")
    }

    func testRelativeReferenceIsRefusedBeforeAnyRequest() async {
        await assertRefusedLocally("cache/images/fleet-pin.png", detailContains: "absolute")
    }

    func testURLFormReferenceIsRefusedBeforeAnyRequest() async {
        await assertRefusedLocally("file:///tmp/fleet-pin.png", detailContains: "URL")
    }

    func testNonAllowlistedExtensionIsRefusedBeforeAnyRequest() async {
        await assertRefusedLocally("/tmp/fleet-devgw/cache/notes.txt", detailContains: "allowlist")
    }

    func testKnownByteCountAboveCapIsRefusedBeforeAnyRequest() async {
        let reference = reference(byteCount: 30 * 1024 * 1024)
        do {
            _ = try await makeClient().retrieve(reference)
            XCTFail("expected tooLarge")
        } catch let error as ArtifactTransportError {
            guard case .tooLarge = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(MediaStubURLProtocol.capturedRequests.isEmpty)
    }

    func testGatewayMismatchIsRefusedBeforeAnyRequest() async {
        let foreign = ArtifactReference(
            gatewayID: GatewayID(rawValue: "other-gateway"),
            path: "/var/cache/images/x.png", name: "x.png")
        do {
            _ = try await makeClient().retrieve(foreign)
            XCTFail("expected gatewayMismatch")
        } catch let error as ArtifactTransportError {
            XCTAssertEqual(
                error, .gatewayMismatch(expected: gateway, actual: GatewayID(rawValue: "other-gateway")))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(MediaStubURLProtocol.capturedRequests.isEmpty)
    }

    private func assertRefusedLocally(_ path: String, detailContains: String) async {
        do {
            _ = try await makeClient().retrieve(reference(path: path))
            XCTFail("expected invalidReference for \(path)")
        } catch let error as ArtifactTransportError {
            guard case .invalidReference(let detail) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(detail.contains(detailContains), "detail was: \(detail)")
            // The refusal copy never echoes the path itself.
            XCTAssertFalse(error.description.contains(path))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(MediaStubURLProtocol.capturedRequests.isEmpty)
    }

    // MARK: Status mapping + expiration

    func testUnauthenticatedStatusMapsToAuthenticationRequired() async {
        MediaStubURLProtocol.plan.status = 401
        await assertStatusMaps(401) { error in
            guard case .authenticationRequired = error else { return false }
            return true
        }
    }

    func testOutsideRootsStatusMapsToNotPermitted() async {
        await assertStatusMaps(403) { error in
            guard case .notPermitted = error else { return false }
            return true
        }
    }

    func testExpiredStatusMapsToExpiredAndIsExpiration() async {
        MediaStubURLProtocol.plan.status = 404
        await assertStatusMaps(404) { error in
            XCTAssertTrue(error.isExpiration)
            guard case .expired = error else { return false }
            return true
        }
    }

    func testServerSizeCapMapsToTooLarge() async {
        await assertStatusMaps(413) { error in
            guard case .tooLarge = error else { return false }
            return true
        }
    }

    func testUnsupportedTypeStatusMapsToUnsupportedType() async {
        await assertStatusMaps(415) { error in
            guard case .unsupportedType = error else { return false }
            return true
        }
    }

    func testServerErrorMapsToTransferFailed() async {
        await assertStatusMaps(500) { error in
            guard case .transferFailed = error else { return false }
            return true
        }
    }

    private func assertStatusMaps(
        _ status: Int,
        _ check: (ArtifactTransportError) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        MediaStubURLProtocol.plan.status = status
        MediaStubURLProtocol.plan.body = Data(#"{"detail":"nope"}"#.utf8)
        do {
            _ = try await makeClient().retrieve(reference())
            XCTFail("expected failure for HTTP \(status)", file: file, line: line)
        } catch let error as ArtifactTransportError {
            XCTAssertTrue(check(error), "unexpected classification \(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Bounded transfers

    func testAdvertisedContentLengthAboveCapFailsWithoutBuffering() async {
        MediaStubURLProtocol.plan.headers = [
            "Content-Type": "application/json",
            "Content-Length": String(64 * 1024 * 1024),
        ]
        MediaStubURLProtocol.plan.body = Self.envelope(Self.pngBytes())
        do {
            _ = try await makeClient(limitBytes: 1024 * 1024).retrieve(reference())
            XCTFail("expected tooLarge")
        } catch let error as ArtifactTransportError {
            guard case .tooLarge = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testStreamingBodyAboveCapIsAbortedMidFlight() async {
        // A body far larger than the cap arrives in chunks; the transfer must
        // abort (cancel) rather than buffer the whole thing.
        let chunk = Data(repeating: 0x41, count: 4096)
        MediaStubURLProtocol.plan.chunks = Array(repeating: chunk, count: 64) // 256 KB
        do {
            _ = try await makeClient(limitBytes: 16 * 1024).retrieve(reference())
            XCTFail("expected tooLarge")
        } catch let error as ArtifactTransportError {
            guard case .tooLarge = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
        let cancelledMidFlight = await waitForStubCancellation()
        XCTAssertTrue(cancelledMidFlight, "the oversized transfer must be cancelled mid-flight")
    }

    /// `stopLoading` lands on the protocol's queue asynchronously; give the
    /// cancellation a bounded moment to surface.
    private func waitForStubCancellation(timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if MediaStubURLProtocol.didCancel { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return MediaStubURLProtocol.didCancel
    }

    func testDecodedPayloadAboveCapFails() async {
        // Encoded response fits the raw cap; the DECODED payload exceeds the
        // artifact cap.
        let payload = Self.pngBytes(extra: 4096)
        MediaStubURLProtocol.plan.body = Self.envelope(payload)
        do {
            _ = try await makeClient(limitBytes: 1024 * 1024, decodedLimit: 1024).retrieve(reference())
            XCTFail("expected tooLarge")
        } catch let error as ArtifactTransportError {
            guard case .tooLarge = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTimeoutMapsToTimedOut() async {
        MediaStubURLProtocol.plan.failure = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        do {
            _ = try await makeClient().retrieve(reference())
            XCTFail("expected timedOut")
        } catch let error as ArtifactTransportError {
            guard case .timedOut = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testConnectionFailureMapsToTransferFailed() async {
        MediaStubURLProtocol.plan.failure = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        do {
            _ = try await makeClient().retrieve(reference())
            XCTFail("expected transferFailed")
        } catch let error as ArtifactTransportError {
            guard case .transferFailed = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Envelope / type guards

    func testMissingDataURLIsMalformed() async {
        MediaStubURLProtocol.plan.body = Data(#"{"ok":true}"#.utf8)
        await assertDecodeFailure("malformed")
    }

    func testNonBase64DataURLIsMalformed() async {
        MediaStubURLProtocol.plan.body = Data(#"{"data_url":"data:image/png,plain-not-base64"}"#.utf8)
        await assertDecodeFailure("malformed")
    }

    func testInvalidBase64PayloadIsMalformed() async {
        MediaStubURLProtocol.plan.body = Data(#"{"data_url":"data:image/png;base64,@@@@"}"#.utf8)
        await assertDecodeFailure("malformed")
    }

    func testDeclaredTypeContradictingPayloadBytesIsMalformed() async {
        // Bytes are PNG; the envelope declares image/jpeg.
        MediaStubURLProtocol.plan.body = Self.envelope(Self.pngBytes(), mime: "image/jpeg")
        await assertDecodeFailure("malformed")
    }

    func testNonImageDataURLIsUnsupported() async {
        MediaStubURLProtocol.plan.body = Data(
            #"{"data_url":"data:text/html;base64,PGh0bWw+"}"#.utf8)
        do {
            _ = try await makeClient().retrieve(reference())
            XCTFail("expected unsupportedType")
        } catch let error as ArtifactTransportError {
            guard case .unsupportedType = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testReferenceMIMEContradictionIsMalformed() async {
        MediaStubURLProtocol.plan.body = Self.envelope(Self.pngBytes())
        do {
            _ = try await makeClient().retrieve(reference(mimeType: "image/jpeg"))
            XCTFail("expected malformedResponse")
        } catch let error as ArtifactTransportError {
            guard case .malformedResponse = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testJPEGPayloadWithJPEGEnvelopeSucceeds() async throws {
        let payload = Self.jpegBytes()
        MediaStubURLProtocol.plan.body = Self.envelope(payload, mime: "image/jpeg")
        let artifact = try await makeClient().retrieve(reference(mimeType: "image/jpeg"))
        XCTAssertEqual(artifact.data, payload)
        XCTAssertEqual(artifact.mimeType, "image/jpeg")
    }

    private func assertDecodeFailure(_ kind: String) async {
        do {
            _ = try await makeClient().retrieve(reference())
            XCTFail("expected \(kind) failure")
        } catch let error as ArtifactTransportError {
            guard case .malformedResponse = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Redaction

    func testClientAndErrorsNeverPrintCredentialsOrPaths() async {
        let client = makeClient()
        XCTAssertFalse("\(client)".contains("stub-session-token"))

        let foreignPath = "/Users/someone/.hermes/cache/images/secret-name.png"
        do {
            _ = try await client.retrieve(reference(path: foreignPath + ".exe"))
            XCTFail("expected invalidReference")
        } catch let error as ArtifactTransportError {
            XCTAssertFalse(error.description.contains(foreignPath))
            XCTAssertFalse(error.description.contains("Users"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testReferenceDescriptionNeverPrintsTheHostPath() {
        let ref = reference(path: "/Users/someone/.hermes/cache/images/leak.png")
        XCTAssertFalse(ref.description.contains("/Users/someone"))
        XCTAssertFalse(ref.description.contains("leak.png"))
        XCTAssertTrue(ref.description.contains("fleet-pin.png"))
        XCTAssertEqual(ref.displayName, "fleet-pin.png")
    }
}
