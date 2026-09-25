import Foundation
import os
import FleetCore

/// Card C — concrete `ArtifactRetrieving` over the dashboard's authenticated
/// media API.
///
/// Wire contract (verified live + in source; `hermes_cli/web_routers/files.py`):
/// - `GET {base}/api/media?path=<gateway-local path>` → 200
///   `{"data_url": "data:image/<mime>;base64,<b64>"}` (`get_media`,
///   files.py:243-264). The path rides ONLY as a percent-encoded query item —
///   it is never a URL path component, never a public URL.
/// - Auth rides the dashboard session middleware exactly like the ws-ticket
///   mint and the kanban board fetch: `X-Hermes-Session-Token` (loopback /
///   session-token / bearer strategies — the stored credential) or the login
///   `Cookie` (username/password strategy). No credential → 401 (verified).
/// - Guards verified live: 403 outside the media roots, 415 for a
///   non-allowlisted extension, 413 above 25 MB, 404 once a cache entry has
///   aged out. The client ALSO fails the traversal/relative/URL-form/unknown-
///   extension classes locally, before any request.
/// - Transfers are bounded: a hard raw-body cap cancels the task mid-flight
///   (`BoundedTransferChannel`), and the decoded payload is capped again after
///   base64 decode.
public struct GatewayArtifactClient: ArtifactRetrieving {
    public let gatewayID: GatewayID
    /// Dashboard HTTP base (`http(s)://host:port`).
    public let baseURL: URL
    public let limits: ArtifactTransferLimits

    /// HTTP credential resolution for one media fetch, per auth strategy
    /// (mirrors `KanbanEventStreamClient.HTTPCredential`; credential
    /// resolution failures propagate — a failed password login is an error
    /// state, never a silent anonymous request). Values are never printed.
    public enum HTTPCredential: Sendable {
        case none
        case sessionTokenHeader(String)
        case cookie(SessionCookie)
    }

    private let credential: @Sendable () async throws -> HTTPCredential
    private let channel: BoundedTransferChannel

