import Foundation

/// User-facing connection state of a gateway (spec §13).
///
/// Maps the transport seam's `TransportState` onto the fleet vocabulary the
/// UI renders: Online / Connecting / Degraded / Authentication Required /
/// Offline / Unsupported. The transport layer stays behind `HermesTransport`;
/// this type is pure domain so FleetUI can render reachability without
/// importing the transport module (M0 guard).
public enum GatewayStatus: String, Hashable, Sendable, Codable, CaseIterable {
    /// Fully connected and serving (`gateway.ready` adopted, requests work).
    case online
    /// Socket handshake in progress.
    case connecting
    /// Reachable but unhealthy (server error / TLS failure).
    case degraded
    /// Close 4401 — the credential/ticket was rejected; re-authenticate.
    case authenticationRequired
    /// Cleanly disconnected, or the endpoint never answered.
    case offline
    /// Endpoint answered but is not a usable chat gateway surface
    /// (4400 / 4403 / 4404 / 4408).
    case unsupported

    /// Whether the gateway is currently reachable and can serve requests.
    /// Online and degraded both mean the endpoint is up; everything else is
    /// unreachable or unusable (spec §13 / §31 "reachable/unreachable").
    public var isReachable: Bool {
        self == .online || self == .degraded
    }

    /// Map a transport seam's observable state onto the user-facing status.
    public init(transportState: TransportState) {
        switch transportState {
        case .connected: self = .online
        case .connecting: self = .connecting
        case .disconnected: self = .offline
        case .failed(let detail): self = Self.classify(failureDetail: detail)
        }
    }

    /// Map a `GatewayConnectivityError` (the M3 UI-facing vocabulary) onto the
    /// §13 status. A failed probe is a classification, never a thrown error —
    /// reachable/unreachable is the spec §31 acceptance.
    public init(connectivityError: GatewayConnectivityError) {
        switch connectivityError {
        case .authenticationRequired:
            self = .authenticationRequired
        case .authStrategyRejected:
            // P0-9: the gateway rejected the STRATEGY (401 "no_cookie" — a
            // token mint against a cookie-only gateway). Still an auth
            // problem the user must fix (sign in with username & password);
            // the cause-specific guidance lives in the failure copy.
            self = .authenticationRequired
        case .authSurfaceHTTP(let code) where code == 401 || code == 403:
            self = .authenticationRequired
        case .authSurfaceHTTP:
            // The endpoint ANSWERED — it is reachable — but it is not the
            // gateway API surface (wrong port; the F1 8642-vs-9119 case).
            self = .unsupported
        case .unsupported:
            self = .unsupported
        case .unreachable, .timeout:
            self = .offline
        case .connectionFailed(let detail), .invalidState(let detail):
            self = Self.classify(failureDetail: detail)
        }
    }

    /// Classify a `TransportState.failed` detail string (produced from
    /// `DisconnectReason.debugDescription` by the transport layer).
    ///
    /// Falls closed: anything unrecognized is treated as `.offline`.
    public static func classify(failureDetail: String) -> GatewayStatus {
        let d = failureDetail.lowercased()
        if d.contains("reauthentication") || d.contains("4401") {
            return .authenticationRequired
        }
        if d.contains("invalid channel") || d.contains("host mismatch")
            || d.contains("chat disabled") || d.contains("peer not allowed")
            || d.contains("4400") || d.contains("4403")
            || d.contains("4404") || d.contains("4408") {
            return .unsupported
        }
        if d.contains("server error") || d.contains("1011") || d.contains("tls") {
            return .degraded
        }
        // normal/going-away/abnormal/unknown → offline (endpoint not serving).
        return .offline
    }
}
