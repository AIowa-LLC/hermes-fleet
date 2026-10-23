import Foundation
import Observation
import FleetCore

/// Builds the inbox feed for ONE gateway (the concrete transport-backed feed
/// is constructed at the composition root). `nil` when the gateway has no
/// endpoint (fail closed: that gateway contributes no inbox items).
public typealias FleetInboxFeedFactory = @Sendable (_ gateway: FleetGateway) -> (any InboxGatewayFeed)?

/// Phase B — the app-level approvals inbox.
///
/// Lives for the app's lifetime (it is NOT per conversation). Every attached
/// gateway feeds it: live server requests, legacy `approval.request` events,
/// and `request.cancel` withdrawals from ALL sessions. It reconciles against
/// `approval.pending` on refresh, so an item survives a relaunch while still
/// pending.
///
/// Rules this store enforces:
/// - Identity: an item is keyed by gateway + session + request id, so the same
///   request from a conversation banner, a re-delivery, or a second path is ONE
///   item (see `InboxItemID`).
/// - Withdrawal is never a denial. `request.cancel` → `.cancelled`, nothing sent.
/// - Approve needs (1) full review of a long command and (2) a verified user
///   presence check (`AppLockBiometricAuth`, the same gate the banner uses),
///   both BEFORE anything reaches the wire. Deny is ungated.
/// - A gateway that is not attached cannot be answered: `.gatewayUnavailable`.
/// - Every decision attempt is audited with its outcome. Values (answers,
///   secrets) are never audited, stored, or logged.
/// - Banner ↔ inbox agreement: a decision made on a conversation banner is
///   reported via `noteConversationDecision`, and every pending → terminal
///   transition is published on `resolutions()` so an open banner dismisses
///   the same request.
@MainActor
@Observable
public final class InboxStore: InboxProviding {

    // MARK: Observable state

    public private(set) var items: [InboxItem] = []
    public private(set) var auditTrail: [InboxDecisionRecord] = []

    /// Gateways currently attached to a live feed.
    public var attachedGatewayIDs: Set<GatewayID> { Set(feeds.keys) }

    // MARK: Injected seams

    private let biometrics: any AppLockBiometricAuth
    private let decider: InboxDecider
    private let now: @Sendable () -> Date
    private let history: any InboxHistoryStoring
    private let feedFactory: FleetInboxFeedFactory

    /// Restored pending items older than this, with no attached gateway, expire.
    public static let restoredMaxAge: TimeInterval = 60 * 60

    /// Session ids to reconcile for a gateway (the Live Ops `.waiting` sessions,
    /// supplied by the composition root). Never a fan-out over the roster.
    private var sessionProvider: @MainActor (GatewayID) -> [String] = { _ in [] }
    private var gatewaysProvider: @MainActor () -> [FleetGateway] = { [] }
    private var connectionStateProvider: @MainActor (GatewayID) -> GatewayConnectionState = { _ in .idle }

    // MARK: Internal state

    @ObservationIgnored private var ledger = InboxLedger()
    @ObservationIgnored private var reviewTracker = ApprovalReviewTracker()
    @ObservationIgnored private var audit: [InboxDecisionRecord] = []
    @ObservationIgnored private var feeds: [GatewayID: Attachment] = [:]
    @ObservationIgnored private var inFlight: Set<InboxItemID> = []
    @ObservationIgnored private var updateObservers: [UUID: AsyncStream<[InboxItem]>.Continuation] = [:]
    @ObservationIgnored private var resolutionObservers: [UUID: AsyncStream<InboxResolution>.Continuation] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    private struct Attachment {
        let feed: any InboxGatewayFeed
        let label: String
        let consumer: Task<Void, Never>
    }

    public init(
        history: any InboxHistoryStoring,
        biometrics: any AppLockBiometricAuth,
        feedFactory: @escaping FleetInboxFeedFactory = { _ in nil },
        ownerName: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.history = history
        self.biometrics = biometrics
        self.feedFactory = feedFactory
        self.decider = .thisDevice(ownerName: ownerName)
        self.now = now
        loadTask = Task { @MainActor [weak self] in
            await self?.load()
        }
    }

