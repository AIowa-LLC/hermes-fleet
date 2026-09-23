import Foundation
import FleetCore

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
                 NSURLErrorNotConnectedToInternet,
                 // -1011: the socket ended without a WebSocket close
                 // handshake (Apple surfaces this for an abruptly dropped
                 // WS / an upgrade response that was not a valid 101) — the
                 // abnormal-teardown family. NEVER read as the gateway's
                 // 1011 "server error" close code: the old `unknown` mapping
                 // formatted "-1011" into the failure detail, and the §13
                 // classifier's substring match then rendered "Degraded" for
                 // a transient loss (dogfood r2, 2026-09-23).
                 NSURLErrorBadServerResponse:
                return .abnormalClosure
            default:
                return .unknown(code: nsError.code, detail: nsError.localizedDescription)
            }
        }
        return .unknown(code: nsError.code, detail: nsError.localizedDescription)
    }
}
