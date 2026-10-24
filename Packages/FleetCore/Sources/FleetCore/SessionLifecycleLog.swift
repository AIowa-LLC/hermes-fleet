import Foundation
import os

/// Privacy-safe `os.Logger` events for the conversation session lifecycle
/// (open, send, reconnect).
///
/// Privacy rules (AGENTS.md rule 3):
/// - No identifiers are logged: no session IDs, gateway IDs, hostnames, row
///   IDs, or ticket values. Events carry only a closed-vocabulary failure kind
///   and numeric durations, so there is nothing to hash or redact.
/// - No content is logged: no prompt text, no assistant output, no error
///   messages. `FailureKind` is the only failure detail that leaves this type.
public enum SessionLifecycleLog {
    public static let logger = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "session-lifecycle")

    /// Closed vocabulary for why an open, send, or reconnect failed.
    public enum FailureKind: String, Sendable, Equatable, CaseIterable {
        case timeout
        case authRequired = "auth_required"
        case unreachable
        case notConnected = "not_connected"
        case sessionNotFound = "session_not_found"
        case sessionTooLong = "session_too_long"
        case rpc
        case malformed
        case other
    }

    /// Classify an error into `FailureKind` without reading its text.
    public static func failureKind(for error: any Error) -> FailureKind {
        if let connectivity = error as? GatewayConnectivityError {
            switch connectivity {
            case .timeout: return .timeout
            case .authenticationRequired: return .authRequired
            case .unreachable: return .unreachable
            default: return .other
            }
        }
        if let conversation = error as? ConversationError {
            switch conversation {
            case .notConnected: return .notConnected
            case .sessionNotFound: return .sessionNotFound
            case .sessionTooLongToReload: return .sessionTooLong
            case .rpcFailed: return .rpc
            case .malformedPayload: return .malformed
            default: return .other
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return .timeout
        }
        return .other
    }

    /// Milliseconds elapsed since `start`, clamped to be non-negative.
    public static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: ContinuousClock.now)
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        return max(0, Int(ms.rounded()))
    }

    // MARK: Open

    public static func openStarted() {
        logger.info("session open started")
    }

    public static func openSucceeded(durationMs: Int) {
        logger.info("session open succeeded duration_ms=\(durationMs, privacy: .public)")
    }

    public static func openFailed(_ kind: FailureKind, durationMs: Int) {
        logger.error("session open failed kind=\(kind.rawValue, privacy: .public) duration_ms=\(durationMs, privacy: .public)")
    }

    // MARK: Send

    public static func sendStarted() {
        logger.info("prompt send started")
    }

    /// The gateway accepted the prompt. `streaming` is false when the gateway
    /// accepted it without a stream (the turn settles immediately).
    public static func sendAcknowledged(streaming: Bool, durationMs: Int) {
        logger.info("prompt send acknowledged streaming=\(streaming, privacy: .public) duration_ms=\(durationMs, privacy: .public)")
    }

    public static func sendFailed(_ kind: FailureKind, durationMs: Int) {
        logger.error("prompt send failed kind=\(kind.rawValue, privacy: .public) duration_ms=\(durationMs, privacy: .public)")
    }

    // MARK: Reconnect

    public static func reconnectStarted() {
        logger.info("session reconnect started")
    }

    public static func reconnectFailed(_ kind: FailureKind) {
        logger.error("session reconnect failed kind=\(kind.rawValue, privacy: .public)")
    }
}
