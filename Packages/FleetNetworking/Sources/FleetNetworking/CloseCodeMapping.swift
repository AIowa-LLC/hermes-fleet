import Foundation

/// Typed reasons a gateway WebSocket connection ends, derived from the raw
/// close-code/error. Verified close-code table in `hermes_cli/web_server.py`
/// (4400/4401/4403/4404/4408/1011) and RFC 6455 standard codes.
public enum DisconnectReason: Sendable, Hashable, Equatable {
    /// Connection closed normally (1000) or by client request.
    case normalClosure
    /// Server going away / transport teardown (1001).
    case goingAway
    /// Connection lost without a clean close (1006).
    case abnormalClosure
    /// Server closed due to an internal error (1011).
    case serverError
    /// TLS handshake failure (1015).
    case tlsHandshakeFailure
    /// T3: the presented certificate's SPKI differs from the TOFU pin —
    /// possible MITM / replaced certificate. REJECTED by policy; the user
    /// must explicitly re-trust (never auto-reconnect).
    case tlsPinMismatch

    /// 4400 — invalid/absent `?channel=` (event/subscription surfaces).
    case invalidChannel
    /// 4401 — bad credential (invalid ticket / token mismatch / internal
    /// invalid). Maps to "re-mint a ticket / re-auth", never a silent retry.
    case reauthenticationRequired
    /// 4403 — host/origin mismatch or chat disabled gate.
    case hostMismatch
    /// 4404 — embedded chat disabled.
    case chatDisabled
    /// 4408 — peer (client IP) not allowed.
    case peerNotAllowed

    /// A close-code/error we do not have a typed classification for.
    case unknown(code: Int, detail: String)

    public var isAuthFailure: Bool {
        self == .reauthenticationRequired
    }

    public var debugDescription: String {
        switch self {
        case .normalClosure: return "normal closure"
        case .goingAway: return "going away"
        case .abnormalClosure: return "abnormal closure"
        case .serverError: return "server error (1011)"
        case .tlsHandshakeFailure: return "TLS handshake failure"
        case .tlsPinMismatch: return "gateway certificate changed (possible interception) — connection blocked"
        case .invalidChannel: return "invalid channel (4400)"
        case .reauthenticationRequired: return "reauthentication required (4401)"
        case .hostMismatch: return "host mismatch (4403)"
        case .chatDisabled: return "chat disabled (4404)"
        case .peerNotAllowed: return "peer not allowed (4408)"
        case .unknown(let code, let detail): return "unknown close \(code): \(detail)"
        }
    }
}

/// Maps raw WebSocket close codes and transport errors onto the typed
/// `DisconnectReason` vocabulary.
public enum CloseCodeMapping {
    /// Map a raw close code (RFC 6455 + gateway application codes).
    public static func reason(forRawCode rawCode: Int) -> DisconnectReason {
        switch rawCode {
        case 1000: return .normalClosure
        case 1001: return .goingAway
        case 1006: return .abnormalClosure
        case 1011: return .serverError
        case 1015: return .tlsHandshakeFailure
        case 4400: return .invalidChannel
        case 4401: return .reauthenticationRequired
        case 4403: return .hostMismatch
        case 4404: return .chatDisabled
        case 4408: return .peerNotAllowed
        default: return .unknown(code: rawCode, detail: "unclassified close code")
        }
    }

    /// Map a `URLSessionWebSocketTask.CloseCode` (standard codes only;
    /// non-standard 44xx arrive as `.invalid` on this SDK).
    public static func reason(forCloseCode code: URLSessionWebSocketTask.CloseCode) -> DisconnectReason {
        reason(forRawCode: code.rawValue)
    }

    /// Map a transport/URLError into a disconnect reason when no close frame
    /// was observed (e.g. abnormal teardown).
    public static func reason(for error: any Error) -> DisconnectReason {
        // T3: the typed pin-rejection error from the trust handler — the
        // presented key differs from the TOFU pin.
        if let pinError = error as? TLSPinRejectedError {
            return .tlsPinMismatch
        }
        let nsError = error as NSError
        // POSIX ENOTCONN (57): socket dropped without a close frame — the
        // network-switch / abnormal-loss signal. Classify as abnormal closure
        // rather than an opaque unknown.
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 {
            return .abnormalClosure
        }
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired:
                return .tlsHandshakeFailure
            case NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNotConnectedToInternet:
                return .abnormalClosure
            default:
                return .unknown(code: nsError.code, detail: nsError.localizedDescription)
            }
        }
        return .unknown(code: nsError.code, detail: nsError.localizedDescription)
    }
}
