import Foundation
import Observation
import FleetCore

/// Phase B — the app-level approvals inbox.
///
/// Lives for the app's lifetime. It opens NO connection of its own. It learns
/// about requests from sources the app already has:
/// - open conversations: each registers its answer seams (`registerSource`) and
///   forwards the server requests, legacy `approval.request` events, and
///   `request.cancel` withdrawals it receives (`record`). Live delivery for a
///   session is therefore only as complete as the conversation transports the
///   app currently holds.
/// - the Live Ops `approval.pending` poll (`setPollSource`): cross-session
///   discovery. It runs only while Home or an Operation Detail polls, so an
///   approval on a session that is not open and not being polled is seen on the
///   next poll or refresh, not instantly.
///
/// Rules this store enforces:
/// - Identity: an item is keyed by gateway + session + request id, so the same
///   request from a conversation and from the poll is ONE item.
/// - Answering: a server request (`srq-`) is answered ONLY on the source that
///   delivered it. A legacy approval may be answered by the poll source
///   (`approval.respond`). If the source is gone the decision fails with
///   `.gatewayUnavailable` and nothing is sent.
/// - Withdrawal is never a denial. `request.cancel` → `.cancelled`.
/// - Approve needs (1) full review of a long command and (2) a verified user
///   presence check before any wire call. Deny is ungated.
/// - Every decision attempt is audited with its outcome. Answer values and
///   secrets are never audited, stored, or logged.
/// - Banner ↔ inbox agreement: a banner or prompt decision is reported via
///   `noteConversationDecision`, and every pending → terminal transition is
///   published on `resolutions()` so an open banner or prompt dismisses it.
@MainActor
@Observable
public final class InboxStore: InboxProviding {

    // MARK: Observable state

    public private(set) var items: [InboxItem] = []
    public private(set) var auditTrail: [InboxDecisionRecord] = []

    // MARK: Constants

    /// Cadence of the periodic reconcile while the app is foregrounded.
    public static let reconcileInterval: Duration = .seconds(60)
    /// Restored pending items older than this, with no reachable gateway, expire.
    public static let restoredMaxAge: TimeInterval = 60 * 60

    // MARK: Injected seams

    private let biometrics: any AppLockBiometricAuth
    private let decider: InboxDecider
    private let now: @Sendable () -> Date
    private let history: any InboxHistoryStoring
    /// The periodic-reconcile clock. Tests inject a controllable sleep.
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Session ids to reconcile for a gateway (the Live Ops `.waiting` sessions).
    private var sessionProvider: @MainActor (GatewayID) -> [String] = { _ in [] }
    private var pollSourceProvider: @MainActor (GatewayID) -> (any InboxAnswerSource)? = { _ in nil }
    private var gatewaysProvider: @MainActor () -> [FleetGateway] = { [] }
    private var connectionStateProvider: @MainActor (GatewayID) -> GatewayConnectionState = { _ in .idle }

    // MARK: Internal state

    @ObservationIgnored private var ledger = InboxLedger()
    @ObservationIgnored private var reviewTracker = ApprovalReviewTracker()
    @ObservationIgnored private var audit: [InboxDecisionRecord] = []
    @ObservationIgnored private var sources: [UUID: Registration] = [:]
    @ObservationIgnored private var itemSource: [InboxItemID: UUID] = [:]
    @ObservationIgnored private var inFlight: Set<InboxItemID> = []
    @ObservationIgnored private var updateObservers: [UUID: AsyncStream<[InboxItem]>.Continuation] = [:]
    @ObservationIgnored private var resolutionObservers: [UUID: AsyncStream<InboxResolution>.Continuation] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var reconcileLoop: Task<Void, Never>?

    private struct Registration {
        let gatewayID: GatewayID
        let label: String
        let source: any InboxAnswerSource
    }

    public init(
        history: any InboxHistoryStoring,
        biometrics: any AppLockBiometricAuth,
        ownerName: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.history = history
        self.biometrics = biometrics
        self.decider = .thisDevice(ownerName: ownerName)
        self.now = now
        self.sleep = sleep
        loadTask = Task { @MainActor [weak self] in
            await self?.load()
        }
    }

    /// Wire the per-gateway session list (Live Ops `.waiting` sessions).
    public func setSessionProvider(_ provider: @escaping @MainActor (GatewayID) -> [String]) {
        sessionProvider = provider
    }

