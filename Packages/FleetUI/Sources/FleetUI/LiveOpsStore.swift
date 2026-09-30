import Foundation
import Observation
import FleetCore

/// Builds the Live Ops read seam (`LiveOpsProviding` + `LiveOpsSubagentControlling`)
/// PLUS the same gateway's approvals seam (`ApprovalsProviding`) for ONE
/// gateway. Lives in FleetUI (never FleetNetworking — M0 guard); the
/// composition root builds the concrete `GatewayLiveOpsClient` /
/// `GatewayApprovalClient` pair over the SAME transport, mirroring how the
/// other per-gateway factories in this file are shaped. `nil` when the
/// gateway has no endpoint wired (fail closed — the store then reports that
/// gateway `.disconnected` without ever attempting a request).
public typealias FleetLiveOpsFactory = @Sendable (
    _ gateway: FleetGateway
) -> LiveOpsGatewaySeam?

/// One gateway's Live Ops read/control seam + its approvals seam, bundled
/// because Home's approve/deny flow answers a Live Ops attention row over
/// the SAME per-gateway approvals path `ConversationViewModel` already uses
/// (`ApprovalsCapable.approvals`) — this is just that seam reachable without
/// an open conversation.
public struct LiveOpsGatewaySeam: Sendable {
    public let ops: any LiveOpsProviding & LiveOpsSubagentControlling
    public let approvals: any ApprovalsProviding

    public init(ops: any LiveOpsProviding & LiveOpsSubagentControlling, approvals: any ApprovalsProviding) {
        self.ops = ops
        self.approvals = approvals
    }
}

/// Fleet-wide Live Ops observation, owned by FleetUI (`AppEnvironment`
/// injects it) so the dashboard and Operation Detail share ONE coalesced
/// polling loop instead of a poller per row.
///
/// Polling discipline (mission contract):
/// - refresh only while Home or an Operation Detail is visible — callers
///   register/unregister a `PollContext` from `.task` lifetimes;
/// - cadence ~5s while only Home is visible, ~2s while any Operation Detail
///   is visible (a closer view deserves a tighter loop; Home's summary
///   strip does not need sub-5s freshness);
/// - ONE loop for the whole fleet, bounded concurrency (≤3 gateways in
///   flight at once);
/// - only CONNECTED gateways are asked — a disconnected gateway is folded
///   into the snapshot as `.disconnected` coverage with no request;
/// - `approval.pending` is fetched ONLY for sessions currently `.waiting`
///   (never a fan-out over the whole roster);
/// - every refresh is stamped with a monotonic per-cycle generation before
///   `LiveOpsSnapshotReducer.merge` — a slow gateway's response from an
///   older cycle can never overwrite a newer cycle's result for that
///   gateway (the reducer's own generation/observedAt tiebreak still
///   applies within a cycle);
/// - `session.activate` is never called from this store — this is
///   monitoring only.
@MainActor
@Observable
public final class LiveOpsStore {

    /// A visible surface that wants the polling loop running. Home and each
    /// open Operation Detail register their own context; the loop stops the
    /// instant the last one unregisters.
    public enum PollContext: Hashable, Sendable {
        case home
        case detail(LiveOperationID)
        case setup(GatewayID)
        case gateway(GatewayID)
    }

    // MARK: Observable state

    public private(set) var snapshot: LiveOpsSnapshot?
    /// Live Ops attention rows (waiting sessions, joined with any pending
    /// approval for that session). Keyed implicitly by `LiveOperationID`
    /// (one row per waiting operation) — never duplicated across refreshes.
    public private(set) var attentionItems: [LiveOpsAttentionItem] = []
    /// requestIDs currently being answered (approve/deny in flight) so the
    /// row can show a disabled/"Working…" affordance instead of double-firing.
    public private(set) var resolvingRequestIDs: Set<String> = []
    /// Non-secret, display-safe message from the last failed approve/deny,
    /// keyed by requestID.
    public private(set) var actionErrors: [String: String] = [:]
    /// P0.2a: long commands the user has reviewed in full. Home applies the
    /// same rule as the conversation banner — Approve stays blocked until the
    /// review sheet has been completed — so the guard cannot be bypassed here.
    public private(set) var reviewTracker = ApprovalReviewTracker()

