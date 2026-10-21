import Foundation
import Network
import os

/// A short-lived loopback HTTP listener that accepts the OAuth redirect
/// from the gateway (`http://127.0.0.1:<port>/cb?code=…&state=…`).
///
/// The gateway's `_validate_loopback_redirect_uri` accepts ONLY
/// `http://127.0.0.1[:port]/…` or `http://[::1][:port]/…` — no
/// `localhost`, no custom schemes, no universal links. This listener
/// binds to 127.0.0.1 on an ephemeral port, serves exactly one request,
/// responds with a 302 to `hermes-fleet://oauth-callback?…` so
/// `ASWebAuthenticationSession` can capture it via `callbackURLScheme`,
/// then shuts down.
///
/// Single-use: after the redirect is received (or a timeout fires), the
/// listener stops and the port is released.
public actor LoopbackOAuthListener {
    /// The result of the OAuth callback. Query values are percent-decoded.
    public struct OAuthCallbackResult: Sendable, Equatable {
        public let code: String
        public let state: String

        public init(code: String, state: String) {
            self.code = code
            self.state = state
        }
    }

    private let listener: NWListener
    private var assignedPort: UInt16 = 0
    private var continuation: CheckedContinuation<OAuthCallbackResult, Error>?
    private var pendingResult: Result<OAuthCallbackResult, NativeOAuthError>?
    private var isFinished = false
    private var timeoutTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.aiowa.hermesfleet", category: "loopback-oauth")

    /// Start a new loopback listener on an ephemeral port.
    public init() async throws {
        let parameters = Self.listenerParameters()

        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: parameters, on: .any)
        } catch {
            throw NativeOAuthError.internalError("Failed to create loopback listener")
        }
        self.listener = nwListener
        // Network.framework expects the accept handler to be installed before
        // start. Starting first can fail the listener on simulator/device
        // runtimes before the ephemeral port is reported ready.
        nwListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleConnection(connection) }
        }

        let readyPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce()
            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = nwListener.port {
                        box.resume { continuation.resume(returning: port.rawValue) }
                    } else {
                        box.resume {
                            continuation.resume(throwing: NativeOAuthError.internalError("Listener ready without a port"))
                        }
                    }
                case .failed(let error):
                    box.resume {
                        continuation.resume(throwing: NativeOAuthError.internalError("Loopback listener failed: \(error)"))
                    }
                case .cancelled:
                    box.resume { continuation.resume(throwing: NativeOAuthError.cancelled) }
                default:
                    break
                }
            }
            nwListener.start(queue: .global(qos: .userInitiated))
        }
        self.assignedPort = readyPort
        log.info("Loopback listener ready on port \(readyPort, privacy: .public)")
    }

    /// Keep the callback socket private to this device. The redirect URI is
    /// explicitly IPv4 loopback, so binding to `NWEndpoint.Port.any` alone
    /// would expose the one-time authorization code listener on every local
    /// interface.
    static func listenerParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: .any)
        return parameters
    }

    /// The loopback redirect URI to pass to `/auth/native/authorize`.
    /// Format: `http://127.0.0.1:<port>/cb`
    public var redirectURI: String {
        "http://127.0.0.1:\(assignedPort)/cb"
    }

    /// Wait for the OAuth redirect callback. Times out after `timeout`
    /// seconds (default 300; the gateway's pending TTL is 600s).
    public func waitForCallback(timeout: TimeInterval = 300) async throws -> OAuthCallbackResult {
        if let pendingResult {
            self.pendingResult = nil
            return try pendingResult.get()
        }
        guard !isFinished else { throw NativeOAuthError.cancelled }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OAuthCallbackResult, Error>) in
            self.continuation = continuation
            self.timeoutTask = Task { [weak self] in
                let nanos = UInt64(max(timeout, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                await self?.fail(.callbackTimeout)
            }
        }
    }

    /// Stop the listener and release the port. Safe to call more than once.
    public func stop() {
        finish(.failure(.cancelled))
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { await self?.receiveRequest(on: connection) }
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: max(1, 8192 - accumulated.count)
        ) { [weak self] data, _, isComplete, error in
            var requestData = accumulated
            if let data { requestData.append(data) }
            Task {
                guard let self else { return }
                let hasCompleteHeaders = requestData.range(of: Data("\r\n\r\n".utf8)) != nil
                if error != nil || isComplete || hasCompleteHeaders || requestData.count >= 8192 {
                    await self.processRequest(data: requestData, error: error, connection: connection)
                } else {
                    await self.receiveRequest(on: connection, accumulated: requestData)
                }
            }
        }
    }

    private func processRequest(data: Data?, error: NWError?, connection: NWConnection) {
        if error != nil {
            connection.cancel()
            return
        }
        guard let data, !data.isEmpty, let requestString = String(data: data, encoding: .utf8) else {
            connection.cancel()
            fail(.missingCode)
            return
        }
        guard data.range(of: Data("\r\n\r\n".utf8)) != nil else {
            connection.cancel()
            fail(.missingCode)
            return
        }

        let parsed = Self.parseCallback(requestString)
        let code = parsed.code ?? ""
        let state = parsed.state ?? ""
        var callbackComponents = URLComponents()
        callbackComponents.scheme = "hermes-fleet"
        callbackComponents.host = "oauth-callback"
        callbackComponents.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "state", value: state),
        ]
        guard let appSchemeURL = callbackComponents.string else {
            connection.cancel()
            fail(.internalError("Failed to build OAuth callback URL"))
            return
        }
        let response = """
            HTTP/1.1 302 Found\r
            Location: \(appSchemeURL)\r
            Content-Length: 0\r
            Connection: close\r
            \r
            """
        let responseData = Data(response.utf8)
        connection.send(content: responseData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            Task {
                if let error {
                    await self?.fail(.internalError("Failed to send OAuth callback response: \(error)"))
                } else if let code = parsed.code, let state = parsed.state, !code.isEmpty, !state.isEmpty {
                    await self?.succeed(OAuthCallbackResult(code: code, state: state))
                } else {
                    await self?.fail(.missingCode)
                }
            }
        })
    }

    private func succeed(_ result: OAuthCallbackResult) {
        finish(.success(result))
    }

    private func fail(_ error: NativeOAuthError) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<OAuthCallbackResult, NativeOAuthError>) {
        guard !isFinished else {
            listener.cancel()
            return
        }
        isFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if let continuation {
            self.continuation = nil
            switch result {
            case .success(let callback): continuation.resume(returning: callback)
            case .failure(let error): continuation.resume(throwing: error)
            }
        } else {
            pendingResult = result
        }
        listener.cancel()
        log.info("Loopback listener stopped")
    }

    /// Parse `GET /cb?code=…&state=… HTTP/1.1`. Values are percent-decoded.
    static func parseCallback(_ request: String) -> (code: String?, state: String?) {
        guard let firstLine = request.split(separator: "\r\n").first else {
            return (nil, nil)
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return (nil, nil) }
        let urlPath = String(parts[1])
        guard urlPath.hasPrefix("/cb?") else { return (nil, nil) }
        guard let queryStart = urlPath.firstIndex(of: "?") else { return (nil, nil) }
        let query = String(urlPath[urlPath.index(after: queryStart)...])
        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            params[key] = value
        }
        return (params["code"], params["state"])
    }
}

/// Resumes a continuation at most once. Network.framework can emit more than
/// one terminal state update; double-resume is a crash.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