    /// Wire the cross-session discovery source: the gateway's approvals seam
    /// used for `approval.pending`. Nil when the gateway has no seam.
    public func setPollSource(_ provider: @escaping @MainActor (GatewayID) -> (any InboxAnswerSource)?) {
        pollSourceProvider = provider
    }

    /// Wire the live gateway list and per-gateway connection state.
    public func setProviders(
        gateways: @escaping @MainActor () -> [FleetGateway],
        connectionState: @escaping @MainActor (GatewayID) -> GatewayConnectionState
    ) {
        gatewaysProvider = gateways
        connectionStateProvider = connectionState
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

    /// Every pending → terminal transition, from any source.
    public func resolutions() -> AsyncStream<InboxResolution> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<InboxResolution>.makeStream(bufferingPolicy: .unbounded)
        resolutionObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.resolutionObservers.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: Sources

    /// Register an open conversation's answer seams. Returns the id its events
    /// are recorded under. The caller unregisters it when the conversation ends.
    public func registerSource(_ source: any InboxAnswerSource, label: String?) -> UUID {
        let id = UUID()
        let resolved = label ?? gatewayLabel(source.gatewayID)
        sources[id] = Registration(gatewayID: source.gatewayID, label: resolved, source: source)
        return id
    }

    /// Remove a source. Items it delivered stay pending, but can no longer be
    /// answered through it.
    public func unregisterSource(_ id: UUID) {
        sources.removeValue(forKey: id)
    }

    /// Gateways that currently have a registered source.
    public var sourceGatewayIDs: Set<GatewayID> {
        Set(sources.values.map(\.gatewayID))
    }

    /// Record one inbox-relevant event delivered on a registered source.
    public func record(_ event: InboxFeedEvent, sourceID: UUID) {
        guard let registration = sources[sourceID] else { return }
        let at = now()
        switch event {
        case .serverRequest(let request):
            ingest(.make(from: request, agent: identity(registration, session: request.sessionID), at: at), sourceID: sourceID)
        case .legacyApproval(let approval):
            ingest(.approval(from: approval, agent: identity(registration, session: approval.sessionID), at: at), sourceID: sourceID)
        case .withdrawn(let wireID):
            commit { $0.cancel(wireRequestID: wireID, at: at) }
        }
    }

    /// A gateway was removed from the fleet: its pending items fail and its
    /// sources are dropped.
    public func forget(gatewayID: GatewayID) {
        sources = sources.filter { $0.value.gatewayID != gatewayID }
        let at = now()
        commit { $0.removeGateway(gatewayID, at: at) }
    }

    private func identity(_ registration: Registration, session: String) -> InboxAgentIdentity {
        InboxAgentIdentity(gatewayID: registration.gatewayID, gatewayLabel: registration.label, sessionID: session)
    }

    private func ingest(_ item: InboxItem, sourceID: UUID) {
        let result = ledger.ingest(item)
        guard result != .ignoredTerminal else { return }
        // Keep the first source still registered: a srq item must stay answerable
        // on the transport that delivered it.
        if itemSource[item.id].flatMap({ sources[$0] }) == nil {
            itemSource[item.id] = sourceID
        }
        publish()
    }

    // MARK: Reconcile and periodic refresh

    /// Start the periodic reconcile while the app is foregrounded, or stop it.
    /// Cancellable: backgrounding stops it.
    public func setForeground(_ active: Bool) {
        reconcileLoop?.cancel()
        reconcileLoop = nil
        guard active else { return }
        reconcileLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.sleep(Self.reconcileInterval)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                await self.refresh()
            }
        }
    }

    /// Whether the periodic reconcile is running.
    public var isReconcilingPeriodically: Bool { reconcileLoop != nil }

    /// Reconcile every connected gateway that has a poll source against
    /// `approval.pending`, then expire restored items whose gateway is not reachable.
    public func refresh() async {
        await awaitLoaded()
        var reachable: Set<GatewayID> = sourceGatewayIDs
        for gateway in gatewaysProvider() where connectionStateProvider(gateway.id) == .connected {
            guard pollSourceProvider(gateway.id) != nil else { continue }
            reachable.insert(gateway.id)
            await reconcile(gatewayID: gateway.id, sessionIDs: sessionProvider(gateway.id))
        }
        let at = now()
        commit { $0.expireUnattended(attachedGateways: reachable, at: at, maxAge: Self.restoredMaxAge) }
    }

    /// Reconcile one gateway's sessions against its poll source. Fail-soft per
    /// session: a failed read is not an answer, so nothing expires.
    public func reconcile(gatewayID: GatewayID, sessionIDs: [String]) async {
        guard let poll = pollSourceProvider(gatewayID) else { return }
        let label = gatewayLabel(gatewayID)
        for sessionID in sessionIDs {
            let started = now()
            let live: [ApprovalRequest]
            do {
                live = try await poll.approvals.pendingApprovals(sessionID: sessionID)
            } catch {
                continue
            }
            let agent = InboxAgentIdentity(gatewayID: gatewayID, gatewayLabel: label, sessionID: sessionID)
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

    private func gatewayLabel(_ gatewayID: GatewayID) -> String {
        if let registration = sources.values.first(where: { $0.gatewayID == gatewayID }) {
            return registration.label
        }
        return gatewaysProvider().first(where: { $0.id == gatewayID })?.displayName ?? ApprovalOrigin.unknownValue
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
            let source = try answerSource(for: item)
            inFlight.insert(itemID)
            defer { inFlight.remove(itemID) }
            // Presence comes BEFORE any wire call. A failed check sends nothing.
            let result = await biometrics.verifyPresence(presence)
            guard result == .verified else { throw InboxError.presenceNotVerified(result) }
            guard ledger.item(itemID)?.status == .pending else { throw InboxError.notPending }
            return try await sendApproval(item: item, request: request, choice: choice, source: source, action: action)

        case (.approval, .deny):
            let source = try answerSource(for: item)
            inFlight.insert(itemID)
            defer { inFlight.remove(itemID) }
            return try await sendApproval(
                item: item, request: Self.approvalRequest(item), choice: .deny, source: source, action: action)

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

    /// A decision the user made on a conversation banner or prompt, reported
    /// so the inbox agrees. Audited as a successful decision on this device.
    /// A no-op for an item that is already settled.
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

    /// The source that can answer this item. A server request is answered ONLY
    /// by the source that delivered it. A legacy approval may use the poll source.
    private func answerSource(for item: InboxItem) throws -> any InboxAnswerSource {
        if let id = itemSource[item.id], let registration = sources[id] {
            return registration.source
        }
        if item.serverRequestID == nil, let poll = pollSourceProvider(item.agent.gatewayID) {
            return poll
        }
        throw InboxError.gatewayUnavailable
    }

    private func sendApproval(
        item: InboxItem,
        request: ApprovalRequest,
        choice: ApprovalChoice,
        source: any InboxAnswerSource,
        action: InboxDecisionAction
    ) async throws -> InboxDecisionRecord {
        do {
            let resolved = try await source.approvals.respond(to: request, choice: choice, all: false)
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
        let source = try answerSource(for: item)
        guard let prompts = source.prompts, let serverRequestID = item.serverRequestID else {
            throw InboxError.gatewayUnavailable
        }
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
                try await prompts.answerClarify(requestID: serverRequestID, answer: value)
            case .sudo, .secret:
                try await prompts.answerValue(requestID: serverRequestID, value: value)
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
            itemSource.removeValue(forKey: id)
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

    /// Saves run in order and only after the initial load has merged, so a
    /// save can never overwrite persisted items that have not been restored yet.
    /// The snapshot is taken when the save runs, so it is the latest state.
    private func persist() {
        let previous = pendingSave
        let loading = loadTask
        let history = self.history
        pendingSave = Task { @MainActor [weak self] in
            _ = await loading?.value
            _ = await previous?.value
            guard let self else { return }
            let snapshot = InboxPersistedState(items: self.ledger.ordered, audit: self.audit)
            try? await history.save(snapshot)
        }
    }

    /// Merge the persisted state in. Events recorded before this completes are
    /// live and are never overwritten by the older snapshot.
    private func load() async {
        let state = await history.load()
        let at = now()
        ledger.restore(state.items)
        ledger.expireUnattended(attachedGateways: [], at: at, maxAge: Self.restoredMaxAge)
        audit = InboxLedger.retainedAudit(state.audit + audit, now: at)
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
