import XCTest
@testable import FleetCore

/// Backoff must survive short-lived connections: "online" for one sample is not
/// "healthy". Exact, clock-injected tests.
final class ReconnectBackoffTests: XCTestCase {
    private let policy = ReconnectBackoff.Policy(baseDelay: 2, maxDelay: 30, maxAttempts: 4, healthyDuration: 60)

    func testDelaysDoubleAndAreCappedAndBounded() {
        var b = ReconnectBackoff(policy: policy)
        XCTAssertEqual(b.nextDelay(), 2)
        XCTAssertEqual(b.nextDelay(), 4)
        XCTAssertEqual(b.nextDelay(), 8)
        XCTAssertEqual(b.nextDelay(), 16)
        XCTAssertNil(b.nextDelay(), "budget spent: stays failed until an explicit reset")
    }

    /// The regression: a peer that accepts the connection and drops it again
    /// (e.g. after rejecting an oversized frame) used to regain the base delay
    /// every time because one `.online` sample reset the budget.
    func testShortLivedConnectionsKeepTheirBackoff() {
        var b = ReconnectBackoff(policy: policy)
        var delays: [TimeInterval] = []
        var now = 0.0
        for _ in 0..<10 {
            if let d = b.nextDelay() { delays.append(d) } else { break }
            now += delays.last ?? 0
            b.observeOnline(at: now)        // connected...
            now += 1                        // ...for about one second
            b.observeOnline(at: now)
            b.observeFailure()              // ...then dropped again
        }
        XCTAssertEqual(delays, [2, 4, 8, 16], "delays keep growing across 1 s connections, then the budget ends")
    }

    func testSustainedHealthRestoresTheBudget() {
        var b = ReconnectBackoff(policy: policy)
        _ = b.nextDelay(); _ = b.nextDelay(); _ = b.nextDelay()
        b.observeOnline(at: 1_000)
        b.observeOnline(at: 1_059)
        XCTAssertEqual(b.attempts, 3, "59 s of uptime is not yet healthy")
        b.observeOnline(at: 1_060)
        XCTAssertEqual(b.attempts, 0, "60 s of continuous uptime proves recovery")
        XCTAssertEqual(b.nextDelay(), 2, "a recovered gateway is not penalized afterwards")
    }

    func testAFailureRestartsTheStabilityClock() {
        var b = ReconnectBackoff(policy: policy)
        _ = b.nextDelay(); _ = b.nextDelay()
        b.observeOnline(at: 0)
        b.observeOnline(at: 50)
        b.observeFailure()                  // dropped at 50 s
        b.observeOnline(at: 51)             // back; the 60 s clock restarts here
        b.observeOnline(at: 100)            // only 49 s since the restart
        XCTAssertEqual(b.attempts, 2)
        b.observeOnline(at: 111)
        XCTAssertEqual(b.attempts, 0)
    }

    func testExplicitResetRestoresTheBudget() {
        var b = ReconnectBackoff(policy: policy)
        while b.nextDelay() != nil {}
        b.reset()
        XCTAssertEqual(b.nextDelay(), 2, "foreground restore / manual retry / endpoint change start fresh")
    }

    func testAnImmediateHealthyDurationKeepsTheLegacyResetOnOnline() {
        var b = ReconnectBackoff(policy: .init(baseDelay: 1, maxDelay: 4, maxAttempts: 2, healthyDuration: 0))
        _ = b.nextDelay(); _ = b.nextDelay()
        b.observeOnline(at: 5)
        XCTAssertEqual(b.attempts, 0)
    }
}
