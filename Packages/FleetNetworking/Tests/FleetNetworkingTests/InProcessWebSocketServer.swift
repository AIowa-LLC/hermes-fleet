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
    private let script: Script
    private let stateLock = NSLock()
    private var _connection: NWConnection?
    private var _inboundCount = 0

    public init(script: Script) throws {
        self.script = script
        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.setClientRequestHandler(DispatchQueue.global()) { _, _ in
            .init(status: .accept, subprotocol: nil, additionalHeaders: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        self.listener = try NWListener(using: parameters, on: .any)
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
        _connection = connection
        stateLock.unlock()
        connection.start(queue: .global())
        // Push scripted open frames once the handshake has settled.
        for frame in script.onOpen {
            sendText(frame, on: connection)
        }
        runReceiveLoop(connection)
    }

    private func runReceiveLoop(_ connection: NWConnection) {
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
                            self.handleText(string)
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
                self.runReceiveLoop(connection)
            }
        }
    }

    private func handleText(_ string: String) {
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
}