    private static let log = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "artifact-transport")

    /// - Parameters:
    ///   - urlSessionConfiguration: the session the bounded channel runs on.
    ///     Production passes the gateway-scoped configuration; tests inject a
    ///     stub `URLProtocol` here.
    ///   - trustHandler: the SAME per-gateway TOFU pin policy the other
    ///     credential-bearing REST sessions use (https gateways). Nil for
    ///     http/loopback and hermetic tests.
    public init(
        gatewayID: GatewayID,
        baseURL: URL,
        credential: @escaping @Sendable () async throws -> HTTPCredential = { .none },
        limits: ArtifactTransferLimits = .standard,
        urlSessionConfiguration: URLSessionConfiguration = .ephemeral,
        trustHandler: PinningTrustHandler? = nil
    ) {
        self.gatewayID = gatewayID
        self.baseURL = baseURL
        self.credential = credential
        self.limits = limits
        self.channel = BoundedTransferChannel(
            configuration: urlSessionConfiguration,
            trustHandler: trustHandler,
            capBytes: limits.maxEncodedResponseBytes)
    }

    // MARK: - Retrieval

    public func retrieve(_ reference: ArtifactReference) async throws -> RetrievedArtifact {
        // Binding first: never present one gateway's path to another gateway.
        guard reference.gatewayID == gatewayID else {
            throw ArtifactTransportError.gatewayMismatch(
                expected: gatewayID, actual: reference.gatewayID)
        }
        // Client-side guards — no request is made for a path the gateway
        // would resolve outside its media roots.
        let path = try ArtifactTransportRules.validatedPath(reference.path)
        if let known = reference.byteCount, known > limits.maxArtifactBytes {
            throw ArtifactTransportError.tooLarge(
                detail: "\(known) bytes exceeds the \(limits.maxArtifactBytes)-byte cap")
        }

        var request = URLRequest(url: try Self.makeMediaURL(base: baseURL, path: path))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = limits.transferTimeoutSeconds
        switch try await credential() {
        case .none:
            break
        case .sessionTokenHeader(let token):
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        case .cookie(let cookie):
            request.setValue(cookie.headerValue, forHTTPHeaderField: "Cookie")
        }

        let outcome = await channel.transfer(request)
        switch outcome {
        case .tooLarge:
            Self.log.error("media fetch exceeded the transfer cap")
            throw ArtifactTransportError.tooLarge(
                detail: "response exceeded the \(limits.maxEncodedResponseBytes)-byte transfer cap")
        case .httpStatus(let status):
            Self.log.error("media fetch: HTTP \(status)")
            throw Self.mapHTTPStatus(status)
        case .network(let domain, let code, let detail):
            if domain == NSURLErrorDomain && code == NSURLErrorTimedOut {
                throw ArtifactTransportError.timedOut(
                    detail: "no response within \(Int(limits.transferTimeoutSeconds))s")
            }
            throw ArtifactTransportError.transferFailed(detail: detail)
        case .body(let data, let status):
            guard (200..<300).contains(status) else {
                throw Self.mapHTTPStatus(status)
            }
            let artifact = try Self.decodeEnvelope(
                data, reference: reference, limits: limits)
            Self.log.info("media fetch ok (\(artifact.byteCount) bytes, \(artifact.mimeType, privacy: .public))")
            return artifact
        }
    }

    // MARK: - URL construction

    /// The one URL shape this transport emits: the authenticated media
    /// endpoint with the gateway path as a FULLY percent-encoded `path` QUERY
    /// item (RFC 3986 unreserved characters only, so the filesystem path can
    /// never be mistaken for URL structure — it never becomes a URL path
    /// component and no other endpoint ever sees it).
    public static func makeMediaURL(base: URL, path: String) throws -> URL {
        var components = URLComponents(
            url: base.appendingPathComponent("api/media"),
            resolvingAgainstBaseURL: false)
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw ArtifactTransportError.invalidReference(detail: "could not encode the media path")
        }
        components?.percentEncodedQueryItems = [URLQueryItem(name: "path", value: encoded)]
        guard let url = components?.url else {
            throw ArtifactTransportError.invalidReference(detail: "could not build the media URL")
        }
        return url
    }

    // MARK: - Response mapping

    static func mapHTTPStatus(_ status: Int) -> ArtifactTransportError {
        switch status {
        case 400:
            return .invalidReference(detail: "the gateway rejected the path (400)")
        case 401:
            return .authenticationRequired(
                detail: "sign in to this gateway to retrieve its artifacts")
        case 403:
            return .notPermitted(
                detail: "the path is outside the gateway's media roots")
        case 404:
            return .expired(
                detail: "the gateway no longer serves this path (cache retention or moved)")
        case 413:
            return .tooLarge(detail: "the gateway's own size cap rejected the file")
        case 415:
            return .unsupportedType(detail: "the gateway does not serve this media type")
        default:
            return .transferFailed(detail: "HTTP \(status)")
        }
    }

    /// Decode `{"data_url": "data:image/…;base64,…"}` into real bytes,
    /// enforcing the type + size + provenance guards.
    static func decodeEnvelope(
        _ body: Data,
        reference: ArtifactReference,
        limits: ArtifactTransferLimits
    ) throws -> RetrievedArtifact {
        struct Envelope: Decodable { let data_url: String? }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: body)
        } catch {
            throw ArtifactTransportError.malformedResponse(detail: "media envelope did not decode")
        }
        guard let dataURL = envelope.data_url, !dataURL.isEmpty else {
            throw ArtifactTransportError.malformedResponse(detail: "media envelope carried no data_url")
        }
        let (mime, encoded) = try splitDataURL(dataURL)
        guard let bytes = Data(base64Encoded: encoded) else {
            throw ArtifactTransportError.malformedResponse(detail: "data_url payload is not valid base64")
        }
        guard !bytes.isEmpty else {
            throw ArtifactTransportError.malformedResponse(detail: "data_url payload is empty")
        }
        guard bytes.count <= limits.maxArtifactBytes else {
            throw ArtifactTransportError.tooLarge(
                detail: "decoded \(bytes.count) bytes exceeds the \(limits.maxArtifactBytes)-byte cap")
        }
        guard ArtifactTransportRules.payloadMatches(declaredMIME: mime, bytes: bytes) else {
            throw ArtifactTransportError.malformedResponse(
                detail: "payload bytes contradict the declared \(mime) type")
        }
        if let declared = reference.mimeType,
           ArtifactTransportRules.normalizedMIME(declared) != mime {
            throw ArtifactTransportError.malformedResponse(
                detail: "gateway declared \(mime) for a reference that declared \(declared)")
        }
        return RetrievedArtifact(reference: reference, data: bytes, mimeType: mime)
    }

    /// Split `data:<mime>;base64,<payload>`; only image MIME types from the
    /// server's own table are accepted.
    static func splitDataURL(_ dataURL: String) throws -> (mime: String, encoded: String) {
        guard dataURL.hasPrefix("data:") else {
            throw ArtifactTransportError.malformedResponse(detail: "data_url is not a data URL")
        }
        guard let comma = dataURL.firstIndex(of: ",") else {
            throw ArtifactTransportError.malformedResponse(detail: "data_url has no payload separator")
        }
        let header = dataURL[dataURL.startIndex..<comma]
        guard header.hasSuffix(";base64") else {
            throw ArtifactTransportError.malformedResponse(detail: "data_url is not base64 encoded")
        }
        let mime = ArtifactTransportRules.normalizedMIME(
            String(header.dropFirst("data:".count).dropLast(";base64".count)))
        guard ArtifactTransportRules.allowedMIMETypes.contains(mime) else {
            throw ArtifactTransportError.unsupportedType(detail: "declared \(mime)")
        }
        return (mime, String(dataURL[dataURL.index(after: comma)...]))
    }
}

