import Foundation
import Security
import FleetCore

/// Why a one-shot call failed. No case carries a URL, credential, header, or raw
/// server text: messages from the server are bounded and redacted with
/// `Redaction.safeText`, everything else is a fixed reason or a numeric code.
public enum OneShotRPCError: Error, Sendable, Equatable {
    /// The endpoint is not an https URL with a host, or carries user-info,
    /// a query string, or a fragment (credentials never travel in the URL).
    case invalidEndpoint
    case invalidRequest
    /// The call did not complete within the timeout.
    case timeout
    /// TLS pin check refused the connection (`PinVerdict` other than matched).
    case pinRejected(PinVerdict)
    /// The server answered with a non-2xx HTTP status.
    case httpStatus(Int)
    /// The response body exceeded the size cap.
    case responseTooLarge
    /// The response was not a valid JSON-RPC 2.0 reply.
    case malformedResponse
    /// JSON-RPC error reply (`message` is redacted and bounded).
    case rpcError(code: Int, message: String)
    /// Any other transport failure (numeric `URLError` code only).
    case network(code: Int)
}

/// A tiny, extension-safe one-shot HTTPS JSON-RPC 2.0 call: one POST, one reply,
/// then the session is torn down. No WebSocket, no retained connection, no
/// background work.
///
/// Guarantees:
/// - https only; the URL may not carry user-info, query, or fragment;
/// - bounded time (`timeout`, clamped 1...30 s) and bounded response size;
/// - server trust is decided ONLY by the SPKI pin check in `PinVerifier`
///   (verify-only: a missing pin, a mismatch, or a store failure all reject; a
///   one-shot call never trusts on first use). In the app, pass the shared pin
///   store; an extension that cannot read the app-private pin store must be
///   handed a pin through another channel (`FixedPinStore`);
/// - ephemeral session: no cookies, no disk cache, no credential storage;
/// - errors are redacted (`OneShotRPCError`).
///
/// It mints no credentials. The caller supplies any bearer token for the single
/// call and is responsible for where it came from (see `docs/extension-kit.md`:
/// extensions use single-use response tokens carried in payloads; gateway
/// credentials are never placed in a shared keychain group).
public struct OneShotJSONRPCClient: Sendable {
    public static let defaultTimeout: TimeInterval = 10
    public static let maximumResponseBytes = 256 * 1024

    private let verifier: PinVerifier
    private let timeout: TimeInterval
    private let sessionConfiguration: @Sendable () -> URLSessionConfiguration

    /// - Parameter sessionConfiguration: test seam (register a `URLProtocol`);
    ///   production uses an ephemeral configuration.
    public init(
        gatewayID: GatewayID,
        pinStore: any SynchronousPinStoring,
        timeout: TimeInterval = OneShotJSONRPCClient.defaultTimeout,
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) {
        self.verifier = PinVerifier(gatewayID: gatewayID, pinStore: pinStore)
        self.timeout = min(max(timeout, 1), 30)
        self.sessionConfiguration = sessionConfiguration
    }

    /// Perform one JSON-RPC call and return its `result`.
    public func call(
        endpoint: URL,
        method: String,
        params: MetadataValue? = nil,
        bearerToken: String? = nil
    ) async throws -> MetadataValue {
        try Self.validate(endpoint: endpoint)
        guard !method.isEmpty, method.count <= 128 else { throw OneShotRPCError.invalidRequest }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try Self.encodeEnvelope(method: method, params: params)

        let configuration = sessionConfiguration()
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let delegate = PinVerifyingSessionDelegate(verifier: verifier)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let body: Data
        do {
            body = try await Self.fetch(request, session: session)
        } catch let error as OneShotRPCError {
            throw error
        } catch let error as URLError {
            if let verdict = delegate.rejectedVerdict { throw OneShotRPCError.pinRejected(verdict) }
            if error.code == .timedOut { throw OneShotRPCError.timeout }
            throw OneShotRPCError.network(code: error.errorCode)
        } catch {
            if let verdict = delegate.rejectedVerdict { throw OneShotRPCError.pinRejected(verdict) }
            throw OneShotRPCError.network(code: (error as NSError).code)
        }
        return try Self.decodeResult(body)
    }

    // MARK: request / response

    static func validate(endpoint: URL) throws {
        guard endpoint.scheme?.lowercased() == "https",
              let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else {
            throw OneShotRPCError.invalidEndpoint
        }
    }

    static func encodeEnvelope(method: String, params: MetadataValue?) throws -> Data {
        var envelope: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
        if let params { envelope["params"] = jsonObject(from: params) }
        guard JSONSerialization.isValidJSONObject(envelope) else { throw OneShotRPCError.invalidRequest }
        do {
            return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        } catch {
            throw OneShotRPCError.invalidRequest
        }
    }

    private static func fetch(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw OneShotRPCError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw OneShotRPCError.httpStatus(http.statusCode) }
        if http.expectedContentLength > Int64(maximumResponseBytes) {
            throw OneShotRPCError.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumResponseBytes { throw OneShotRPCError.responseTooLarge }
        }
        return data
    }

    static func decodeResult(_ data: Data) throws -> MetadataValue {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
                as? [String: Any] else {
            throw OneShotRPCError.malformedResponse
        }
        if let error = root["error"] as? [String: Any] {
            guard let code = error["code"] as? Int else { throw OneShotRPCError.malformedResponse }
            throw OneShotRPCError.rpcError(
                code: code,
                message: Redaction.safeText((error["message"] as? String) ?? ""))
        }
        guard root["jsonrpc"] as? String == "2.0", let result = root["result"] else {
            throw OneShotRPCError.malformedResponse
        }
        return metadataValue(from: result)
    }

    // MARK: JSON <-> MetadataValue
    // `MetadataValue`'s synthesized Codable is not plain JSON, so convert by hand.

    static func jsonObject(from value: MetadataValue) -> Any {
        switch value {
        case .string(let text): return text
        case .number(let number): return number
        case .bool(let flag): return flag
        case .null: return NSNull()
        case .array(let items): return items.map { jsonObject(from: $0) }
        case .object(let fields): return fields.mapValues { jsonObject(from: $0) }
        }
    }

    static func metadataValue(from object: Any) -> MetadataValue {
        switch object {
        case let text as String:
            return .string(text)
        case let number as NSNumber:
            // JSONSerialization bridges booleans as a distinct CFBoolean.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case is NSNull:
            return .null
        case let items as [Any]:
            return .array(items.map { metadataValue(from: $0) })
        case let fields as [String: Any]:
            return .object(fields.mapValues { metadataValue(from: $0) })
        default:
            return .null
        }
    }
}

/// Session delegate that decides server-trust challenges purely by SPKI pin.
final class PinVerifyingSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let verifier: PinVerifier
    private let lock = NSLock()
    private var rejected: PinVerdict?

    init(verifier: PinVerifier) {
        self.verifier = verifier
    }

    /// The verdict that caused a rejection, if the pin check refused the peer.
    var rejectedVerdict: PinVerdict? {
        lock.lock(); defer { lock.unlock() }
        return rejected
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            // Not a server-trust challenge (for example a client-certificate or
            // basic-auth request): a one-shot call answers none of them.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let verdict = verifier.verdict(forServerTrust: trust)
        if verdict == .matched {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            lock.lock(); rejected = verdict; lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
