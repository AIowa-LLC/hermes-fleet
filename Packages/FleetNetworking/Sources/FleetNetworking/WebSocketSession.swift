import Foundation
import os

/// A message received from / sent to the gateway socket.
public enum WebSocketMessage: Sendable, Hashable, Equatable {
    case text(String)
    case data(Data)
}

/// The transport's seam over a WebSocket connection. The concrete
/// implementation wraps `URLSessionWebSocketTask`; tests inject fakes or point
/// the real one at an in-process fixture server.
public protocol WebSocketSession: Sendable {
    /// Establish the connection (resume the task).
    func open() async throws
    /// Receive the next message. Throws when the socket closes or errors;
    /// the resulting `closeCode` (if any) is available via `lastCloseCode`.
    func receive() async throws -> WebSocketMessage
    /// Send a text or data message.
    func send(_ message: WebSocketMessage) async throws
    /// Close the connection with a close code + optional reason.
    func close(code: Int, reason: String?) async
    /// The raw close code observed from the peer (nil until the socket closed).
    var lastCloseCode: Int? { get }
}

/// Factory producing sessions, so the transport can be built with the real
/// `URLSessionWebSocketTask` implementation or a test double.
public protocol WebSocketSessionFactory: Sendable {
    func makeSession(url: URL) -> any WebSocketSession
}

/// Concrete `URLSessionWebSocketTask`-backed session.
///
/// URLSession retains its delegate, so this session owns a dedicated
/// `URLSession` configured with a small delegate object (retained by us) that
/// forwards the server's close code through a closure. We also retain the
/// delegate, breaking the only would-be cycle (delegate → nothing).
public final class URLSessionWebSocketSession: WebSocketSession, @unchecked Sendable {
    private final class CloseDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        var onClose: (@Sendable (Int, Data?) -> Void)?

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            onClose?(closeCode.rawValue, reason)
        }
    }

    private let urlSession: URLSession
    private let task: URLSessionWebSocketTask
    private let delegate: CloseDelegate
    private let lock = OSAllocatedUnfairLock<Int?>(initialState: nil)

    public init(url: URL, configuration: URLSessionConfiguration = .ephemeral) {
        let delegate = CloseDelegate()
        self.delegate = delegate
        self.urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.task = urlSession.webSocketTask(with: url)
        delegate.onClose = { [weak self] code, _ in
            self?.lock.withLock { $0 = code }
        }
    }

    public var lastCloseCode: Int? {
        lock.withLock { $0 }
    }

    public func open() async throws {
        task.resume()
    }

    public func receive() async throws -> WebSocketMessage {
        do {
            let message = try await task.receive()
            switch message {
            case .string(let s): return .text(s)
            case .data(let d): return .data(d)
            @unknown default: return .data(Data())
            }
        } catch {
            // On close URLSession reports a generic URLError; the close code
            // is captured by the delegate. Re-throw so the transport can
            // classify via lastCloseCode.
            throw error
        }
    }

    public func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .text(let s): try await task.send(.string(s))
        case .data(let d): try await task.send(.data(d))
        }
    }

    public func close(code: Int, reason: String?) async {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: closeCode, reason: reason?.data(using: .utf8))
        lock.withLock { $0 = code }
    }
}

/// Factory producing `URLSessionWebSocketTask` sessions. The default creates
/// the session from an ephemeral URLSession with a delegate, so close codes
/// are observable; callers may supply their own `URLSessionConfiguration`.
public struct URLSessionWebSocketSessionFactory: WebSocketSessionFactory {
    public let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func makeSession(url: URL) -> any WebSocketSession {
        URLSessionWebSocketSession(url: url, configuration: configuration)
    }
}