    /// Supply the per-gateway session list used by `refresh()`.
    public func setSessionProvider(_ provider: @escaping @MainActor (GatewayID) -> [String]) {
        sessionProvider = provider
    }

    /// Supply the live gateway list and per-gateway connection state that
    /// `syncConnections()` reads (mirrors `LiveOpsStore.setProviders`).
    public func setProviders(
        gateways: @escaping @MainActor () -> [FleetGateway],
        connectionState: @escaping @MainActor (GatewayID) -> GatewayConnectionState
    ) {
        gatewaysProvider = gateways
        connectionStateProvider = connectionState
    }

    /// Attach a feed for every CONNECTED gateway, detach gateways that dropped
    /// off, and forget gateways that were removed. Called on connection-state
    /// changes and on foreground. A newly attached gateway is reconciled
    /// against `approval.pending` right away.
    public func syncConnections() {
        let gateways = gatewaysProvider()
        let known = Set(gateways.map(\.id))
        for id in feeds.keys where !known.contains(id) {
            forget(gatewayID: id)
        }
        for gateway in gateways {
            let connected = connectionStateProvider(gateway.id) == .connected
            if connected {
                guard feeds[gateway.id] == nil, let feed = feedFactory(gateway) else { continue }
                attach(feed, label: gateway.displayName)
            } else {
                detach(gatewayID: gateway.id)
            }
        }
    }


    /// Resolves once the persisted state has been loaded.
    public func awaitLoaded() async {
        await loadTask?.value
    }

    // MARK: Streams

