import XCTest
@testable import FleetCore

/// FOS-4 (t_2f5bf49a) — Needs You projection + coverage truth + the §17
/// bounded scheduler, hermetically.
final class FleetAttentionAndSchedulerTests: XCTestCase {

    private let ws = GatewayID(rawValue: "workstation")
    private let lab = GatewayID(rawValue: "lab")

    /// Mutable injectable clock (Swift 6 sendable-safe via a locked box).
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = Date(timeIntervalSince1970: 1000)
        var value: Date {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            _value = _value.addingTimeInterval(seconds)
        }
    }

    private var gatewayList: [FleetGateway] {
        [
            FleetGateway(id: ws, displayName: "Workstation", endpoint: nil),
            FleetGateway(id: lab, displayName: "Lab Node", endpoint: nil),
        ]
    }

    private func snapshot(_ outcomes: [GatewayID: GatewayRosterOutcome]) -> FleetRosterSnapshot {
        var roster = FleetRoster()
        for gateway in gatewayList { roster.upsertGateway(gateway) }
        return FleetRosterSnapshot(roster: roster, gatewayOutcomes: outcomes)
    }

    // MARK: unknown ≠ zero (SPEC §7 coverage truth)

    func testAuthRequiredGatewayProducesExactlyOneItem() {
        let snap = snapshot([
            ws: .loaded(profileCount: 2),
            lab: .failed(status: .authenticationRequired, detail: nil),
        ])
        let items = FleetAttentionProjection.gatewayItems(gateways: gatewayList, snapshot: snap, now: Date())
        XCTAssertEqual(items.count, 1, "one item per gateway/auth episode")
        XCTAssertEqual(items[0].kind, .gatewayAuthRequired)
        XCTAssertEqual(items[0].gatewayID, lab)
        XCTAssertEqual(items[0].title, "Sign in to Lab Node")
    }

    func testDedupByGatewayEpisode() {
        let snap = snapshot([
            ws: .failed(status: .authenticationRequired, detail: nil),
            lab: .failed(status: .authenticationRequired, detail: nil),
        ])
        let items = FleetAttentionProjection.gatewayItems(gateways: gatewayList, snapshot: snap)
        XCTAssertEqual(items.count, 2, "two gateways = two episodes (never per-error)")
        XCTAssertEqual(Set(items.map(\.id)).count, 2, "ids stable + unique per gateway")
        // Same snapshot re-projected yields identical ids (dedupe by identity).
        let again = FleetAttentionProjection.gatewayItems(gateways: gatewayList, snapshot: snap)
        XCTAssertEqual(items.map(\.id), again.map(\.id))
    }

    func testOfflineAndDegradedAreNotAttentionItems() {
        let snap = snapshot([
            ws: .failed(status: .offline, detail: "unreachable"),
            lab: .failed(status: .degraded, detail: "rpc malformed"),
        ])
        let items = FleetAttentionProjection.gatewayItems(gateways: gatewayList, snapshot: snap)
        XCTAssertTrue(items.isEmpty, "transient/connection classes are coverage, not Needs You")
    }

    func testUnsupportedWithDoctorMarkerIsActionableConfigProblem() {
        let snap = snapshot([
            ws: .loaded(profileCount: 1),
            lab: .failed(status: .unsupported, detail: "ws-ticket 404 (/health: hermes-agent)"),
        ])
        let items = FleetAttentionProjection.gatewayItems(gateways: gatewayList, snapshot: snap)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .gatewayConfigProblem)
        XCTAssertEqual(items[0].gatewayID, lab)
    }

    func testUnsupportedWithoutMarkerIsNotActionable() {
        let snap = snapshot([
            ws: .loaded(profileCount: 1),
            lab: .failed(status: .unsupported, detail: "ws-ticket 404"),
        ])
        let items = FleetAttentionProjection.gatewayItems(gateways: gatewayList, snapshot: snap)
        XCTAssertTrue(items.isEmpty, "a plain unsupported answer is status, not a repair item")
    }

    func testNilSnapshotYieldsNoItemsNeverZeroClaim() {
        let items = FleetAttentionProjection.gatewayItems(gateways: gatewayList, snapshot: nil)
        XCTAssertTrue(items.isEmpty)
        let coverage = FleetAttentionCoverage.compute(gateways: gatewayList, snapshot: nil)
        XCTAssertFalse(coverage.allGatewaysClassified, "no snapshot = incomplete coverage, never a complete-inbox claim")
    }

    func testCoverageIncompleteWhenAnyGatewayUnclassified() {
        let snap = snapshot([ws: .loaded(profileCount: 1)])
        let coverage = FleetAttentionCoverage.compute(gateways: gatewayList, snapshot: snap)
        XCTAssertFalse(coverage.allGatewaysClassified)
        let complete = FleetAttentionCoverage.compute(
            gateways: gatewayList,
            snapshot: snapshot([ws: .loaded(profileCount: 1), lab: .loaded(profileCount: 3)]))
        XCTAssertTrue(complete.allGatewaysClassified)
    }

    func testPriorityOrderApprovalsBeforeAuthBeforeRetry() {
        let now = Date()
        func item(_ kind: FleetAttentionItem.Kind, _ id: String, at: Date) -> FleetAttentionItem {
            FleetAttentionItem(id: id, kind: kind, gatewayID: ws, title: id, observedAt: at,
                               destination: .gatewayAuthentication(ws))
        }
        let later = now.addingTimeInterval(10)
        let unordered = [
            item(.roomRetry, "retry", at: now),
            item(.gatewayAuthRequired, "auth", at: later),
            item(.roomApproval, "approval", at: later),
        ]
        let sorted = unordered.sorted(by: FleetAttentionItem.prioritySort)
        XCTAssertEqual(sorted.map(\.kind), [.roomApproval, .gatewayAuthRequired, .roomRetry])
        // Within class, oldest first.
        let sameClass = [
            item(.gatewayAuthRequired, "b", at: later),
            item(.gatewayAuthRequired, "a", at: now),
        ].sorted(by: FleetAttentionItem.prioritySort)
        XCTAssertEqual(sameClass.map(\.id), ["a", "b"])
    }

    // MARK: §17 scheduler

    func testSchedulerDueOnFirstObservation() {
        let scheduler = FleetSummaryScheduler(now: { Date(timeIntervalSince1970: 1000) })
        XCTAssertTrue(scheduler.isDue(.empty), "never-observed gateway is due immediately")
    }

    func testSchedulerNotDueWithinMinInterval() {
        let clock = Clock()
        let scheduler = FleetSummaryScheduler(now: { clock.value })
        let state = scheduler.onSuccess(.empty)
        clock.advance(29)
        XCTAssertFalse(scheduler.isDue(state))
        clock.advance(1)
        XCTAssertTrue(scheduler.isDue(state), "due again at exactly 30s (foreground cadence)")
    }

    func testBackoffLadder30_60_120_300() {
        let scheduler = FleetSummaryScheduler()
        XCTAssertEqual(scheduler.backoffDelay(failures: 1), 30)
        XCTAssertEqual(scheduler.backoffDelay(failures: 2), 60)
        XCTAssertEqual(scheduler.backoffDelay(failures: 3), 120)
        XCTAssertEqual(scheduler.backoffDelay(failures: 4), 300)
        XCTAssertEqual(scheduler.backoffDelay(failures: 9), 300, "the cap repeats")
    }

    func testFailureBackoffGatesRedriveAndSuccessResets() {
        let clock = Clock()
        let scheduler = FleetSummaryScheduler(now: { clock.value })
        var state = FleetSummaryScheduler.SourceState()
        state = scheduler.onFailure(state)
        XCTAssertEqual(state.consecutiveFailures, 1)
        clock.advance(29)
        XCTAssertFalse(scheduler.isDue(state), "failed source waits the full backoff step")
        clock.advance(2)
        XCTAssertTrue(scheduler.isDue(state))
        state = scheduler.onSuccess(state)
        XCTAssertEqual(state.consecutiveFailures, 0, "success resets the ladder")
        XCTAssertFalse(scheduler.isDue(state), "fresh success is not immediately due")
    }
}
