import XCTest
import FleetCore
import FleetUI
@testable import HermesFleetApp

/// Live Ops v1 (Build 91, Worker B) — `LiveOpsStore` polling discipline,
/// attention-item derivation, and the Home approve/deny flow. Mirrors the
/// scripted-double style of `ApprovalFlowTests`.
@MainActor
final class LiveOpsStoreTests: XCTestCase {

    // MARK: - Scripted seams

    private final class ScriptedOps: LiveOpsProviding, LiveOpsSubagentControlling, @unchecked Sendable {
        let gatewayID: GatewayID
        var coverage: LiveOpsGatewayCoverage = .reporting
        var operations: [LiveOperation] = []
        private let lock = NSLock()
        private var _snapshotCallCount = 0
        var snapshotCallCount: Int { lock.lock(); defer { lock.unlock() }; return _snapshotCallCount }
        private var _controlSessionIDs: [String] = []
        var controlSessionIDs: [String] { lock.lock(); defer { lock.unlock() }; return _controlSessionIDs }
        var listSubagentsResult: Result<[LiveOpsSubagent], LiveOpsControlError> = .failure(.notAttached)

        init(gatewayID: GatewayID) { self.gatewayID = gatewayID }

        // NSLock's lock()/unlock() are unavailable directly inside an async
        // function body (Swift 6) — route through a synchronous helper.
        private func recordSnapshotCall() {
            lock.lock(); defer { lock.unlock() }
            _snapshotCallCount += 1
        }
        private func recordControlSession(_ sessionID: String) {
            lock.lock(); defer { lock.unlock() }
            _controlSessionIDs.append(sessionID)
        }

        func snapshot(gateway: GatewayID) async -> LiveOpsGatewaySnapshot {
            recordSnapshotCall()
            return LiveOpsGatewaySnapshot(gatewayID: gatewayID, coverage: coverage, operations: operations, observedAt: Date())
        }

        func listSubagents(sessionID: String) async throws -> [LiveOpsSubagent] {
            recordControlSession(sessionID)
            return try listSubagentsResult.get()
        }
        func tail(subagentID: String, sessionID: String) async throws -> LiveOpsSubagentTail {
            LiveOpsSubagentTail(available: false, text: "", truncated: false)
        }
        var steerResult: Result<LiveOpsSteerResult, LiveOpsControlError> = .success(.queued)
        func steer(subagentID: String, sessionID: String, text: String) async throws -> LiveOpsSteerResult {
            recordControlSession(sessionID)
            return try steerResult.get()
        }
        func interrupt(subagentID: String, sessionID: String) async throws -> Bool {
            recordControlSession(sessionID)
            return true
        }
    }

    private final class ScriptedApprovals: ApprovalsProviding, @unchecked Sendable {
        let lock = NSLock()
        var pendingByBoolSession: [String: [ApprovalRequest]] = [:]
        private var _pendingCallSessions: [String] = []
        var pendingCallSessions: [String] { lock.lock(); defer { lock.unlock() }; return _pendingCallSessions }
        var scriptedPendingResponses: [[ApprovalRequest]]?
        var delayFirstPendingResponse = false
        private var _respondCalls: [(sessionID: String, requestID: String, choice: ApprovalChoice)] = []
        var respondCalls: [(sessionID: String, requestID: String, choice: ApprovalChoice)] {
            lock.lock(); defer { lock.unlock() }; return _respondCalls
        }
        var respondResult: Result<Int, Error> = .success(1)

        private func recordRespond(_ sessionID: String, _ requestID: String, _ choice: ApprovalChoice) {
            lock.lock(); defer { lock.unlock() }
            _respondCalls.append((sessionID, requestID, choice))
        }
        private func recordPending(_ sessionID: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            _pendingCallSessions.append(sessionID)
            return _pendingCallSessions.count
        }

