import XCTest
@testable import FleetCore

/// Automatic history recovery after a stream gap is rate-limited: a hostile or
/// broken gateway cannot turn repeated overflow into a refetch storm, and the
/// budget running out is a visible state, not a silent stop.
final class GapRecoveryGovernorTests: XCTestCase {
    private let policy = GapRecoveryGovernor.Policy(
        baseInterval: 2, maxInterval: 16, maxRecoveriesPerWindow: 3, window: 60)

    func testFirstGapRecoversImmediately() {
        var governor = GapRecoveryGovernor(policy: policy)
        XCTAssertEqual(governor.request(at: 100), .recoverNow)
    }

    func testRapidFollowUpsAreDeferredNotDropped() {
        var governor = GapRecoveryGovernor(policy: policy)
        XCTAssertEqual(governor.request(at: 100), .recoverNow)
        XCTAssertEqual(governor.request(at: 100.5), .deferUntil(102), "base interval after the first")
        // Deferral did not consume budget.
        XCTAssertEqual(governor.attemptsInWindow(at: 100.5), 1)
        XCTAssertEqual(governor.request(at: 102), .recoverNow)
    }

    func testBackoffDoublesAndIsCapped() {
        var governor = GapRecoveryGovernor(policy: .init(
            baseInterval: 2, maxInterval: 5, maxRecoveriesPerWindow: 10, window: 1_000))
        XCTAssertEqual(governor.request(at: 0), .recoverNow)
        XCTAssertEqual(governor.request(at: 2), .recoverNow)       // spacing 2
        XCTAssertEqual(governor.request(at: 3), .deferUntil(6))    // spacing 4
        XCTAssertEqual(governor.request(at: 6), .recoverNow)
        XCTAssertEqual(governor.request(at: 7), .deferUntil(11))   // spacing capped at 5
    }

    func testBudgetExhaustionIsSuppressedWithAVisibleRetryTime() {
        var governor = GapRecoveryGovernor(policy: policy)
        for t in [0.0, 20, 40] { XCTAssertEqual(governor.request(at: t), .recoverNow) } // past every backoff
        guard case .suppressed(let retryAfter) = governor.request(at: 50) else {
            return XCTFail("expected suppression after the window budget")
        }
        XCTAssertEqual(retryAfter, 10, accuracy: 0.001, "oldest attempt (t=0) leaves the 60s window at t=60")
        XCTAssertEqual(governor.attemptsInWindow(at: 50), 3, "suppressed requests are not counted")
    }

    func testBudgetRecoversOnceAttemptsAgeOutOfTheWindow() {
        var governor = GapRecoveryGovernor(policy: policy)
        for t in [0.0, 20, 40] { XCTAssertEqual(governor.request(at: t), .recoverNow) }
        guard case .suppressed(let retryAfter) = governor.request(at: 45) else { return XCTFail() }
        XCTAssertEqual(retryAfter, 15, accuracy: 0.001)
        XCTAssertEqual(governor.request(at: 61), .recoverNow, "the t=0 attempt aged out")
    }

    func testAStormOfRequestsCostsAtMostTheWindowBudget() {
        var governor = GapRecoveryGovernor(policy: policy)
        var recoveries = 0
        var now = 0.0
        for _ in 0..<10_000 {          // 10k gaps over ~50s
            if governor.request(at: now) == .recoverNow { recoveries += 1 }
            now += 0.005
        }
        XCTAssertLessThanOrEqual(recoveries, policy.maxRecoveriesPerWindow)
    }

    func testResetForgetsHistory() {
        var governor = GapRecoveryGovernor(policy: policy)
        _ = governor.request(at: 0)
        governor.reset()
        XCTAssertEqual(governor.request(at: 0.1), .recoverNow)
    }
}
