import Foundation

/// R9-T1 — dangerous-command approval domain.
///
/// Wire shapes verified against hermes-agent 0.21.0:
/// - push event `approval.request` (tui_gateway/server.py:3102
///   `_emit_approval_request`); payload built by `_approval_request_payload`
///   (server.py:3036): `{request_id, command (already gateway-redacted,
///   #48456), description, choices, allow_session, allow_permanent}`.
///   `request_id` is a gateway-minted uuid4 hex (tools/approval.py:2826).
/// - `approval.respond` (methods_prompt.py:1881): params
///   `{session_id, choice, request_id?, all?}` where choice is one of
///   once|session|always|deny (`_ApprovalEntry.result`,
///   tools/approval.py:2828); result `{resolved: N}`.
/// - per-session YOLO bypass: `config.set key=yolo value=1|0 scope=session`
///   (server.py:14967-15035) — flips ONLY the session's `_session_yolo`
///   flag, never the global config; readback rides `session.info`
///   `{yolo, approval_mode}` (server.py:7758).
public struct ApprovalRequest: Identifiable, Hashable, Sendable {
    /// Gateway-minted unique id (`request_id` on the wire).
    public let requestID: String
    /// The session (runtime id) the approval blocks.
    public let sessionID: String
    /// The command preview. The gateway redacts credentials server-side
    /// (#48456); the client runs `Redaction.commandPreview` as a second,
    /// never-trusting pass before rendering.
    public let command: String
    /// Human explanation of the danger (`description`).
    public let detail: String?
    /// Offered choices in gateway order (`once|session|always|deny`).
    public let choices: [String]

    public init(
        requestID: String,
        sessionID: String,
        command: String,
        detail: String? = nil,
        choices: [String] = []
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.command = command
        self.detail = detail
        self.choices = choices
    }

    /// Identifiable rides the gateway-minted request id (stable across
    /// reconnects — the pending queue stays authoritative server-side).
    public var id: String { requestID }
}

/// The approval choices the gateway understands (`resolve_gateway_approval`,
/// tools/approval.py:2865 — the agent thread unblocks with one of these).
public enum ApprovalChoice: String, Sendable, Hashable {
    /// Run the command this one time.
    case once
    /// Run it and auto-approve the same pattern for the rest of the session.
    case session
    /// Run it and persist the pattern allowlist entry.
    case always
    /// Block it. Always friction-free in the UI (R9 security posture).
    case deny
}

/// R9-T1 seam: approve/deny pending dangerous-command approvals + flip the
/// PER-SESSION YOLO bypass. Lives in FleetCore so FleetUI never imports
/// FleetNetworking (M0 guard); the concrete `GatewayApprovalClient` is
/// injected at the composition root.
///
/// Fail-closed by design: an implementation that cannot reach the gateway
/// THROWS — a failed approve must never look like success (the agent would
/// run a dangerous command the user never actually approved).
public protocol ApprovalsProviding: Sendable {
    /// Respond to one pending approval via `approval.respond`.
    /// - Returns: the number of approvals the gateway resolved (0 when the
    ///   request already timed out or was resolved elsewhere).
    func respond(
        sessionID: String,
        requestID: String,
        choice: ApprovalChoice,
        all: Bool
    ) async throws -> Int

    /// Flip this session's YOLO bypass via `config.set yolo scope=session`.
    /// NEVER touches the global `approvals.mode` — per-session only, the
    /// same contract as the desktop's Shift+Tab (server.py:14967).
    /// - Returns: the resulting enabled state.
    func setSessionYolo(_ enabled: Bool, sessionID: String) async throws -> Bool

    /// `approval.pending` (methods_prompt.py:1804) — the replay-safe list
    /// of unresolved approvals for a session. Called on open/reconnect to
    /// restore a banner whose push event was missed while detached; the
    /// server-side queue stays authoritative (this is a read, not a claim).
    /// - Returns: the session's unresolved approvals (empty when none).
    func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest]
}

/// Sessions whose concrete type carries an approvals seam (R9-T1).
/// `GatewayConversationSession` conforms in FleetNetworking; the UI layer
/// resolves the seam with ONE cast at build time (`session as?
/// ApprovalsCapable`) — deliberately NOT a same-named extension property on
/// `ConversationSessionProviding`: an extension member named identically to
/// the sub-protocol requirement recurses through swift_dynamicCast and
/// overflows the stack (verified crash: ConversationSessionProviding
/// .approvals.getter → swift_dynamicCast → getter, SIGSEGV stack guard).
public protocol ApprovalsCapable: ConversationSessionProviding {
    /// Approve/deny + per-session YOLO over the session's transport.
    var approvals: any ApprovalsProviding { get }
}

/// Fail-closed default: gateways without approvals support (older than the
/// approval-event gateway, or unconfigured sessions) throw instead of
/// silently pretending the user answered.
public struct UnsupportedApprovals: ApprovalsProviding {
    public init() {}

    public func respond(
        sessionID: String, requestID: String, choice: ApprovalChoice, all: Bool
    ) async throws -> Int {
        throw ConversationError.notConnected
    }

    public func setSessionYolo(_ enabled: Bool, sessionID: String) async throws -> Bool {
        throw ConversationError.notConnected
    }

    public func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] {
        throw ConversationError.notConnected
    }
}
