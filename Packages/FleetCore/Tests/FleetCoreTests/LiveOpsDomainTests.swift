import XCTest
@testable import FleetCore

/// Live Ops v1 domain: source-qualified identity, status vocabulary,
/// aggregation/coverage honesty, the stale/failed-refresh reducer rules, and
/// swarm-tree correlation. Wire ground truth is documented at the top of
/// `LiveOps.swift` (hermes-agent origin/main 6636b08).
final class LiveOpsDomainTests: XCTestCase {

    func testReportingSetupRequiredIsVisibleEvenWhenLegacyRPCIsUnsupported() {
        let gateway = GatewayID(rawValue: "setup-fixture")
        let missing = LiveOpsGatewaySnapshot(gatewayID: gateway, coverage: .unsupported,
            operations: [], observedAt: Date(), reportingSetup: .required)
        XCTAssertFalse(missing.hasEverReported)
        XCTAssertEqual(missing.reportingSetup, .required)
        let recovered = LiveOpsGatewaySnapshot(gatewayID: gateway, coverage: .reporting,
            operations: [], observedAt: Date(), generation: 1, reportingSetup: .reporting(backends: 2))
        let merged = LiveOpsSnapshotReducer.merge(incoming: recovered, into: LiveOpsSnapshot(gateways: [missing]))
        XCTAssertEqual(merged.gateways.first?.reportingSetup, .reporting(backends: 2))
        XCTAssertTrue(merged.isCoverageComplete)
    }

    func testReportingSetupRetainsDetectionAcrossDisconnectButExplicitFailureSupersedesIt() {
        let gateway = GatewayID(rawValue: "setup-fixture")
        let ready = LiveOpsGatewaySnapshot(gatewayID: gateway, coverage: .reporting,
            operations: [], observedAt: Date(), reportingSetup: .reporting(backends: 2))
        let offline = LiveOpsGatewaySnapshot(gatewayID: gateway, coverage: .disconnected,
            operations: [], observedAt: Date(), generation: 1)
        let merged = LiveOpsSnapshotReducer.merge(incoming: offline, into: LiveOpsSnapshot(gateways: [ready]))
        XCTAssertEqual(merged.gateways.first?.reportingSetup, .reporting(backends: 2))
        XCTAssertFalse(merged.isCoverageComplete)
        let stalled = LiveOpsGatewaySnapshot(gatewayID: gateway, coverage: .failed(reason: "Reporter stalled"),
            operations: [], observedAt: Date(), generation: 2, reportingSetup: .unavailable)
        XCTAssertEqual(LiveOpsSnapshotReducer.merge(incoming: stalled, into: merged).gateways.first?.reportingSetup, .unavailable)
    }

    // MARK: identity

