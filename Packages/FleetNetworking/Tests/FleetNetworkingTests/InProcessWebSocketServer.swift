import Foundation
import Network

/// In-process RFC6455 WebSocket server fixture (Network.framework), used to
/// exercise `URLSessionWebSocketTask` against a scripted gateway without any
/// live Hermes node. This is the M1 "fixtures / in-process test server" seam.
///
/// Behavior is scripted per connection:
///   - `onOpen`: frames pushed immediately after the WS handshake completes
///     (e.g. `gateway.ready`).
///   - `onText`: closure mapping each inbound text frame to reply frames.
///   - `closeAfterInboundCount`: optional auto-close after N inbound frames.
public final class InProcessWebSocketServer: @unchecked Sendable {
    public struct Script: Sendable {
        public var onOpen: [String]
        public var onText: @Sendable (String) -> [String]
        public var closeAfterInboundCount: Int?

        public init(
            onOpen: [String] = [],
            onText: @escaping @Sendable (String) -> [String] = { _ in [] },
            closeAfterInboundCount: Int? = nil
        ) {
            self.onOpen = onOpen
            self.onText = onText
            self.closeAfterInboundCount = closeAfterInboundCount
        }
    }

    private let listener: NWListener
    /// One script per accepted connection; connection N uses
    /// `scripts[min(N, scripts.count-1)]` so reconnects can be scripted with
    /// different behavior per connection (P4 reconnect suite).
    private let scripts: [Script]
    private let stateLock = NSLock()
    private var _connection: NWConnection?
    private var _inboundCount = 0
    private var _connectionCount = 0

    public convenience init(script: Script) throws {
        try self.init(scripts: [script])
    }

    public init(scripts: [Script]) throws {
        self.scripts = scripts.isEmpty ? [Script()] : scripts
        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.setClientRequestHandler(DispatchQueue.global()) { _, _ in
            .init(status: .accept, subprotocol: nil, additionalHeaders: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        self.listener = try NWListener(using: parameters, on: .any)
    }

    /// The number of WebSocket connections accepted so far (1-based). Lets a
    /// test observe that a reconnect actually opened a fresh connection.
    public var connectionCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _connectionCount
    }

    /// The port this server is listening on (valid after `start`).
    public var listeningPort: UInt16 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listener.port?.rawValue ?? 0
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                case .failed(let error):
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: .global())
        }
    }

    public func stop() {
        stateLock.lock()
        let connection = _connection
        stateLock.unlock()
        connection?.cancel()
        listener.cancel()
    }

    /// Abruptly cancel the current connection WITHOUT a close frame — the
    /// network-switch / abnormal-loss simulation (client observes a transport
    /// error, no close code → `.abnormalClosure`).
    public func abortConnection() {
        stateLock.lock()
        let connection = _connection
        stateLock.unlock()
        connection?.cancel()
    }

    /// Deliver a server→client close frame with the given application code
    /// (e.g. 4401). `NWProtocolWebSocket.CloseCode.applicationCode` carries
    /// 4400–4999 verbatim.
    public func sendClose(code: UInt16) {
        stateLock.lock()
        guard let connection = _connection else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let closeCode: NWProtocolWebSocket.CloseCode =
            code >= 4400 && code <= 4999
            ? .applicationCode(code)
            : .protocolCode(NWProtocolWebSocket.CloseCode.Defined(rawValue: code) ?? .normalClosure)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = closeCode
        let context = NWConnection.ContentContext(
            identifier: "close",
            metadata: [metadata]
        )
        connection.send(
            content: nil,
            contentContext: context,
            completion: .contentProcessed { _ in }
        )
    }

    private func accept(_ connection: NWConnection) {
        stateLock.lock()
        _connectionCount += 1
        let index = min(_connectionCount - 1, scripts.count - 1)
        let script = scripts[index]
        _connection = connection
        _inboundCount = 0
        stateLock.unlock()
        connection.start(queue: .global())
        // Push scripted open frames once the handshake has settled.
        for frame in script.onOpen {
            sendText(frame, on: connection)
        }
        runReceiveLoop(connection, script: script)
    }

    private func runReceiveLoop(_ connection: NWConnection, script: Script) {
        connection.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content, isComplete {
                let metadata = connection.metadata(definition: NWProtocolWebSocket.definition)
                if let metadata = metadata as? NWProtocolWebSocket.Metadata {
                    switch metadata.opcode {
                    case .text, .cont, .binary:
                        // NWProtocolWebSocket reports received text messages
                        // as .cont on some paths; decode any data-bearing frame.
                        if let string = String(data: content, encoding: .utf8) {
                            self.handleText(string, script: script)
                        }
                    case .close:
                        connection.cancel()
                        return
                    default:
                        break // ping/pong handled by autoReplyPing
                    }
                }
            }
            if error != nil {
                connection.cancel()
            } else {
                self.runReceiveLoop(connection, script: script)
            }
        }
    }

    private func handleText(_ string: String, script: Script) {
        stateLock.lock()
        _inboundCount += 1
        let count = _inboundCount
        stateLock.unlock()

        let replies = script.onText(string)
        stateLock.lock()
        let connection = _connection
        stateLock.unlock()
        for reply in replies {
            if let connection { sendText(reply, on: connection) }
        }
        if let cap = script.closeAfterInboundCount, count >= cap {
            sendClose(code: 1000)
        }
    }
    private func sendText(_ string: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "text",
            metadata: [metadata]
        )
        connection.send(
            content: string.data(using: .utf8),
            contentContext: context,
            completion: .contentProcessed { _ in }
        )
    }

    /// Deliver a server→client TEXT frame on the current connection. Accepts
    /// ANY string — including malformed/non-JSON-RPC junk — so tests can push
    /// malformed frames at the peer (P1-4 junk-liveness suite).
    public func sendText(_ string: String) {
        stateLock.lock()
        let connection = _connection
        stateLock.unlock()
        if let connection { sendText(string, on: connection) }
    }

    /// Deliver a server→client BINARY frame on the current connection. /api/ws
    /// is text-only, so binary frames are unsupported junk — used to prove a
    /// binary-flooding peer cannot keep the transport "connected" forever
    /// (P1-4).
    public func sendBinary(_ data: Data) {
        stateLock.lock()
        let connection = _connection
        stateLock.unlock()
        guard let connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: "binary",
            metadata: [metadata]
        )
        connection.send(
            content: data,
            contentContext: context,
            completion: .contentProcessed { _ in }
        )
    }
}
