import Foundation
import Network
import Security

/// T3 — in-process TLS WebSocket server fixture: the same scripted gateway
/// as `InProcessWebSocketServer`, but over TLS presenting a configurable
/// self-signed identity (gateway vs. MITM), so the REAL URLSession
/// challenge path (serverTrust → PinningTrustHandler) is exercised
/// end-to-end without a live Hermes node.
public final class InProcessTLSServer: @unchecked Sendable {
    private let listener: NWListener
    private let scripts: [InProcessWebSocketServer.Script]
    private let stateLock = NSLock()
    private var _connection: NWConnection?
    private var _inboundCount = 0
    private var _connectionCount = 0

    /// - Parameters:
    ///   - scripts: one script per accepted connection (index clamped).
    ///   - identity: the SecIdentity this server presents.
    public init(
        scripts: [InProcessWebSocketServer.Script],
        identity: SecIdentity
    ) throws {
        self.scripts = scripts.isEmpty ? [InProcessWebSocketServer.Script()] : scripts

        // TLS via the standard route: NWParameters(tls:) wraps TCP in TLS,
        // then WebSocket rides on top as the application protocol.
        let tlsOptions = NWProtocolTLS.Options()
        guard let secId = sec_identity_create(identity) else {
            throw NSError(domain: "InProcessTLSServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "sec_identity_create failed"])
        }
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secId)

        let parameters = NWParameters(tls: tlsOptions)
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.setClientRequestHandler(DispatchQueue.global()) { _, _ in
            .init(status: .accept, subprotocol: nil, additionalHeaders: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        self.listener = try NWListener(using: parameters, on: .any)
    }

    public var connectionCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _connectionCount
    }

    public var listeningPort: UInt16 {
        stateLock.lock(); defer { stateLock.unlock() }
        return listener.port?.rawValue ?? 0
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume()
                case .failed(let error): cont.resume(throwing: error)
                default: break
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

    private func accept(_ connection: NWConnection) {
        stateLock.lock()
        _connectionCount += 1
        let index = min(_connectionCount - 1, scripts.count - 1)
        let script = scripts[index]
        _connection = connection
        stateLock.unlock()
        connection.start(queue: .global())
        for frame in script.onOpen {
            sendText(frame, on: connection)
        }
        runReceiveLoop(connection, script: script)
    }

    private func runReceiveLoop(_ connection: NWConnection, script: InProcessWebSocketServer.Script) {
        connection.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content, isComplete {
                let metadata = connection.metadata(definition: NWProtocolWebSocket.definition)
                if let metadata = metadata as? NWProtocolWebSocket.Metadata {
                    switch metadata.opcode {
                    case .text, .cont, .binary:
                        if let string = String(data: content, encoding: .utf8) {
                            self.handleText(string, script: script)
                        }
                    case .close:
                        connection.cancel()
                        return
                    default:
                        break
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

    private func handleText(_ string: String, script: InProcessWebSocketServer.Script) {
        stateLock.lock()
        _inboundCount += 1
        let count = _inboundCount
        let connection = _connection
        stateLock.unlock()
        let replies = script.onText(string)
        for reply in replies {
            if let connection { sendText(reply, on: connection) }
        }
        if let cap = script.closeAfterInboundCount, count >= cap {
            sendCloseFrame(connection)
        }
    }

    private func sendCloseFrame(_ connection: NWConnection?) {
        guard let connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, completion: .contentProcessed { _ in })
    }

    private func sendText(_ string: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(
            content: string.data(using: .utf8),
            contentContext: context,
            completion: .contentProcessed { _ in }
        )
    }
}
