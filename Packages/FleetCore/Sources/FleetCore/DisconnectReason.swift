import Foundation

/// Typed reasons a gateway WebSocket connection ends, derived from the raw
/// close-code/error. Verified close-code table in `hermes_cli/web_server.py`
/// (4400/4401/4403/4404/4408/1011) and RFC 6455 standard codes.
///
/// Lives in FleetCore (moved from FleetNetworking, dogfood r2): the reconnect
/// decision is part of the §13/§8.6 domain vocabulary that the runtime
/// (FleetUI) applies — FleetUI must never import the transport module (M0
/// hard guard), exactly like `TransportState` / `GatewayStatus`.
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

/// What the reconnect policy says to do after a disconnect, derived from the
/// classified close reason (spec §8.6 "Reconnect: close-code handling;
/// 4401 → re-mint ticket, never silent retry; other codes → reconnect +
/// replay").
public enum ReconnectDecision: Sendable, Hashable, Equatable {
    /// Transient/expected drop (abnormal close, going-away, server error, TLS)
    /// — reconnect + replay.
    case reconnect
    /// 4401 — bad credential: re-mint a ticket / re-auth. NEVER a silent
    /// retry with the same credential (spec §8.6).
    case reauthenticate
    /// Clean/user-requested close or a terminal unsupported surface
    /// (4400/4403/4404/4408) — do not auto-reconnect.
    case doNotReconnect
}

/// Pure mapping from a classified `DisconnectReason` to a reconnect decision.
/// Kept as a static function so the reconnect suite can test every close code
/// without a live gateway; the runtime's bounded auto-recovery applies it
/// after every observed failure (dogfood r2).
public enum ReconnectPolicy {
    public static func decision(for reason: DisconnectReason) -> ReconnectDecision {
        switch reason {
        case .reauthenticationRequired:
            // 4401 — the one case that must NEVER silently retry.
            return .reauthenticate
        case .normalClosure:
            // Clean close (client requested or server normal) — no reconnect.
            return .doNotReconnect
        case .invalidChannel, .hostMismatch, .chatDisabled, .peerNotAllowed:
            // Endpoint answered but is not a usable surface — permanent.
            return .doNotReconnect
        case .tlsPinMismatch:
            // T3: possible MITM / replaced certificate — NEVER auto-retry.
            // The user must explicitly re-trust the new pin (warn-on-change
            // flow); hammering the endpoint would only mask the attack.
            return .doNotReconnect
        case .goingAway, .abnormalClosure, .serverError, .tlsHandshakeFailure,
             .unknown:
            // Transient — reconnect + replay.
            return .reconnect
        }
    }
}