import Foundation

/// Pure state machine behind the approvals inbox. No I/O, no actors, no
/// clocks: every transition takes its time as a parameter so the rules are
/// unit-testable and deterministic.
///
/// Transition rules:
/// - `ingest` never resurrects a terminal item. A re-delivery of a pending
///   item refreshes it in place (createdAt is kept, so FIFO order holds).
/// - Only a `pending` item can move to a terminal status. `resolve`,
///   `cancel`, `reconcile`, `expireDue`, and `removeGateway` all respect this,
///   so a late event can never change an already-answered item.
/// - A withdrawal (`request.cancel`) is `cancelled`, never `denied`.
/// - Caps: at most `maxTerminalItems` history items and `maxPendingItems`
///   pending items. Overflow never grows memory: terminal history is pruned
///   oldest-first, and overflowing pending items are expired visibly.
public struct InboxLedger: Equatable, Sendable {
    /// Terminal (history) items kept in memory and in the persisted snapshot.
    public static let maxTerminalItems = 200
    /// Pending items held at once across every gateway. A pending overflow
    /// expires the oldest pending item rather than dropping it silently.
    public static let maxPendingItems = 200
    /// Audit trail caps (applied by `retainedAudit`).
    public static let maxAuditRecords = 500
    public static let auditRetention: TimeInterval = 30 * 24 * 60 * 60

    public enum IngestResult: Equatable, Sendable {
        case inserted
        case refreshed
        /// The item is already terminal; the re-delivery was ignored.
        case ignoredTerminal
    }

    public private(set) var items: [InboxItemID: InboxItem]

    public init(items: [InboxItem] = []) {
        var map: [InboxItemID: InboxItem] = [:]
        for item in items { map[item.id] = item }
        self.items = map
        enforceCaps(at: Date.distantPast, reason: "inbox full")
    }

    /// Merge restored (persisted) items into this ledger. An item already present
    /// is left as it is: live state recorded before a restore completes always wins.
    public mutating func restore(_ restored: [InboxItem]) {
        for item in restored where items[item.id] == nil {
            items[item.id] = item
        }
        enforceCaps(at: Date.distantPast, reason: "inbox full")
    }

    // MARK: Queries

    public func item(_ id: InboxItemID) -> InboxItem? { items[id] }

    /// Pending items, oldest first (the gateway resolves approvals FIFO).
    public var pending: [InboxItem] {
        items.values
            .filter { $0.status == .pending }
            .sorted { ($0.createdAt, $0.id.rawValue) < ($1.createdAt, $1.id.rawValue) }
    }

    /// Every item for display: pending first (oldest first), then history
    /// (most recently updated first).
    public var ordered: [InboxItem] {
        let history = items.values
            .filter { $0.status.isTerminal }
            .sorted { ($0.updatedAt, $0.id.rawValue) > ($1.updatedAt, $1.id.rawValue) }
        return pending + history
    }

    public var pendingCount: Int { items.values.lazy.filter { $0.status == .pending }.count }

    // MARK: Transitions

    /// Insert a new pending item, or refresh an existing pending one in place.
    /// The incoming item must be pending.
    @discardableResult
    public mutating func ingest(_ incoming: InboxItem) -> IngestResult {
        guard incoming.status == .pending else { return .ignoredTerminal }
        if var existing = items[incoming.id] {
            guard existing.status == .pending else { return .ignoredTerminal }
            // Re-delivery: keep the first createdAt (FIFO) and refresh the rest.
            existing = InboxItem(
                id: existing.id,
                kind: incoming.kind,
                requestID: incoming.requestID,
                status: .pending,
                agent: incoming.agent,
                context: incoming.context,
                serverRequestID: incoming.serverRequestID ?? existing.serverRequestID,
                createdAt: existing.createdAt,
                updatedAt: max(existing.updatedAt, incoming.updatedAt),
                expiresAt: incoming.expiresAt ?? existing.expiresAt,
                failureMessage: nil
            )
            items[existing.id] = existing
            return .refreshed
        }
        items[incoming.id] = incoming
        enforceCaps(at: incoming.updatedAt, reason: "inbox full")
        return .inserted
    }

    /// Match a withdrawal only within its originating gateway and, when
    /// supplied, session. An ambiguous session-less wire id changes nothing.
    @discardableResult
    public mutating func cancel(
        gatewayID: GatewayID,
        sessionID: String?,
        wireRequestID: String,
        at now: Date
    ) -> InboxItemID? {
        let matches = pending.filter {
            $0.agent.gatewayID == gatewayID &&
            (sessionID == nil || $0.agent.sessionID == sessionID) &&
            ($0.serverRequestID == wireRequestID || $0.requestID == wireRequestID)
        }
        guard matches.count == 1, let id = matches.first?.id else { return nil }
        setTerminal(id, status: .cancelled, at: now, failure: nil)
        return id
    }

    /// Move a pending item to a terminal status. Returns false (no change)
    /// when the item is missing or already terminal.
    @discardableResult
    public mutating func resolve(
        _ id: InboxItemID,
        as status: InboxStatus,
        at now: Date,
        failure: String? = nil
    ) -> Bool {
        guard let item = items[id], item.status == .pending, status.isTerminal else { return false }
        setTerminal(id, status: status, at: now, failure: failure)
        return true
    }