    func testSameRuntimeSidOnTwoGatewaysDoesNotCollide() {
        let a = LiveOperationID(gatewayID: GatewayID(rawValue: "gw-a"), runtimeSessionID: "sid-1")
        let b = LiveOperationID(gatewayID: GatewayID(rawValue: "gw-b"), runtimeSessionID: "sid-1")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.description, b.description)
    }

    func testSameGatewayAndSidIsEqual() {
        let a = LiveOperationID(gatewayID: GatewayID(rawValue: "gw-a"), runtimeSessionID: "sid-1")
        let b = LiveOperationID(gatewayID: GatewayID(rawValue: "gw-a"), runtimeSessionID: "sid-1")
        XCTAssertEqual(a, b)
    }

    // MARK: status vocabulary

    func testKnownStatusesDecodeExactly() {
        XCTAssertEqual(LiveOperationStatus(wireValue: "idle"), .idle)
        XCTAssertEqual(LiveOperationStatus(wireValue: "starting"), .starting)
        XCTAssertEqual(LiveOperationStatus(wireValue: "waiting"), .waiting)
        XCTAssertEqual(LiveOperationStatus(wireValue: "working"), .working)
    }

    func testUnknownStatusDecodesToUnknownNeverCrashesNeverBecomesWorking() {
        let status = LiveOperationStatus(wireValue: "blocked_on_billing")
        guard case .unknown(let raw) = status else {
            return XCTFail("expected .unknown, got \(status)")
        }
        XCTAssertEqual(raw, "blocked_on_billing")
        XCTAssertEqual(status.wireValue, "blocked_on_billing")
        XCTAssertFalse(status.isActive, "an unrecognized future status must not be counted as active")
        XCTAssertFalse(status.isWaiting)
    }

    func testActiveIsWorkingStartingOrWaitingOnlyIdleExcluded() {
        XCTAssertTrue(LiveOperationStatus.working.isActive)
        XCTAssertTrue(LiveOperationStatus.starting.isActive)
        XCTAssertTrue(LiveOperationStatus.waiting.isActive)
        XCTAssertFalse(LiveOperationStatus.idle.isActive)
    }

    func testWaitingOnlyTrueForWaiting() {
        XCTAssertTrue(LiveOperationStatus.waiting.isWaiting)
        XCTAssertFalse(LiveOperationStatus.working.isWaiting)
        XCTAssertFalse(LiveOperationStatus.idle.isWaiting)
        XCTAssertFalse(LiveOperationStatus.starting.isWaiting)
    }

    // MARK: LiveOperation / subagentsKnown

    private func makeOperation(
        sid: String = "sid-1",
        gatewayID: String = "gw-a",
        status: LiveOperationStatus = .working,
        subagents: [LiveOpsSubagent]? = nil
    ) -> LiveOperation {
        LiveOperation(
            id: LiveOperationID(gatewayID: GatewayID(rawValue: gatewayID), runtimeSessionID: sid),
            sessionKey: "durable-\(sid)",
            title: "Fixture session",
            preview: "doing fixture work",
            model: "fixture-model",
            startedAt: Date(timeIntervalSince1970: 1000),
            lastActive: Date(timeIntervalSince1970: 2000),
            messageCount: 3,
            status: status,
            subagents: subagents
        )
    }

    func testSubagentsKnownDistinguishesNilFromEmpty() {
        XCTAssertFalse(makeOperation(subagents: nil).subagentsKnown)
        XCTAssertTrue(makeOperation(subagents: []).subagentsKnown)
    }

    func testIdleParentWithRunningChildCountsAsActive() {
        let child = LiveOpsSubagent(subagentID: "child", parentID: nil, depth: 0,
                                   goal: "Synthetic task", model: nil, startedAt: Date(),
                                   status: "running", toolCount: 0)
        let operation = makeOperation(status: .idle, subagents: [child])
        XCTAssertTrue(operation.isActive)
        XCTAssertTrue(operation.isDelegating)
        let gateway = LiveOpsGatewaySnapshot(gatewayID: operation.id.gatewayID,
                                            coverage: .reporting, operations: [operation], observedAt: Date())
        XCTAssertEqual(LiveOpsSnapshot(gateways: [gateway]).activeCount.value, 1)
        XCTAssertFalse(makeOperation(status: .idle, subagents: []).isActive)
        XCTAssertFalse(makeOperation(status: .idle, subagents: nil).isActive)
    }

    func testUnknownChildStatusDoesNotFabricateActivity() {
        let child = LiveOpsSubagent(subagentID: "child", parentID: nil, depth: 0,
                                   goal: "Synthetic task", model: nil, startedAt: Date(),
                                   status: "future-state", toolCount: 0)
        XCTAssertFalse(makeOperation(status: .idle, subagents: [child]).isActive)
    }

    func testSwarmTreeNilWhenSubagentsUnknown() {
        XCTAssertNil(makeOperation(subagents: nil).swarmTree)
    }

    // MARK: gateway coverage

    func testCoverageIsReportingOnlyForReportingCase() {
        XCTAssertTrue(LiveOpsGatewayCoverage.reporting.isReporting)
        XCTAssertFalse(LiveOpsGatewayCoverage.unsupported.isReporting)
        XCTAssertFalse(LiveOpsGatewayCoverage.disconnected.isReporting)
        XCTAssertFalse(LiveOpsGatewayCoverage.authFailed.isReporting)
        XCTAssertFalse(LiveOpsGatewayCoverage.failed(reason: "boom").isReporting)
    }

    // MARK: aggregation / partial coverage honesty

    func testEmptySnapshotCountsArePartialNeverZero() {
        let snapshot = LiveOpsSnapshot(gateways: [])
        XCTAssertTrue(snapshot.activeCount.isPartial)
        XCTAssertTrue(snapshot.waitingCount.isPartial)
        XCTAssertTrue(snapshot.subagentCount.isPartial)
        XCTAssertNil(snapshot.activeCount.value)
        XCTAssertFalse(snapshot.isCoverageComplete)
    }

    func testAllGatewaysNonReportingIsPartialNeverZero() {
        let gw = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"),
            coverage: .disconnected,
            operations: [],
            observedAt: Date()
        )
        let snapshot = LiveOpsSnapshot(gateways: [gw])
        XCTAssertTrue(snapshot.activeCount.isPartial)
        XCTAssertFalse(snapshot.isCoverageComplete)
        XCTAssertEqual(snapshot.reportingGatewayCount, 0)
    }

    func testMixedCoverageCountsOnlyReportingGatewaysButIsNotPartial() {
        let reporting = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"),
            coverage: .reporting,
            operations: [makeOperation(status: .working)],
            observedAt: Date()
        )
        let failed = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-b"),
            coverage: .failed(reason: "timeout"),
            operations: [],
            observedAt: Date()
        )
        let snapshot = LiveOpsSnapshot(gateways: [reporting, failed])
        XCTAssertEqual(snapshot.activeCount.value, 1)
        XCTAssertFalse(snapshot.isCoverageComplete, "one gateway failed — coverage cannot claim complete")
        XCTAssertEqual(snapshot.reportingGatewayCount, 1)
    }

    func testFullCoverageIsCoverageCompleteTrue() {
        let gw = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"),
            coverage: .reporting,
            operations: [],
            observedAt: Date()
        )
        XCTAssertTrue(LiveOpsSnapshot(gateways: [gw]).isCoverageComplete)
    }

    func testActiveWaitingIdleCountedCorrectly() {
        let gw = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"),
            coverage: .reporting,
            operations: [
                makeOperation(sid: "s1", status: .working),
                makeOperation(sid: "s2", status: .waiting),
                makeOperation(sid: "s3", status: .starting),
                makeOperation(sid: "s4", status: .idle),
            ],
            observedAt: Date()
        )
        let snapshot = LiveOpsSnapshot(gateways: [gw])
        XCTAssertEqual(snapshot.activeCount.value, 3, "working+starting+waiting, idle excluded")
        XCTAssertEqual(snapshot.waitingCount.value, 1)
    }

    func testSubagentCountPartialWhenNoOperationKnowsItsSubagents() {
        let gw = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"),
            coverage: .reporting,
            operations: [makeOperation(subagents: nil)],
            observedAt: Date()
        )
        XCTAssertTrue(LiveOpsSnapshot(gateways: [gw]).subagentCount.isPartial)
    }

    func testSubagentCountSumsKnownOperationsOnly() {
        let child = LiveOpsSubagent(
            subagentID: "child-1", parentID: nil, depth: 0, goal: "fixture goal",
            model: "m", startedAt: Date(), status: "running", toolCount: 2
        )
        let gw = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"),
            coverage: .reporting,
            operations: [
                makeOperation(sid: "s1", subagents: [child]),
                makeOperation(sid: "s2", subagents: nil), // unknown — excluded, not zero
            ],
            observedAt: Date()
        )
        XCTAssertEqual(LiveOpsSnapshot(gateways: [gw]).subagentCount.value, 1)
    }

    // MARK: reducer — stale cannot overwrite newer

    func testStaleGenerationCannotOverwriteNewer() {
        let newer = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"), coverage: .reporting,
            operations: [makeOperation(sid: "new")], observedAt: Date(), generation: 5
        )
        let existing = LiveOpsSnapshot(gateways: [newer])

        let stale = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"), coverage: .reporting,
            operations: [makeOperation(sid: "stale")], observedAt: Date(), generation: 3
        )
        let merged = LiveOpsSnapshotReducer.merge(incoming: stale, into: existing)
        XCTAssertEqual(merged.gateways.first?.operations.first?.id.runtimeSessionID, "new")
        XCTAssertEqual(merged.gateways.first?.generation, 5)
    }

    func testEqualGenerationAndObservedAtDoesNotOverwrite() {
        let now = Date()
        let first = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"), coverage: .reporting,
            operations: [makeOperation(sid: "first")], observedAt: now, generation: 1
        )
        let existing = LiveOpsSnapshot(gateways: [first])
        let duplicate = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"), coverage: .reporting,
            operations: [makeOperation(sid: "duplicate")], observedAt: now, generation: 1
        )
        let merged = LiveOpsSnapshotReducer.merge(incoming: duplicate, into: existing)
        XCTAssertEqual(merged.gateways.first?.operations.first?.id.runtimeSessionID, "first")
    }

    func testNewerObservedAtAtSameGenerationOverwrites() {
        let earlier = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"), coverage: .reporting,
            operations: [makeOperation(sid: "earlier")], observedAt: Date(timeIntervalSince1970: 100), generation: 1
        )
        let existing = LiveOpsSnapshot(gateways: [earlier])
        let later = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"), coverage: .reporting,
            operations: [makeOperation(sid: "later")], observedAt: Date(timeIntervalSince1970: 200), generation: 1
        )
        let merged = LiveOpsSnapshotReducer.merge(incoming: later, into: existing)
        XCTAssertEqual(merged.gateways.first?.operations.first?.id.runtimeSessionID, "later")
    }

    // MARK: reducer — failure keeps last-good, never "0 active"

    func testFailedRefreshKeepsLastGoodOperationsAndMarksCoverageFailed() {
        let good = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"), coverage: .reporting,
            operations: [makeOperation(sid: "good", status: .working)],
            observedAt: Date(timeIntervalSince1970: 100), generation: 1,
            observationNote: "Synthetic observer scope"
        )
        let existing = LiveOpsSnapshot(gateways: [good])

        let failure = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"), coverage: .failed(reason: "connection reset"),
            operations: [], observedAt: Date(timeIntervalSince1970: 200), generation: 2
        )
        let merged = LiveOpsSnapshotReducer.merge(incoming: failure, into: existing)
        let mergedGateway = merged.gateways.first
        XCTAssertEqual(mergedGateway?.operations.count, 1, "last-good operations preserved through a failed refresh")
        XCTAssertEqual(mergedGateway?.operations.first?.id.runtimeSessionID, "good")
        XCTAssertEqual(mergedGateway?.coverage, .failed(reason: "connection reset"))
        // The aggregate must never read as "0 active" purely because of the
        // failed refresh — the held-over operation still counts.
        XCTAssertEqual(merged.activeCount.value, 1)
        XCTAssertEqual(mergedGateway?.observationNote, "Synthetic observer scope")
        let recovered = LiveOpsGatewaySnapshot(
            gatewayID: good.gatewayID, coverage: .reporting, operations: [],
            observedAt: Date(timeIntervalSince1970: 300), generation: 3)
        XCTAssertNil(LiveOpsSnapshotReducer.merge(incoming: recovered, into: merged).gateways.first?.observationNote)
    }

    func testFirstSnapshotForAGatewayIsAlwaysAccepted() {
        let first = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"), coverage: .unsupported,
            operations: [], observedAt: Date(), generation: 0
        )
        let merged = LiveOpsSnapshotReducer.merge(incoming: first, into: nil)
        XCTAssertEqual(merged.gateways.count, 1)
        XCTAssertEqual(merged.gateways.first?.coverage, .unsupported)
    }

    func testMergeIsPerGatewayIndependent() {
        let a = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-a"), coverage: .reporting,
            operations: [], observedAt: Date()
        )
        var snapshot = LiveOpsSnapshotReducer.merge(incoming: a, into: nil)
        let b = LiveOpsGatewaySnapshot(
            gatewayID: GatewayID(rawValue: "gw-b"), coverage: .reporting,
            operations: [], observedAt: Date()
        )
        snapshot = LiveOpsSnapshotReducer.merge(incoming: b, into: snapshot)
        XCTAssertEqual(snapshot.gateways.count, 2)
    }

    // MARK: swarm tree — join by owner id, nesting, orphans

    func testSwarmTreeBuildsParentChildFromParentID() {
        let root = LiveOpsSubagent(
            subagentID: "root", parentID: nil, depth: 0, goal: "root goal",
            model: nil, startedAt: Date(), status: "running", toolCount: 0
        )
        let child = LiveOpsSubagent(
            subagentID: "child", parentID: "root", depth: 1, goal: "child goal",
            model: nil, startedAt: Date(), status: "running", toolCount: 0
        )
        let tree = LiveOpsSnapshotReducer.swarmTree(from: [root, child])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree.first?.subagent.subagentID, "root")
        XCTAssertEqual(tree.first?.children.count, 1)
        XCTAssertEqual(tree.first?.children.first?.subagent.subagentID, "child")
    }

    func testSwarmTreeHandlesDeepNesting() {
        let a = LiveOpsSubagent(subagentID: "a", parentID: nil, depth: 0, goal: "g", model: nil, startedAt: Date(), status: "running", toolCount: 0)
        let b = LiveOpsSubagent(subagentID: "b", parentID: "a", depth: 1, goal: "g", model: nil, startedAt: Date(), status: "running", toolCount: 0)
        let c = LiveOpsSubagent(subagentID: "c", parentID: "b", depth: 2, goal: "g", model: nil, startedAt: Date(), status: "running", toolCount: 0)
        let tree = LiveOpsSnapshotReducer.swarmTree(from: [a, b, c])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree.first?.children.first?.children.first?.subagent.subagentID, "c")
    }

    func testSwarmTreeAttachesOrphanToRootDeterministically() {
        // "orphan" declares a parent that isn't present in the snapshot
        // (already completed / evicted) — must attach at root, never drop.
        let orphan = LiveOpsSubagent(
            subagentID: "orphan", parentID: "long-gone", depth: 3, goal: "orphan goal",
            model: nil, startedAt: Date(), status: "running", toolCount: 0
        )
        let normalRoot = LiveOpsSubagent(
            subagentID: "normal", parentID: nil, depth: 0, goal: "goal",
            model: nil, startedAt: Date(), status: "running", toolCount: 0
        )
        let tree1 = LiveOpsSnapshotReducer.swarmTree(from: [orphan, normalRoot])
        let tree2 = LiveOpsSnapshotReducer.swarmTree(from: [normalRoot, orphan])
        XCTAssertEqual(tree1.map(\.subagent.subagentID), ["normal", "orphan"], "deterministic sort regardless of input order")
        XCTAssertEqual(tree2.map(\.subagent.subagentID), ["normal", "orphan"])
    }

    func testSwarmTreeEmptyForNoSubagents() {
        XCTAssertTrue(LiveOpsSnapshotReducer.swarmTree(from: []).isEmpty)
    }

    // MARK: control error / attention

    func testLiveOpsControlErrorDescriptionsAreDisplaySafe() {
        XCTAssertEqual(LiveOpsControlError.notAttached.errorDescription, "not attached to this session")
        XCTAssertEqual(LiveOpsControlError.unsupported.errorDescription, "gateway does not support this operation")
    }

    func testAttentionItemCarriesOptionalApproval() {
        let op = makeOperation(status: .waiting)
        let withApproval = LiveOpsAttentionItem(
            operation: op,
            pendingApproval: ApprovalRequest(requestID: "r1", sessionID: "sid-1", command: "printf hi")
        )
        XCTAssertEqual(withApproval.id, op.id)
        XCTAssertNotNil(withApproval.pendingApproval)

        let withoutApproval = LiveOpsAttentionItem(operation: op)
        XCTAssertNil(withoutApproval.pendingApproval)
    }

    // MARK: steer result vocabulary

    func testSteerResultVocabularyMatchesGateway() {
        XCTAssertEqual(LiveOpsSteerResult.queued.rawValue, "queued")
        XCTAssertEqual(LiveOpsSteerResult.rejected.rawValue, "rejected")
    }
}
