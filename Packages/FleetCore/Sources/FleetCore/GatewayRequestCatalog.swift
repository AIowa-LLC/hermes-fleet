import Foundation

/// Catalog of gateway JSON-RPC methods that the app needs to reason about when a
/// request does not come back: which ones are safe to repeat, and what to call
/// them to the user when they time out.
///
/// Lives in FleetCore so the transport (FleetNetworking) can read the retry
/// allowlist and the UI-facing copy stays out of networking code.
public enum GatewayRequestCatalog {
    /// Pure, idempotent reads. ONLY these methods are retried automatically
    /// after a request timeout. Every other method (sends, approvals, config
    /// writes, session creation/resume, interrupts) is attempted exactly once
    /// and its timeout is surfaced to the user, because a repeated write could
    /// apply twice.
    public static let idempotentReads: Set<String> = [
        "session.list",
        "session.active_list",
        "session.history",
        "session.status",
        "session.events.since",
        "profiles.list",
        "profiles.describe",
        "profiles.get_asset",
        "config.get",
        "approval.pending",
        "delegation.status",
        "subagent.list",
        "subagent.tail",
        "projects.tree",
        "complete.path",
        "groups.list",
        "groups.state",
        "groups.log",
        "groups.capabilities",
    ]

    /// Whether a method may be retried after a timeout.
    public static func isIdempotentRead(_ method: String) -> Bool {
        idempotentReads.contains(method)
    }

    /// Human label for the operation a gateway method performs, or nil for a
    /// method without a dedicated label.
    public static func operationLabel(forMethod method: String) -> String? {
        switch method {
        case "session.history": return "Loading messages"
        case "session.status": return "Checking session status"
        case "session.list": return "Loading sessions"
        case "session.active_list": return "Loading active sessions"
        case "session.events.since": return "Catching up on new messages"
        case "session.resume": return "Opening the conversation"
        case "session.create": return "Starting a conversation"
        case "session.interrupt": return "Stopping the conversation"
        case "prompt.submit": return "Sending your message"
        case "approval.respond": return "Sending your approval"
        case "approval.pending": return "Loading approvals"
        case "config.get": return "Loading settings"
        case "config.set": return "Saving settings"
        case "profiles.list": return "Loading profiles"
        case "projects.tree": return "Loading projects"
        case "cron.manage": return "Updating scheduled jobs"
        default: return nil
        }
    }

    /// The user-facing sentence for a timed-out gateway request.
    ///
    /// Reads say what was loading and that a retry is worth trying. Writes
    /// say the change may or may not have applied, so the user checks before
    /// tapping Retry (a blind retry of a send could post the message twice).
    public static func timeoutMessage(forMethod method: String) -> String {
        guard let label = operationLabel(forMethod: method) else {
            return "The gateway didn't respond in time. Check your connection and tap Retry."
        }
        if isIdempotentRead(method) {
            return "\(label) timed out. Check your connection and tap Retry."
        }
        return "\(label) timed out before the gateway confirmed it. Check the conversation or settings before trying again."
    }
}