extension GatewayArtifactClient: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never prints a credential; the endpoint is redacted like every other
    /// gateway REST client.
    public var description: String {
        "GatewayArtifactClient(baseURL: \(Redaction.redactedURL(baseURL)))"
    }
    public var debugDescription: String { description }
}

// MARK: - Bounded transfer channel

/// One per client: the URLSession plus the per-task routing table that lets
/// each in-flight media fetch enforce its own byte cap. Session-level server
/// trust challenges chain to the gateway's TOFU pin handler, so artifact
/// fetches carry the same trust policy as every other REST call.
final class BoundedTransferChannel: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let capBytes: Int
    private let trustHandler: PinningTrustHandler?
    private let lock = NSLock()
    private var pending: [Int: BoundedTransfer] = [:]
    private var session: URLSession!

    init(configuration: URLSessionConfiguration, trustHandler: PinningTrustHandler?, capBytes: Int) {
        self.capBytes = capBytes
        self.trustHandler = trustHandler
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func transfer(_ request: URLRequest) async -> BoundedTransferOutcome {
        let task = session.dataTask(with: request)
        let transfer = BoundedTransfer(capBytes: capBytes)
        lock.withLock {
            pending[task.taskIdentifier] = transfer
        }
        defer {
            lock.withLock {
                pending[task.taskIdentifier] = nil
            }
        }
        return await transfer.run(task)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let transfer = pending[dataTask.taskIdentifier]
        lock.unlock()
        guard let transfer else {
            completionHandler(.allow)
            return
        }
        completionHandler(transfer.received(response: response, task: dataTask))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let transfer = pending[dataTask.taskIdentifier]
        lock.unlock()
        transfer?.received(data: data, task: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let transfer = pending[task.taskIdentifier]
        lock.unlock()
        transfer?.completed(error: error)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trustHandler else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        trustHandler.evaluate(challenge, completionHandler: completionHandler)
    }
}

/// What one bounded transfer ended as.
enum BoundedTransferOutcome: Sendable {
    case body(Data, status: Int)
    case httpStatus(Int)
    case tooLarge
    case network(domain: String, code: Int, detail: String)
}

/// One in-flight media fetch: accumulates at most `capBytes`, cancels the task
/// the moment the response or the body crosses the cap, and resumes its
/// continuation exactly once.
final class BoundedTransfer: @unchecked Sendable {
    private let capBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BoundedTransferOutcome, Never>?
    private var finished = false
    private var accumulated = Data()
    private var statusCode: Int?

    init(capBytes: Int) {
        self.capBytes = capBytes
    }

    func run(_ task: URLSessionDataTask) async -> BoundedTransferOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            task.resume()
        }
    }

    func received(response: URLResponse, task: URLSessionDataTask) -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            finish(.network(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                            detail: "non-HTTP response"))
            return .cancel
        }
        lock.lock()
        statusCode = http.statusCode
        lock.unlock()
        // Non-2xx: the status alone classifies the failure — never buffer an
        // error body we would not use.
        guard (200..<300).contains(http.statusCode) else {
            finish(.httpStatus(http.statusCode))
            return .cancel
        }
        if let rawLength = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(rawLength), length > capBytes {
            finish(.tooLarge)
            return .cancel
        }
        return .allow
    }

    func received(data: Data, task: URLSessionDataTask) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if accumulated.count + data.count > capBytes {
            lock.unlock()
            finish(.tooLarge)
            task.cancel()
            return
        }
        accumulated.append(data)
        lock.unlock()
    }

    func completed(error: Error?) {
        if let error {
            let nsError = error as NSError
            finish(.network(domain: nsError.domain, code: nsError.code,
                            detail: Redaction.safeErrorDescription(error)))
            return
        }
        lock.lock()
        let status = statusCode
        lock.unlock()
        finish(.body(accumulated, status: status ?? 0))
    }

    private func finish(_ outcome: BoundedTransferOutcome) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: outcome)
    }
}
