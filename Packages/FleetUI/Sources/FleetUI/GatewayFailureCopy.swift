import SwiftUI
import FleetCore

/// F1: cause-differentiated connection-failure copy (apple-design D1 audit).
///
/// Every failure surface renders the SAME mapping from the classified
/// §13 status + non-secret detail to a one-line, sentence-case, actionable
/// sentence — what happened + what to do (HIG writing). The compact pill
/// label stays short ("Unreachable"); the CAUSE lives in this detail line,
/// never in the pill. No raw endpoint or secret is ever echoed — the endpoint
/// is already visible (redacted) in the row, so the copy says "the address".
public enum GatewayFailureCopy {

    /// The detail line for a failed gateway (status + non-secret transport
    /// detail from `GatewayConnectivityError.errorDescription`).
    public static func detail(status: GatewayStatus, detail: String?, gatewayName: String? = nil) -> String {
        let name = gatewayName.flatMap { $0.isEmpty ? nil : $0 } ?? "the gateway"
        switch status {
        case .online, .connecting:
            return "This gateway did not report its roster this refresh."
        case .degraded:
            return "The gateway answered but reported a server error. Retry, or check the gateway's health."
        case .authenticationRequired:
            // P0-9: a rejection the gateway EXPLAINED gets cause-specific
            // guidance. "no_cookie" from ws-ticket means the saved sign-in
            // method is a token, but this gateway only accepts username &
            // password — "re-authenticate" would loop the same failure.
            if let detail, detail.contains("no_cookie") {
                return "The gateway is reachable, but its saved sign-in method isn't accepted here. This gateway needs username & password sign-in — update it in the gateway's settings, not a token."
            }
            return "The gateway is reachable but needs you to sign in. Re-authenticate to continue."
        case .unsupported:
            if let detail, detail.contains("HTTP 404") {
                // F1 wrong-port case: TCP answered, app routes missing.
                return "The gateway answered, but this address isn't serving the app — it returned \"not found\". Check the endpoint and port."
            }
            return "The gateway answered but this address isn't a supported Hermes surface. Check the endpoint and port."
        case .offline:
            if let detail {
                if detail.contains("auth endpoint returned HTTP") {
                    // Late-classified auth-surface failure — same guidance.
                    return "The gateway answered, but this address isn't a supported Hermes surface. Check the endpoint and port."
                }
                if detail.contains("timed out") || detail.contains("timeout") {
                    return "Couldn't reach \(name) — the connection timed out. Check that the gateway is running and the address is right."
                }
            }
            return "Couldn't reach \(name) — the connection timed out. Check that the gateway is running and the address is right."
        }
    }
}
