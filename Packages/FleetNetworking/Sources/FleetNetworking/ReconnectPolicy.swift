import Foundation

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
/// without a live gateway.
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