    /// Message returned by `approve` when a long command has not been reviewed.
    public static let reviewRequiredMessage = "Review the full command before approving"

    /// Per-operation "live since you opened" timeline, populated only while
    /// that operation's Operation Detail is an active poll context (bounded
    /// memory — Home never accumulates timelines for operations no one is
    /// looking at).
    public private(set) var timelines: [LiveOperationID: [OperationTimelineEntry]] = [:]

    public struct OperationTimelineEntry: Identifiable, Hashable, Sendable {
        public let id = UUID()
        public let at: Date
        public let text: String
    }

    /// Whether `listSubagents` has succeeded for an operation this session —
    /// proof the transport is attached, gating child controls in Operation
    /// Detail (`.notAttached` hides them instead of guessing at authority).
    public private(set) var attachedOperations: Set<LiveOperationID> = []

    // MARK: Injected seams

    private let factory: FleetLiveOpsFactory
    private let biometrics: any AppLockBiometricAuth

    private var gatewaysProvider: @MainActor () -> [FleetGateway] = { [] }
    private var connectionStateProvider: @MainActor (GatewayID) -> GatewayConnectionState = { _ in .idle }

    @ObservationIgnored private var seams: [GatewayID: LiveOpsGatewaySeam] = [:]
    @ObservationIgnored private var activeContexts: Set<PollContext> = []
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var cycle = 0
    @ObservationIgnored private var lastOperationsByID: [LiveOperationID: LiveOperation] = [:]

    public init(
        factory: @escaping FleetLiveOpsFactory,
        biometrics: any AppLockBiometricAuth
    ) {
        self.factory = factory
        self.biometrics = biometrics
    }

    /// Wire the live gateway list / connection state (mirrors
    /// `BotManagementController.setGatewayProvider` — the store never holds
    /// its own copy of `AppEnvironment`'s observable state).
    public func setProviders(
        gateways: @escaping @MainActor () -> [FleetGateway],
        connectionState: @escaping @MainActor (GatewayID) -> GatewayConnectionState
    ) {
        gatewaysProvider = gateways
        connectionStateProvider = connectionState
    }

    // MARK: Visibility lifecycle

    /// Register a visible surface. Call from `.task { }` and hold until the
    /// task is cancelled (view disappears / scenePhase backgrounds).
    public func beginObserving(_ context: PollContext) {
        activeContexts.insert(context)
        startLoopIfNeeded()
        // Kick one immediate refresh so a freshly opened surface doesn't
        // wait a full cadence for its first paint.
        Task { await refreshOnce() }
    }

    public func endObserving(_ context: PollContext) {
        activeContexts.remove(context)
        if case .detail(let id) = context {
            // Bounded memory: drop the timeline the instant nobody is
            // looking at this operation.
            timelines[id] = nil
            attachedOperations.remove(id)
        }
        if activeContexts.isEmpty {
            loopTask?.cancel()
            loopTask = nil
        }
    }

    private var cadence: Duration {
        activeContexts.contains(where: {
            if case .detail = $0 { return true }
            return false
        }) ? .seconds(2) : .seconds(5)
    }