    /// Snapshot stream: the current items immediately, then on every change.
    public func updates() -> AsyncStream<[InboxItem]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[InboxItem]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updateObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.updateObservers.removeValue(forKey: id) }
        }
        continuation.yield(items)
        return stream
    }

    /// Every pending → terminal transition, from any source. A conversation
    /// banner subscribes so it dismisses a request the inbox resolved.
    public func resolutions() -> AsyncStream<InboxResolution> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<InboxResolution>.makeStream(bufferingPolicy: .unbounded)
        resolutionObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.resolutionObservers.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: Feed attachment

    /// Attach a connected gateway's feed. Idempotent per gateway: a second
    /// attach replaces the first. Starts the feed's connection, then consumes
    /// its events for as long as it stays attached.
    public func attach(_ feed: any InboxGatewayFeed, label: String) {
        let gatewayID = feed.gatewayID
        feeds[gatewayID]?.consumer.cancel()
        let consumer = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.awaitLoaded()
            // Subscribe BEFORE connecting so no live request is missed in
            // between; the transport replays already-open requests on subscribe.
            let events = feed.events()
            do {
                try await feed.start()
            } catch {
                return
            }
            // Reconcile the restart window: anything the gateway still holds
            // as pending is confirmed, anything it no longer lists expires.
            await self.reconcile(gatewayID: gatewayID, sessionIDs: self.sessionProvider(gatewayID))
            for await event in events {
                if Task.isCancelled { break }
                self.apply(event, gatewayID: gatewayID)
            }
        }
        feeds[gatewayID] = Attachment(feed: feed, label: label, consumer: consumer)
    }

    /// The gateway disconnected or was switched off. Pending items are kept
    /// (they reconcile when it returns) but cannot be answered while detached.
    public func detach(gatewayID: GatewayID) {
        guard let attachment = feeds.removeValue(forKey: gatewayID) else { return }
        attachment.consumer.cancel()
        let feed = attachment.feed
        Task { await feed.stop() }
    }

    /// The gateway was removed from the fleet: its pending items fail.
    public func forget(gatewayID: GatewayID) {
        detach(gatewayID: gatewayID)
        commit { $0.removeGateway(gatewayID, at: now()) }
    }

    // MARK: Ingest

    private func apply(_ event: InboxFeedEvent, gatewayID: GatewayID) {
        guard let attachment = feeds[gatewayID] else { return }
        let at = now()
        switch event {
        case .serverRequest(let request):
            let agent = identity(gatewayID, attachment.label, session: request.sessionID)
            ingest(.make(from: request, agent: agent, at: at))
        case .legacyApproval(let approval):
            let agent = identity(gatewayID, attachment.label, session: approval.sessionID)
            ingest(.approval(from: approval, agent: agent, at: at))
        case .withdrawn(let wireID):
            commit { $0.cancel(wireRequestID: wireID, at: at) }
        }
    }

    private func identity(_ gatewayID: GatewayID, _ label: String, session: String) -> InboxAgentIdentity {
        InboxAgentIdentity(gatewayID: gatewayID, gatewayLabel: label, sessionID: session)
    }

    private func ingest(_ item: InboxItem) {
        guard ledger.ingest(item) != .ignoredTerminal else { return }
        publish()
    }

    // MARK: Reconcile

    /// Reconcile every attached gateway against `approval.pending`, then expire
    /// restored items whose gateway never came back.
    public func refresh() async {
        await awaitLoaded()
        for gatewayID in Array(feeds.keys) {
            await reconcile(gatewayID: gatewayID, sessionIDs: sessionProvider(gatewayID))
        }
        let at = now()
        let attached = attachedGatewayIDs
        commit { $0.expireUnattended(attachedGateways: attached, at: at, maxAge: Self.restoredMaxAge) }
    }

    /// Reconcile one gateway for the given sessions. Fail-soft per session: a
    /// session whose `approval.pending` read fails is left untouched.
    public func reconcile(gatewayID: GatewayID, sessionIDs: [String]) async {
        guard let attachment = feeds[gatewayID] else { return }
        for sessionID in sessionIDs {
            let started = now()
            let live: [ApprovalRequest]
            do {
                live = try await attachment.feed.pendingApprovals(sessionID: sessionID)
            } catch {
                continue
            }
            let agent = identity(gatewayID, attachment.label, session: sessionID)
            for request in live {
                ledger.ingest(.approval(from: request, agent: agent, at: started))
            }
            // Items delivered live while this read was in flight are not
            // expired by a snapshot that predates them.
            let recent = Set(ledger.pending
                .filter { $0.agent.gatewayID == gatewayID && $0.agent.sessionID == sessionID && $0.updatedAt > started }
                .map(\.requestID))
            let liveIDs = Set(live.map(\.requestID)).union(recent)
            commit { $0.reconcile(gatewayID: gatewayID, sessionID: sessionID, livePendingRequestIDs: liveIDs, at: started) }
        }
    }

    // MARK: Decisions

    public func decide(_ itemID: InboxItemID, _ decision: InboxDecision) async throws -> InboxDecisionRecord {
        guard let item = ledger.item(itemID) else { throw InboxError.notFound }
        guard item.status == .pending, !inFlight.contains(itemID) else { throw InboxError.notPending }
        let action = InboxDecisionAction(decision)

        switch (item.kind, decision) {
        case (.approval, .approve(let choice)):
            let request = Self.approvalRequest(item)
            guard reviewTracker.canApprove(request) else { throw InboxError.reviewRequired }
            guard let presence = PresenceAction(approvalChoice: choice) else {
                throw InboxError.unsupportedKind(.approval)
            }
            let feed = try attachedFeed(for: item)
            inFlight.insert(itemID)
            defer { inFlight.remove(itemID) }
            // Presence comes BEFORE any wire call. A failed check sends nothing.
            let result = await biometrics.verifyPresence(presence)
            guard result == .verified else { throw InboxError.presenceNotVerified(result) }
            guard ledger.item(itemID)?.status == .pending else { throw InboxError.notPending }
            return try await sendApproval(item: item, request: request, choice: choice, feed: feed, action: action)

        case (.approval, .deny):
            let feed = try attachedFeed(for: item)
            inFlight.insert(itemID)
            defer { inFlight.remove(itemID) }
            return try await sendApproval(
                item: item, request: Self.approvalRequest(item), choice: .deny, feed: feed, action: action)

        case (.question, .answer(let text)) where !item.context.isBatchQuestion:
            return try await sendAnswer(item: item, value: text, action: action, presence: nil)

        case (.question, .skip) where !item.context.isBatchQuestion:
            return try await sendAnswer(item: item, value: "", action: action, presence: nil)

        case (.sudo, .answer(let text)):
            return try await sendAnswer(item: item, value: text, action: action, presence: .enterSudoPassword)

        case (.sudo, .skip):
            return try await sendAnswer(item: item, value: "", action: action, presence: nil)

        case (.secret, .answer(let text)):
            return try await sendAnswer(item: item, value: text, action: action, presence: .enterSecret)

        case (.secret, .skip):
            return try await sendAnswer(item: item, value: "", action: action, presence: nil)

        default:
            throw InboxError.unsupportedKind(item.kind)
        }
    }

    /// The user reviewed a long command in full. Only that request is affected.
    public func markReviewed(_ itemID: InboxItemID) {
        guard let item = ledger.item(itemID), item.status == .pending else { return }
        reviewTracker.markReviewed(Self.approvalRequest(item))
    }

    /// A decision the user made on a conversation banner, reported so the inbox
    /// agrees. Audited as a successful decision on this device. A no-op for an
    /// item that is already settled.
    public func noteConversationDecision(
        gatewayID: GatewayID,
        sessionID: String,
        requestID: String,
        decision: InboxDecision
    ) {
        let itemID = InboxItemID(gatewayID: gatewayID, sessionID: sessionID, requestID: requestID)
        guard let item = ledger.item(itemID), item.status == .pending else { return }
        let status: InboxStatus
        switch decision {
        case .approve: status = .approved
        case .deny: status = .denied
        case .answer, .skip: status = .answered
        }
        let at = now()
        commit { $0.resolve(itemID, as: status, at: at) }
        appendAudit(item: item, action: InboxDecisionAction(decision), outcome: .succeeded)
    }

    // MARK: Sending

    private func attachedFeed(for item: InboxItem) throws -> any InboxGatewayFeed {
        guard let attachment = feeds[item.agent.gatewayID] else { throw InboxError.gatewayUnavailable }
        return attachment.feed
    }

    private func sendApproval(
        item: InboxItem,
        request: ApprovalRequest,
        choice: ApprovalChoice,
        feed: any InboxGatewayFeed,
        action: InboxDecisionAction
    ) async throws -> InboxDecisionRecord {
        do {
            let resolved = try await feed.approvals.respond(to: request, choice: choice, all: false)
            guard resolved > 0 else {
                // The gateway no longer had it: answered or timed out elsewhere.
                let message = "This request was already answered elsewhere."
                let at = now()
                commit { $0.resolve(item.id, as: .expired, at: at, failure: message) }
                let record = appendAudit(item: item, action: action, outcome: .failed(message: message))
                throw InboxError.gatewayRejected(record.outcome.failureText)
            }
            let at = now()
            commit { $0.resolve(item.id, as: choice == .deny ? .denied : .approved, at: at) }
            return appendAudit(item: item, action: action, outcome: .succeeded)
        } catch let error as InboxError {
            throw error
        } catch {
            try fail(item: item, action: action, error: error)
        }
    }

    private func sendAnswer(
        item: InboxItem,
        value: String,
        action: InboxDecisionAction,
        presence: PresenceAction?
    ) async throws -> InboxDecisionRecord {
        let feed = try attachedFeed(for: item)
        guard let serverRequestID = item.serverRequestID else { throw InboxError.unsupportedKind(item.kind) }
        if let presence, !value.isEmpty {
            // A typed sudo password or secret needs the same presence check the
            // conversation prompt uses. Nothing is sent without it.
            inFlight.insert(item.id)
            let result = await biometrics.verifyPresence(presence)
            inFlight.remove(item.id)
            guard result == .verified else { throw InboxError.presenceNotVerified(result) }
            guard ledger.item(item.id)?.status == .pending else { throw InboxError.notPending }
        }
        do {
            switch item.kind {
            case .question:
                try await feed.prompts.answerClarify(requestID: serverRequestID, answer: value)
            case .sudo, .secret:
                try await feed.prompts.answerValue(requestID: serverRequestID, value: value)
            case .approval:
                throw InboxError.unsupportedKind(.approval)
            }
            let at = now()
            commit { $0.resolve(item.id, as: .answered, at: at) }
            return appendAudit(item: item, action: action, outcome: .succeeded)
        } catch let error as InboxError {
            throw error
        } catch {
            try fail(item: item, action: action, error: error)
        }
    }

    /// A failed send leaves the item pending (retryable) and audits the
    /// attempt. The message is the redacted, display-safe description; it never
    /// echoes the command or the answer.
    private func fail(item: InboxItem, action: InboxDecisionAction, error: Error) throws -> Never {
        let message = Redaction.userFacingErrorDescription(error)
        let at = now()
        commit { $0.recordFailure(item.id, message: message, at: at) }
        let record = appendAudit(item: item, action: action, outcome: .failed(message: message))
        throw InboxError.gatewayRejected(record.outcome.failureText)
    }

    // MARK: Helpers

    private static func approvalRequest(_ item: InboxItem) -> ApprovalRequest {
        ApprovalRequest(
            requestID: item.requestID,
            sessionID: item.agent.sessionID,
            command: item.context.command ?? "",
            detail: item.context.detail,
            choices: item.context.choices,
            serverRequestID: item.serverRequestID)
    }

    @discardableResult
    private func appendAudit(
        item: InboxItem,
        action: InboxDecisionAction,
        outcome: InboxDecisionOutcome
    ) -> InboxDecisionRecord {
        let at = now()
        let record = InboxDecisionRecord(
            itemID: item.id,
            kind: item.kind,
            action: action,
            gatewayID: item.agent.gatewayID,
            sessionID: item.agent.sessionID,
            agentLabel: item.agent.gatewayLabel,
            decider: decider,
            decidedAt: at,
            outcome: outcome)
        audit = InboxLedger.retainedAudit([record] + audit, now: at)
        auditTrail = audit
        persist()
        return record
    }

    /// Apply a ledger mutation, then publish the change and any new terminal
    /// transitions. Every state change goes through here.
    private func commit(_ mutate: (inout InboxLedger) -> Void) {
        let before = Set(ledger.pending.map(\.id))
        mutate(&ledger)
        emitResolutions(from: before)
        publish()
    }

    private func emitResolutions(from before: Set<InboxItemID>) {
        for id in before {
            guard let item = ledger.item(id), item.status.isTerminal else { continue }
            reviewTracker.forget(requestID: item.requestID)
            let resolution = InboxResolution(
                itemID: id,
                gatewayID: item.agent.gatewayID,
                sessionID: item.agent.sessionID,
                requestID: item.requestID,
                kind: item.kind,
                status: item.status)
            for observer in resolutionObservers.values { observer.yield(resolution) }
        }
    }

    private func publish() {
        items = ledger.ordered
        for observer in updateObservers.values { observer.yield(items) }
        persist()
    }

    private func persist() {
        let snapshot = InboxPersistedState(items: ledger.ordered, audit: audit)
        let previous = pendingSave
        pendingSave = Task {
            _ = await previous?.value
            try? await history.save(snapshot)
        }
    }

    private func load() async {
        let state = await history.load()
        ledger = InboxLedger(items: state.items)
        let at = now()
        ledger.expireUnattended(attachedGateways: [], at: at, maxAge: Self.restoredMaxAge)
        audit = InboxLedger.retainedAudit(state.audit, now: at)
        items = ledger.ordered
        auditTrail = audit
    }
}

/// A pending item reached a terminal status. Published on `resolutions()`.
public struct InboxResolution: Equatable, Sendable {
    public let itemID: InboxItemID
    public let gatewayID: GatewayID
    public let sessionID: String
    public let requestID: String
    public let kind: InboxItemKind
    public let status: InboxStatus
}

extension InboxDecisionOutcome {
    /// Display-safe text for a failed outcome; empty for success.
    var failureText: String {
        if case .failed(let message) = self { return message }
        return ""
    }
}
