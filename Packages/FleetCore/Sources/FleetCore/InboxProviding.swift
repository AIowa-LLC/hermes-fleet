import Foundation

// Phase B — the seams the approvals inbox is built on.
//
// FleetUI depends on `InboxProviding` (below) and FleetCore types only. The
// concrete per-gateway feed (`InboxGatewayFeed`) is implemented in
// FleetNetworking over the gateway transport, and wired at the composition
// root. History persistence (`InboxHistoryStoring`) is implemented in
// FleetPersistence. The aggregating `InboxStore` lives in FleetUI.

// MARK: - Feed events

/// One inbox-relevant event from one gateway, in arrival order. All sessions
/// of that gateway are included; the feed never filters by the visible
/// conversation.
public enum InboxFeedEvent: Equatable, Sendable {
    /// A server→client request (`approval`, `clarify`, `sudo`, `secret`),
    /// live or re-delivered by `open_requests`.
    case serverRequest(ServerRequest)
    /// The legacy `approval.request` event (gateways without server requests).
    case legacyApproval(ApprovalRequest)
    /// `request.cancel {id}`: the gateway withdrew the request with this wire id.
    case withdrawn(wireRequestID: String)

    /// Map a conversation event onto the inbox vocabulary. Nil for events the
    /// inbox does not track.
    public init?(conversationEvent event: ConversationEvent) {
        switch event {
        case .serverRequest(let request):
            self = .serverRequest(request)
        case .approvalRequested(let sessionID, let requestID, let command, let detail, let choices, _):
            self = .legacyApproval(ApprovalRequest(
                requestID: requestID,
                sessionID: sessionID,
                command: command,
                detail: detail,
                choices: choices))
        case .requestCancelled(_, let requestID, _, _, _):
            self = .withdrawn(wireRequestID: requestID)
        default:
            return nil
        }
    }
}

extension InboxItem {
    /// Build the pending item for a server request. Identity comes from the
    /// gateway, session, and gateway request id, never from display text.
    /// The secret VALUE is never read here (`SecretPrompt` has no value).
    public static func make(
        from request: ServerRequest,
        agent: InboxAgentIdentity,
        at now: Date
    ) -> InboxItem {
        switch request.kind {
        case .approval(let approval):
            return InboxItem(
                id: InboxItemID(gatewayID: agent.gatewayID, sessionID: approval.sessionID, requestID: approval.requestID),
                kind: .approval,
                requestID: approval.requestID,
                agent: agent,
                context: InboxContext(command: approval.command, detail: approval.detail, choices: approval.choices),
                serverRequestID: request.id,
                createdAt: now)

        case .clarify(let prompt):
            let first = prompt.questions.first
            let text = prompt.questions.map(\.question).joined(separator: "\n")
            return InboxItem(
                id: InboxItemID(gatewayID: agent.gatewayID, sessionID: request.sessionID, requestID: request.id),
                kind: .question,
                requestID: request.id,
                agent: agent,
                context: InboxContext(
                    detail: text,
                    choices: prompt.isBatch ? [] : (first?.choices ?? []),
                    isBatchQuestion: prompt.isBatch),
                serverRequestID: request.id,
                createdAt: now)

        case .sudo(let prompt):
            return InboxItem(
                id: InboxItemID(gatewayID: agent.gatewayID, sessionID: request.sessionID, requestID: request.id),
                kind: .sudo,
                requestID: request.id,
                agent: agent,
                context: InboxContext(command: prompt.command),
                serverRequestID: request.id,
                createdAt: now)

        case .secret(let prompt):
            return InboxItem(
                id: InboxItemID(gatewayID: agent.gatewayID, sessionID: request.sessionID, requestID: request.id),
                kind: .secret,
                requestID: request.id,
                agent: agent,
                context: InboxContext(detail: prompt.prompt, envVarName: prompt.envVar),
                serverRequestID: request.id,
                createdAt: now)
        }
    }
}

// MARK: - Per-gateway feed

/// One connected gateway's inbox feed. Implemented in FleetNetworking over the
/// gateway transport; FleetCore and FleetUI see only this seam.
public protocol InboxGatewayFeed: Sendable {
    var gatewayID: GatewayID { get }

    /// Open the feed's connection. Idempotent.
    func start() async throws

    /// A fresh stream of every inbox-relevant event for this gateway (all
    /// sessions, live and replayed), in order. Each call returns a new stream.
    func events() -> AsyncStream<InboxFeedEvent>

    /// Answers approvals. The concrete client routes each answer over the
    /// transport that delivered it.
    var approvals: any ApprovalsProviding { get }
    /// Answers clarify / sudo / secret requests.
    var prompts: any ServerPromptResponding { get }

    /// `approval.pending` for one session: the replay-safe list of unresolved
    /// approvals. Used to reconcile on connect, foreground, and relaunch.
    func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest]
}

// MARK: - Persistence seam

/// Persists the inbox's last-known items and audit trail. Implementations
/// must be fail-soft on load (a corrupt file yields `.empty`, never a crash)
/// and must never store secret values.
public protocol InboxHistoryStoring: Sendable {
    func load() async -> InboxPersistedState
    func save(_ state: InboxPersistedState) async throws
}

/// In-memory history store for tests and previews.
public actor InMemoryInboxHistoryStore: InboxHistoryStoring {
    private var state: InboxPersistedState

    public init(state: InboxPersistedState = .empty) {
        self.state = state
    }

    public func load() async -> InboxPersistedState { state }

    public func save(_ state: InboxPersistedState) async throws {
        self.state = state
    }
}

// MARK: - Consumer seam

/// What the Inbox UI and notifications build against. Main-actor isolated
/// because the UI reads it directly. `updates()` gives a snapshot stream for
/// consumers that are not SwiftUI-observed.
@MainActor
public protocol InboxProviding: AnyObject {
    /// Every item: pending first (oldest first), then history.
    var items: [InboxItem] { get }
    /// Audit trail, newest first.
    var auditTrail: [InboxDecisionRecord] { get }

    /// Snapshot stream. Emits the current items immediately, then on change.
    func updates() -> AsyncStream<[InboxItem]>

    /// Decide one pending item. Approve is presence-gated and review-gated;
    /// deny and skip are not. Returns the audit record for the attempt. A
    /// gateway failure throws and leaves the item pending (retryable).
    func decide(_ itemID: InboxItemID, _ decision: InboxDecision) async throws -> InboxDecisionRecord

    /// The user reviewed a long command in full. Required before approve.
    func markReviewed(_ itemID: InboxItemID)

    /// Reconcile every attached gateway against `approval.pending`.
    func refresh() async
}