        func respond(sessionID: String, requestID: String, choice: ApprovalChoice, all: Bool) async throws -> Int {
            recordRespond(sessionID, requestID, choice)
            return try respondResult.get()
        }
        func setSessionYolo(_ enabled: Bool, sessionID: String) async throws -> Bool { false }
        func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] {
            let callIndex = recordPending(sessionID)
            if callIndex == 1, delayFirstPendingResponse {
                try? await Task.sleep(for: .milliseconds(300))
            }
            if let scriptedPendingResponses, callIndex <= scriptedPendingResponses.count {
                return scriptedPendingResponses[callIndex - 1]
            }
            return pendingByBoolSession[sessionID] ?? []
        }
    }

    private struct ScriptedBiometrics: AppLockBiometricAuth {
        let result: AppLockAuthResult
        func canEvaluateBiometrics() -> Bool { result != .unavailable }
        func evaluateBiometrics(reason: String) async -> AppLockAuthResult { result }
        func evaluateDevicePasscode(reason: String) async -> Bool { false }
    }

    private let gatewayA = GatewayID(rawValue: "gw-a")
    private let gatewayB = GatewayID(rawValue: "gw-b")

    private func makeOperation(
        gatewayID: GatewayID, runtimeID: String, status: LiveOperationStatus, subagents: [LiveOpsSubagent]? = []
    ) -> LiveOperation {
        LiveOperation(
            id: LiveOperationID(gatewayID: gatewayID, runtimeSessionID: runtimeID),
            sessionKey: "key-\(runtimeID)", title: "Op \(runtimeID)", preview: "preview",
            model: "claude-opus", startedAt: Date(timeIntervalSince1970: 1_000), lastActive: Date(),
            messageCount: 1, status: status, subagents: subagents)
    }

    private func makeStore(
        ops: [GatewayID: ScriptedOps], approvals: [GatewayID: ScriptedApprovals],
        gateways: [FleetGateway], biometricResult: AppLockAuthResult = .success
    ) -> LiveOpsStore {
        let store = LiveOpsStore(
            factory: { gateway in
                guard let op = ops[gateway.id], let approval = approvals[gateway.id] else { return nil }
                return LiveOpsGatewaySeam(ops: op, approvals: approval)
            },
            biometrics: ScriptedBiometrics(result: biometricResult)
        )
        store.setProviders(gateways: { gateways }, connectionState: { _ in .connected })
        return store
    }

    // MARK: - Polling only while visible

    func testNoRefreshWithoutAnObserver() async throws {
        let ops = ScriptedOps(gatewayID: gatewayA)
        let store = makeStore(
            ops: [gatewayA: ops], approvals: [gatewayA: ScriptedApprovals()],
            gateways: [FleetGateway(id: gatewayA, displayName: "A", endpoint: nil)])
        // No beginObserving call at all — give the (nonexistent) loop a
        // chance to fire before asserting nothing happened.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(ops.snapshotCallCount, 0, "must never poll with zero registered observers")
        _ = store // silence unused warning if optimized away
    }

    func testBeginObservingTriggersAnImmediateRefresh() async {
        let ops = ScriptedOps(gatewayID: gatewayA)
        let store = makeStore(
            ops: [gatewayA: ops], approvals: [gatewayA: ScriptedApprovals()],
            gateways: [FleetGateway(id: gatewayA, displayName: "A", endpoint: nil)])
        store.beginObserving(.home)
        // Poll for the async refresh to land (bounded wait, no fixed sleep race).
        for _ in 0..<50 where ops.snapshotCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(ops.snapshotCallCount, 0, "opening Home must kick an immediate refresh")
        store.endObserving(.home)
    }

    // MARK: - Only connected gateways are asked

    func testDisconnectedGatewayNeverPolledButFoldedInAsDisconnected() async {
        let ops = ScriptedOps(gatewayID: gatewayA)
        let store = LiveOpsStore(
            factory: { gateway in LiveOpsGatewaySeam(ops: ops, approvals: ScriptedApprovals()) },
            biometrics: ScriptedBiometrics(result: .success))
        store.setProviders(
            gateways: { [FleetGateway(id: self.gatewayA, displayName: "A", endpoint: nil)] },
            connectionState: { _ in .disconnected })
        store.beginObserving(.home)
        for _ in 0..<50 where store.snapshot == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(ops.snapshotCallCount, 0, "a disconnected gateway must never be asked")
        XCTAssertEqual(store.snapshot?.gateways.first?.coverage, .disconnected)
        store.endObserving(.home)
    }

    // MARK: - approval.pending only for waiting sessions

    func testApprovalPendingOnlyFetchedForWaitingOperations() async {
        let ops = ScriptedOps(gatewayID: gatewayA)
        ops.operations = [
            makeOperation(gatewayID: gatewayA, runtimeID: "working-1", status: .working),
            makeOperation(gatewayID: gatewayA, runtimeID: "waiting-1", status: .waiting),
            makeOperation(gatewayID: gatewayA, runtimeID: "idle-1", status: .idle),
        ]
        let approvals = ScriptedApprovals()
        let store = makeStore(
            ops: [gatewayA: ops], approvals: [gatewayA: approvals],
            gateways: [FleetGateway(id: gatewayA, displayName: "A", endpoint: nil)])
        store.beginObserving(.home)
        for _ in 0..<50 where approvals.pendingCallSessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(approvals.pendingCallSessions, ["waiting-1"],
                       "must query approval.pending ONLY for the waiting session, never working/idle")
        store.endObserving(.home)
    }

    // MARK: - Partial coverage never renders zero

    func testPartialCoverageCaveatWhenOneGatewayNeverReported() async {
        let opsA = ScriptedOps(gatewayID: gatewayA)
        opsA.operations = [makeOperation(gatewayID: gatewayA, runtimeID: "r1", status: .working)]
        let opsB = ScriptedOps(gatewayID: gatewayB)
        opsB.coverage = .failed(reason: "boom")
        let store = makeStore(
            ops: [gatewayA: opsA, gatewayB: opsB],
            approvals: [gatewayA: ScriptedApprovals(), gatewayB: ScriptedApprovals()],
            gateways: [
                FleetGateway(id: gatewayA, displayName: "Alpha", endpoint: nil),
                FleetGateway(id: gatewayB, displayName: "Beta", endpoint: nil),
            ])
        store.beginObserving(.home)
        for _ in 0..<50 where store.snapshot == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Give the second gateway's response a moment to land too.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.snapshot?.activeCount, .known(1), "gateway A's real active op still counts")
        XCTAssertNotNil(store.coverageCaveat, "an incomplete fleet must state its caveat, never silently look complete")
        store.endObserving(.home)
    }

    func testUnsupportedGatewayGetsNeutralLimitedReportingCopy() async {
        let opsA = ScriptedOps(gatewayID: gatewayA)
        let opsB = ScriptedOps(gatewayID: gatewayB)
        opsB.coverage = .unsupported
        let store = makeStore(
            ops: [gatewayA: opsA, gatewayB: opsB],
            approvals: [gatewayA: ScriptedApprovals(), gatewayB: ScriptedApprovals()],
            gateways: [
                FleetGateway(id: gatewayA, displayName: "Alpha", endpoint: nil),
                FleetGateway(id: gatewayB, displayName: "Beta", endpoint: nil),
            ])
        store.beginObserving(.home)
        for _ in 0..<50 where store.snapshot == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.coverageCaveat, "1 gateway uses limited activity reporting")
        store.endObserving(.home)
    }

    // MARK: - Approve / deny

    func testApproveRequiresBiometricSuccessAndRemovesRowOnlyAfterAck() async {
        let ops = ScriptedOps(gatewayID: gatewayA)
        let operation = makeOperation(gatewayID: gatewayA, runtimeID: "r1", status: .waiting)
        ops.operations = [operation]
        let approval = ApprovalRequest(requestID: "req-1", sessionID: "r1", command: "ls", detail: nil, choices: ["once", "deny"])
        let approvals = ScriptedApprovals()
        approvals.pendingByBoolSession = ["r1": [approval]]
        let store = makeStore(
            ops: [gatewayA: ops], approvals: [gatewayA: approvals],
            gateways: [FleetGateway(id: gatewayA, displayName: "A", endpoint: nil)],
            biometricResult: .success)
        store.beginObserving(.home)
        for _ in 0..<50 where store.attentionItems.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.attentionItems.count, 1)
        let item = store.attentionItems[0]
        XCTAssertNotNil(item.pendingApproval)

        let error = await store.approve(item)
        XCTAssertNil(error)
        XCTAssertEqual(approvals.respondCalls.count, 1)
        XCTAssertEqual(approvals.respondCalls.first?.choice, .once)
        XCTAssertTrue(store.attentionItems.isEmpty, "removed only after the gateway acknowledged")
        store.endObserving(.home)
    }

    func testApproveBlockedWithoutBiometricSuccess() async {
        let ops = ScriptedOps(gatewayID: gatewayA)
        let operation = makeOperation(gatewayID: gatewayA, runtimeID: "r1", status: .waiting)
        ops.operations = [operation]
        let approval = ApprovalRequest(requestID: "req-1", sessionID: "r1", command: "ls", detail: nil, choices: ["once", "deny"])
        let approvals = ScriptedApprovals()
        approvals.pendingByBoolSession = ["r1": [approval]]
        let store = makeStore(
            ops: [gatewayA: ops], approvals: [gatewayA: approvals],
            gateways: [FleetGateway(id: gatewayA, displayName: "A", endpoint: nil)],
            biometricResult: .failure)
        store.beginObserving(.home)
        for _ in 0..<50 where store.attentionItems.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let item = store.attentionItems[0]
        let error = await store.approve(item)
        XCTAssertNotNil(error)
        XCTAssertTrue(approvals.respondCalls.isEmpty, "approve must never reach the wire without biometric success")
        store.endObserving(.home)
    }

    func testDenyNeverRequiresBiometrics() async {
        let ops = ScriptedOps(gatewayID: gatewayA)
        let operation = makeOperation(gatewayID: gatewayA, runtimeID: "r1", status: .waiting)
        ops.operations = [operation]
        let approval = ApprovalRequest(requestID: "req-1", sessionID: "r1", command: "ls", detail: nil, choices: ["once", "deny"])
        let approvals = ScriptedApprovals()
        approvals.pendingByBoolSession = ["r1": [approval]]
        let store = makeStore(
            ops: [gatewayA: ops], approvals: [gatewayA: approvals],
            gateways: [FleetGateway(id: gatewayA, displayName: "A", endpoint: nil)],
            biometricResult: .unavailable)
        store.beginObserving(.home)
        for _ in 0..<50 where store.attentionItems.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let item = store.attentionItems[0]
        let error = await store.deny(item)
        XCTAssertNil(error)
        XCTAssertEqual(approvals.respondCalls.first?.choice, .deny)
        store.endObserving(.home)
    }

    func testResolvedElsewhereRemovesRowOnNextRefresh() async {
        let ops = ScriptedOps(gatewayID: gatewayA)
        let operation = makeOperation(gatewayID: gatewayA, runtimeID: "r1", status: .waiting)
        ops.operations = [operation]
        let approval = ApprovalRequest(requestID: "req-1", sessionID: "r1", command: "ls", detail: nil, choices: ["once", "deny"])
        let approvals = ScriptedApprovals()
        approvals.pendingByBoolSession = ["r1": [approval]]
        let store = makeStore(
            ops: [gatewayA: ops], approvals: [gatewayA: approvals],
            gateways: [FleetGateway(id: gatewayA, displayName: "A", endpoint: nil)])
        store.beginObserving(.home)
        for _ in 0..<50 where store.attentionItems.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(store.attentionItems.isEmpty)
        // Someone else resolved it — the seam now reports no pending approval.
        approvals.pendingByBoolSession = ["r1": []]
        let before = approvals.pendingCallSessions.count
        // Home polls every five seconds; allow one full scheduled cycle.
        for _ in 0..<350 where approvals.pendingCallSessions.count <= before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Allow one more scheduled tick to fully settle attentionItems.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.attentionItems.allSatisfy { $0.pendingApproval == nil },
                      "an item resolved elsewhere must not keep showing a stale Approve button")
        store.endObserving(.home)
    }

    func testOlderApprovalRefreshCannotRestoreResolvedRequest() async {
        let ops = ScriptedOps(gatewayID: gatewayA)
        ops.operations = [makeOperation(gatewayID: gatewayA, runtimeID: "r1", status: .waiting)]
        let approval = ApprovalRequest(requestID: "req-old", sessionID: "r1", command: "ls", detail: nil, choices: ["once", "deny"])
        let approvals = ScriptedApprovals()
        approvals.scriptedPendingResponses = [[approval], []]
        approvals.delayFirstPendingResponse = true
        let store = makeStore(
            ops: [gatewayA: ops], approvals: [gatewayA: approvals],
            gateways: [FleetGateway(id: gatewayA, displayName: "A", endpoint: nil)])

        store.beginObserving(.home)
        for _ in 0..<50 where approvals.pendingCallSessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(approvals.pendingCallSessions.count, 1)

        // Start a newer detail refresh while the first approval.pending call
        // is suspended. The newer cycle observes the resolved state first.
        store.beginObserving(.detail(LiveOperationID(gatewayID: gatewayA, runtimeSessionID: "r1")))
        for _ in 0..<50 where approvals.pendingCallSessions.count < 2 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(approvals.pendingCallSessions.count, 2)
        for _ in 0..<50 where store.attentionItems.first?.pendingApproval != nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(350)) // Let the older call return.
        XCTAssertTrue(store.attentionItems.allSatisfy { $0.pendingApproval == nil })

        store.endObserving(.detail(LiveOperationID(gatewayID: gatewayA, runtimeSessionID: "r1")))
        store.endObserving(.home)
    }

    // MARK: - Child controls gated on attachment

    func testChildControlsHiddenWhenNotAttached() async {
        let ops = ScriptedOps(gatewayID: gatewayA)
        ops.listSubagentsResult = .failure(.notAttached)
        let operation = makeOperation(gatewayID: gatewayA, runtimeID: "r1", status: .working)
        let store = makeStore(
            ops: [gatewayA: ops], approvals: [gatewayA: ScriptedApprovals()],
            gateways: [FleetGateway(id: gatewayA, displayName: "A", endpoint: nil)])
        store.beginObserving(.detail(operation.id))
        await store.verifyAttachment(operation)
        XCTAssertFalse(store.attachedOperations.contains(operation.id))
        store.endObserving(.detail(operation.id))
    }

    func testChildControlsShownWhenAttached() async {
        let ops = ScriptedOps(gatewayID: gatewayA)
        ops.listSubagentsResult = .success([])
        let operation = makeOperation(gatewayID: gatewayA, runtimeID: "r1", status: .working)
        let store = makeStore(
            ops: [gatewayA: ops], approvals: [gatewayA: ScriptedApprovals()],
            gateways: [FleetGateway(id: gatewayA, displayName: "A", endpoint: nil)])
        store.beginObserving(.detail(operation.id))
        await store.verifyAttachment(operation)
        XCTAssertTrue(store.attachedOperations.contains(operation.id))
        XCTAssertEqual(ops.controlSessionIDs, [operation.sessionKey], "controls must use the durable session key")
        store.endObserving(.detail(operation.id))
    }

    // MARK: - Steer copy: queued vs rejected

    func testSteerQueuedVsRejected() async {
        let ops = ScriptedOps(gatewayID: gatewayA)
        ops.listSubagentsResult = .success([])
        let operation = makeOperation(gatewayID: gatewayA, runtimeID: "r1", status: .working)
        let store = makeStore(
            ops: [gatewayA: ops], approvals: [gatewayA: ScriptedApprovals()],
            gateways: [FleetGateway(id: gatewayA, displayName: "A", endpoint: nil)])
        store.beginObserving(.detail(operation.id))
        await store.verifyAttachment(operation)
        XCTAssertEqual(ops.controlSessionIDs, [operation.sessionKey])

        ops.steerResult = .success(.queued)
        let queuedResult = await store.steer(subagentID: "sub-1", operation: operation, text: "hi")
        guard case .success(.queued) = queuedResult else { return XCTFail("expected queued") }

        ops.steerResult = .success(.rejected)
        let rejectedResult = await store.steer(subagentID: "sub-1", operation: operation, text: "hi")
        guard case .success(.rejected) = rejectedResult else { return XCTFail("expected rejected") }
        XCTAssertEqual(ops.controlSessionIDs, Array(repeating: operation.sessionKey, count: 3))
        store.endObserving(.detail(operation.id))
    }
}