    /// Record a non-terminal failure (for example a transport error on a
    /// retryable decision). The item stays pending.
    public mutating func recordFailure(_ id: InboxItemID, message: String, at now: Date) {
        guard var item = items[id], item.status == .pending else { return }
        item.failureMessage = message
        item.updatedAt = now
        items[id] = item
    }

    /// Reconcile one session against the gateway's `approval.pending` answer.
    /// Pending items for that gateway and session whose request id is NOT in
    /// `livePendingRequestIDs` are no longer pending on the gateway, so they
    /// expire. Returns the expired ids.
    @discardableResult
    public mutating func reconcile(
        gatewayID: GatewayID,
        sessionID: String,
        livePendingRequestIDs: Set<String>,
        at now: Date
    ) -> [InboxItemID] {
        let stale = pending
            .filter { $0.agent.gatewayID == gatewayID && $0.agent.sessionID == sessionID }
            .filter { !livePendingRequestIDs.contains($0.requestID) }
            .map(\.id)
        for id in stale { setTerminal(id, status: .expired, at: now, failure: nil) }
        return stale
    }

    /// Expire pending items whose gateway-indicated expiry has passed.
    @discardableResult
    public mutating func expireDue(at now: Date) -> [InboxItemID] {
        let due = pending.filter { ($0.expiresAt).map { $0 <= now } ?? false }.map(\.id)
        for id in due { setTerminal(id, status: .expired, at: now, failure: nil) }
        return due
    }

    /// A gateway was removed: its pending items can no longer be answered.
    @discardableResult
    public mutating func removeGateway(_ gatewayID: GatewayID, at now: Date) -> [InboxItemID] {
        let owned = pending.filter { $0.agent.gatewayID == gatewayID }.map(\.id)
        for id in owned {
            setTerminal(id, status: .failed, at: now, failure: "gateway removed")
        }
        return owned
    }

    /// Expire restored pending items whose gateway has not been reconciled
    /// within `maxAge`. A pending item from a previous launch is kept (so it
    /// survives relaunch) until a reconcile confirms it or it goes stale.
    @discardableResult
    public mutating func expireUnattended(
        attachedGateways: Set<GatewayID>,
        at now: Date,
        maxAge: TimeInterval
    ) -> [InboxItemID] {
        let stale = pending
            .filter { !attachedGateways.contains($0.agent.gatewayID) }
            .filter { now.timeIntervalSince($0.updatedAt) > maxAge }
            .map(\.id)
        for id in stale { setTerminal(id, status: .expired, at: now, failure: "not confirmed after reconnect") }
        return stale
    }

    // MARK: Caps

    private mutating func setTerminal(_ id: InboxItemID, status: InboxStatus, at now: Date, failure: String?) {
        guard var item = items[id] else { return }
        item.status = status
        item.updatedAt = now
        item.failureMessage = failure
        items[id] = item
        enforceCaps(at: now, reason: "inbox full")
    }

    private mutating func enforceCaps(at now: Date, reason: String) {
        // Pending overflow: the oldest pending items expire, visibly.
        let pendingItems = pending
        if pendingItems.count > Self.maxPendingItems {
            for item in pendingItems.prefix(pendingItems.count - Self.maxPendingItems) {
                setTerminalNoCaps(item.id, status: .expired, at: now, failure: reason)
            }
        }
        // History overflow: the least recently updated terminal items go.
        let history = items.values
            .filter { $0.status.isTerminal }
            .sorted { ($0.updatedAt, $0.id.rawValue) > ($1.updatedAt, $1.id.rawValue) }
        if history.count > Self.maxTerminalItems {
            for item in history.dropFirst(Self.maxTerminalItems) {
                items.removeValue(forKey: item.id)
            }
        }
    }

    private mutating func setTerminalNoCaps(_ id: InboxItemID, status: InboxStatus, at now: Date, failure: String?) {
        guard var item = items[id] else { return }
        item.status = status
        item.updatedAt = now
        item.failureMessage = failure
        items[id] = item
    }

    /// The audit records to keep: newest first, bounded by count and age.
    /// Records older than `auditRetention` relative to `now` are dropped, and
    /// the result never exceeds `maxAuditRecords`.
    public static func retainedAudit(_ records: [InboxDecisionRecord], now: Date) -> [InboxDecisionRecord] {
        let cutoff = now.addingTimeInterval(-auditRetention)
        let fresh = records
            .filter { $0.decidedAt >= cutoff }
            .sorted { $0.decidedAt > $1.decidedAt }
        return Array(fresh.prefix(maxAuditRecords))
    }
}

extension InboxItem {
    /// Convenience for building an approval item from the wire-level request.
    public static func approval(
        from request: ApprovalRequest,
        agent: InboxAgentIdentity,
        at now: Date
    ) -> InboxItem {
        InboxItem(
            id: InboxItemID(gatewayID: agent.gatewayID, sessionID: request.sessionID, requestID: request.requestID),
            kind: .approval,
            requestID: request.requestID,
            agent: agent,
            context: InboxContext(
                command: request.command,
                detail: request.detail,
                choices: request.choices),
            serverRequestID: request.serverRequestID,
            createdAt: now)
    }
}