    private func startLoopIfNeeded() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: self.cadence)
                guard !Task.isCancelled else { return }
                await self.refreshOnce()
            }
        }
    }

    // MARK: Refresh

    public func checkReportingNow() async {
        await refreshOnce()
    }

    private func seam(for gateway: FleetGateway) -> LiveOpsGatewaySeam? {
        if let existing = seams[gateway.id] { return existing }
        guard let built = factory(gateway) else { return nil }
        seams[gateway.id] = built
        return built
    }

    /// Resolve a control seam from the current fleet configuration. Detail
    /// actions can begin before the first asynchronous snapshot has populated
    /// the cache, so control authority must not depend on poll timing.
    private func seam(for operation: LiveOperation) -> LiveOpsGatewaySeam? {
        guard connectionStateProvider(operation.id.gatewayID) == .connected,
              let gateway = gatewaysProvider().first(where: { $0.id == operation.id.gatewayID }) else {
            return nil
        }
        return seam(for: gateway)
    }

    /// One coalesced refresh across every CONNECTED gateway, bounded to ≤3
    /// in flight. Disconnected gateways are folded in without a request.
    private func refreshOnce() async {
        guard !activeContexts.isEmpty else { return }
        cycle += 1
        let thisCycle = cycle
        let gateways = gatewaysProvider()
        guard !gateways.isEmpty else {
            snapshot = LiveOpsSnapshot(gateways: [])
            attentionItems = []
            attachedOperations.removeAll()
            return
        }

        let connected = gateways.filter { connectionStateProvider($0.id) == .connected }
        let disconnected = gateways.filter { connectionStateProvider($0.id) != .connected }

        let currentGatewayIDs = Set(gateways.map(\.id))
        let retained = snapshot.map { LiveOpsSnapshot(gateways: $0.gateways.filter { currentGatewayIDs.contains($0.gatewayID) }) }
        var working = retained
        for gateway in disconnected {
            let stamped = LiveOpsGatewaySnapshot(
                gatewayID: gateway.id, coverage: .disconnected, operations: [],
                observedAt: Date(), generation: thisCycle)
            working = LiveOpsSnapshotReducer.merge(incoming: stamped, into: working)
        }

        let results = await withTaskGroup(of: LiveOpsGatewaySnapshot.self) { group -> [LiveOpsGatewaySnapshot] in
            var iterator = connected.makeIterator()
            var collected: [LiveOpsGatewaySnapshot] = []
            func addNext() {
                guard let gateway = iterator.next() else { return }
                group.addTask { [weak self] in
                    guard let self else {
                        return LiveOpsGatewaySnapshot(
                            gatewayID: gateway.id, coverage: .disconnected, operations: [], observedAt: Date())
                    }
                    guard let seam = await self.seam(for: gateway) else {
                        return LiveOpsGatewaySnapshot(
                            gatewayID: gateway.id, coverage: .disconnected, operations: [], observedAt: Date())
                    }
                    return await seam.ops.snapshot(gateway: gateway.id)
                }
            }
            // Bounded concurrency: at most 3 gateways in flight at once.
            for _ in 0..<3 { addNext() }
            while let raw = await group.next() {
                collected.append(raw)
                addNext()
            }
            return collected
        }

        for raw in results {
            let stamped = LiveOpsGatewaySnapshot(
                gatewayID: raw.gatewayID, coverage: raw.coverage, operations: raw.operations,
                observedAt: raw.observedAt, generation: thisCycle, hasEverReported: raw.hasEverReported,
                observationNote: raw.observationNote, reportingSetup: raw.reportingSetup)
            working = LiveOpsSnapshotReducer.merge(incoming: stamped, into: working)
        }

        // Stale-cannot-overwrite-newer: only adopt this cycle's result if no
        // newer cycle has already completed while we were awaiting network.
        // `working` is non-nil here — `gateways` is non-empty (guarded
        // above), so at least one `merge` call above ran.
        guard thisCycle == cycle, let resolved = working else { return }
        snapshot = resolved
        let currentlyReportingIDs = Set(resolved.gateways
            .filter(\.coverage.isReporting)
            .flatMap(\.operations)
            .map(\.id))
        attachedOperations.formIntersection(currentlyReportingIDs)
        recordTimelineDiffs(newSnapshot: resolved)
        await refreshApprovalAttention(snapshot: resolved, connected: connected, cycle: thisCycle)
    }

    /// `approval.pending` ONLY for operations whose status is `.waiting` —
    /// never a fan-out over every session.
    private func refreshApprovalAttention(snapshot: LiveOpsSnapshot, connected: [FleetGateway], cycle: Int) async {
        var items: [LiveOpsAttentionItem] = []
        for gateway in connected {
            guard let gatewaySnapshot = snapshot.gateways.first(where: { $0.gatewayID == gateway.id }),
                  gatewaySnapshot.coverage.isReporting,
                  let seam = seams[gateway.id] else { continue }
            let waiting = gatewaySnapshot.operations.filter { $0.status.isWaiting }
            for operation in waiting {
                let pending = operation.observationOnly ? nil
                    : try? await seam.approvals.pendingApprovals(sessionID: operation.id.runtimeSessionID)
                guard cycle == self.cycle else { return }
                // Client-side redaction pass (the gateway also redacts); the
                // review sheet and inline preview both render this text.
                let redacted = pending?.first.map { request in
                    ApprovalRequest(
                        requestID: request.requestID,
                        sessionID: request.sessionID,
                        command: Redaction.commandPreview(request.command),
                        detail: request.detail,
                        choices: request.choices,
                        serverRequestID: request.serverRequestID)
                }
                items.append(LiveOpsAttentionItem(operation: operation, pendingApproval: redacted))
            }
        }
        // Key by gateway+operation (one row per waiting operation) — a
        // duplicate can never appear since we build the list fresh each
        // refresh from the current waiting set.
        guard cycle == self.cycle else { return }
        attentionItems = items
        // An item resolved elsewhere (approved/denied outside Fleet) simply
        // will not reappear here on the next refresh; clear any stale
        // resolving/error bookkeeping for requestIDs no longer pending.
        let stillPendingIDs = Set(items.compactMap(\.pendingApproval?.requestID))
        resolvingRequestIDs.formIntersection(stillPendingIDs)
        actionErrors = actionErrors.filter { stillPendingIDs.contains($0.key) }
        reviewTracker.retain(requestIDs: stillPendingIDs)
    }

    /// Lightweight diff of the previous vs. new snapshot for every operation
    /// currently under a `.detail` poll context — "live since you opened",
    /// not history.
    private func recordTimelineDiffs(newSnapshot: LiveOpsSnapshot) {
        let watchedIDs: Set<LiveOperationID> = Set(activeContexts.compactMap {
            if case .detail(let id) = $0 { return id }
            return nil
        })
        guard !watchedIDs.isEmpty else {
            lastOperationsByID = Dictionary(uniqueKeysWithValues: newSnapshot.allOperations.map { ($0.id, $0) })
            return
        }
        let now = Date()
        for id in watchedIDs {
            guard let current = newSnapshot.allOperations.first(where: { $0.id == id }) else { continue }
            guard let previous = lastOperationsByID[id] else { continue }
            var entries: [String] = []
            if previous.status != current.status {
                entries.append("Status: \(previous.status.wireValue) → \(current.status.wireValue)")
            }
            let previousSubs = previous.subagents ?? []
            let currentSubs = current.subagents ?? []
            let previousIDs = Set(previousSubs.map(\.subagentID))
            let currentIDs = Set(currentSubs.map(\.subagentID))
            for started in currentIDs.subtracting(previousIDs) {
                if let sub = currentSubs.first(where: { $0.subagentID == started }) {
                    entries.append("Subagent started: \(sub.goal.isEmpty ? sub.subagentID : sub.goal)")
                }
            }
            for finished in previousIDs.subtracting(currentIDs) {
                if let sub = previousSubs.first(where: { $0.subagentID == finished }) {
                    entries.append("Subagent finished: \(sub.goal.isEmpty ? sub.subagentID : sub.goal)")
                }
            }
            for currentSub in currentSubs {
                if let previousSub = previousSubs.first(where: { $0.subagentID == currentSub.subagentID }),
                   currentSub.toolCount > previousSub.toolCount {
                    entries.append("\(currentSub.goal.isEmpty ? currentSub.subagentID : currentSub.goal): \(currentSub.toolCount) tools")
                }
            }
            guard !entries.isEmpty else { continue }
            var existing = timelines[id] ?? []
            existing.append(contentsOf: entries.map { OperationTimelineEntry(at: now, text: $0) })
            timelines[id] = existing
        }
        lastOperationsByID = Dictionary(uniqueKeysWithValues: newSnapshot.allOperations.map { ($0.id, $0) })
    }

    // MARK: Derived, display-safe coverage copy

    /// `nil` when coverage is complete and there's nothing to caveat.
    public var coverageCaveat: String? {
        guard let snapshot, !snapshot.gateways.isEmpty else { return nil }
        let total = snapshot.gateways.count
        let reporting = snapshot.gateways.filter { $0.coverage.isReporting }
        let unsupported = snapshot.gateways.filter { $0.coverage == .unsupported }
        let namesByID = Dictionary(uniqueKeysWithValues: gatewaysProvider().map { ($0.id, $0.displayName) })

        if reporting.count == total {
            if unsupported.isEmpty { return nil }
            // Reporting-but-unsupported never happens (unsupported is itself
            // a non-reporting coverage state) — defensive, unreachable.
            return nil
        }
        let nonReporting = snapshot.gateways.filter { !$0.coverage.isReporting }
        if nonReporting.count == 1, case .unsupported = nonReporting[0].coverage {
            return "1 gateway uses limited activity reporting"
        }
        if nonReporting.count == unsupported.count, unsupported.count > 1 {
            return "\(unsupported.count) gateways use limited activity reporting"
        }
        if nonReporting.count == 1 {
            let name = namesByID[nonReporting[0].gatewayID] ?? nonReporting[0].gatewayID.rawValue
            return "Live Ops unavailable from \(name)"
        }
        return "\(reporting.count) of \(total) gateways reporting Live Ops"
    }

    /// True when a gateway's CURRENT refresh is not reporting but its
    /// operations are last-good held-over data (the reducer's rule 2) — the
    /// UI must mark these stale, never "live Working".
    public func isStale(_ operation: LiveOperation) -> Bool {
        guard let gatewaySnapshot = snapshot?.gateways.first(where: { $0.gatewayID == operation.id.gatewayID }) else {
            return false
        }
        return !gatewaySnapshot.coverage.isReporting
    }

    public func lastReportedAt(_ operation: LiveOperation) -> Date? {
        snapshot?.gateways.first(where: { $0.gatewayID == operation.id.gatewayID })?.observedAt
    }

    // MARK: Approvals from Home (reuses the ApprovalsProviding seam)

    /// APPROVE — biometric-gated, identical gate to the conversation
    /// approval banner (`ApprovalViewModel.approve`). Returns a non-secret
    /// error message on failure, `nil` on success. The row is removed from
    /// `attentionItems` only after the gateway has acknowledged — never
    /// optimistically before that.
    @discardableResult
    public func approve(_ item: LiveOpsAttentionItem, choice: ApprovalChoice = .once) async -> String? {
        guard let approval = item.pendingApproval else { return "no pending approval" }
        guard let seam = seams[item.operation.id.gatewayID] else { return "gateway not reachable" }
        // P0.2a: same review gate as the conversation banner, checked before
        // the biometric prompt. Deny is never gated.
        guard reviewTracker.canApprove(approval) else {
            actionErrors[approval.requestID] = Self.reviewRequiredMessage
            return Self.reviewRequiredMessage
        }
        guard !resolvingRequestIDs.contains(approval.requestID) else { return nil }
        resolvingRequestIDs.insert(approval.requestID)
        defer { resolvingRequestIDs.remove(approval.requestID) }
        // Same presence gate + passcode fallback as the conversation banner.
        guard let action = PresenceAction(approvalChoice: choice) else { return "deny is not gated" }
        let presence = await biometrics.verifyPresence(action)
        if let message = PresenceFeedback.message(for: presence, action: action) {
            actionErrors[approval.requestID] = message
            return message
        }
        do {
            _ = try await seam.approvals.respond(
                sessionID: approval.sessionID, requestID: approval.requestID, choice: choice, all: false)
            attentionItems.removeAll { $0.pendingApproval?.requestID == approval.requestID }
            actionErrors[approval.requestID] = nil
            return nil
        } catch {
            let message = Redaction.safeErrorDescription(error)
            actionErrors[approval.requestID] = message
            return message
        }
    }

    /// Whether Approve is allowed for this row right now (short command, or the
    /// long command has been reviewed in full).
    public func canApprove(_ item: LiveOpsAttentionItem) -> Bool {
        guard let approval = item.pendingApproval else { return false }
        return reviewTracker.canApprove(approval)
    }

    /// The user finished reviewing this row's full command.
    public func markReviewed(_ item: LiveOpsAttentionItem) {
        guard let approval = item.pendingApproval else { return }
        reviewTracker.markReviewed(approval)
        if actionErrors[approval.requestID] == Self.reviewRequiredMessage {
            actionErrors[approval.requestID] = nil
        }
    }

    /// The header for a Home approval row. Live Ops carries the gateway and
    /// session title but not the bot or working folder, so those honestly
    /// read "unknown" here instead of being left out.
    public func origin(for item: LiveOpsAttentionItem, gatewayLabel: String?) -> ApprovalOrigin {
        ApprovalOrigin(
            gateway: gatewayLabel,
            bot: nil,
            cwd: nil,
            session: ApprovalOrigin.sessionLabel(
                title: item.operation.title, id: item.operation.id.runtimeSessionID))
    }

    /// DENY — friction-free, no biometrics (matches the conversation banner
    /// security posture: the safe answer is always the easy one).
    @discardableResult
    public func deny(_ item: LiveOpsAttentionItem) async -> String? {
        guard let approval = item.pendingApproval else { return "no pending approval" }
        guard let seam = seams[item.operation.id.gatewayID] else { return "gateway not reachable" }
        guard !resolvingRequestIDs.contains(approval.requestID) else { return nil }
        resolvingRequestIDs.insert(approval.requestID)
        defer { resolvingRequestIDs.remove(approval.requestID) }
        do {
            _ = try await seam.approvals.respond(
                sessionID: approval.sessionID, requestID: approval.requestID, choice: .deny, all: false)
            attentionItems.removeAll { $0.pendingApproval?.requestID == approval.requestID }
            actionErrors[approval.requestID] = nil
            return nil
        } catch {
            let message = Redaction.safeErrorDescription(error)
            actionErrors[approval.requestID] = message
            return message
        }
    }

    // MARK: Operation Detail — child controls (attached-session only)

    /// Proves transport authority for this operation by calling
    /// `subagent.list`. Populates `attachedOperations` on success; leaves it
    /// absent on `.notAttached` (or any other failure) — Operation Detail
    /// then shows "Open the chat to control subagents" instead of guessing.
    public func verifyAttachment(_ operation: LiveOperation) async {
        guard activeContexts.contains(.detail(operation.id)),
              let seam = seam(for: operation) else {
            attachedOperations.remove(operation.id)
            return
        }
        do {
            _ = try await seam.ops.listSubagents(sessionID: operation.sessionKey)
            guard activeContexts.contains(.detail(operation.id)) else {
                attachedOperations.remove(operation.id)
                return
            }
            attachedOperations.insert(operation.id)
        } catch {
            attachedOperations.remove(operation.id)
        }
    }

    public func steer(subagentID: String, operation: LiveOperation, text: String) async -> Result<LiveOpsSteerResult, LiveOpsControlError> {
        guard attachedOperations.contains(operation.id) else { return .failure(.notAttached) }
        guard let seam = seam(for: operation) else { return .failure(.notConnected) }
        do {
            return .success(try await seam.ops.steer(subagentID: subagentID, sessionID: operation.sessionKey, text: text))
        } catch let error as LiveOpsControlError {
            return .failure(error)
        } catch {
            return .failure(.rpcFailed(Redaction.safeErrorDescription(error)))
        }
    }

    /// `found: false` reads as "Subagent already finished" per the wire
    /// contract — this returns the raw bool; the view owns that copy.
    public func interruptChild(subagentID: String, operation: LiveOperation) async -> Result<Bool, LiveOpsControlError> {
        guard attachedOperations.contains(operation.id) else { return .failure(.notAttached) }
        guard let seam = seam(for: operation) else { return .failure(.notConnected) }
        do {
            return .success(try await seam.ops.interrupt(subagentID: subagentID, sessionID: operation.sessionKey))
        } catch let error as LiveOpsControlError {
            return .failure(error)
        } catch {
            return .failure(.rpcFailed(Redaction.safeErrorDescription(error)))
        }
    }
}
